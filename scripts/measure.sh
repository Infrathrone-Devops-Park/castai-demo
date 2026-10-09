#!/usr/bin/env bash
# Cost snapshot of the live cluster.
# Usage: scripts/measure.sh [label]
# With label: saves results/<label>.json
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/env.sh >/dev/null

LABEL="${1:-}"
NS=shop
EKS_USD_H=0.10
CACHE=results/price-cache.json
SPOT_TTL=3600
mkdir -p results
[ -s "${CACHE}" ] || echo '{"od":{},"spot":{}}' > "${CACHE}"

# fallback OD prices, ap-south-1, USD/h
static_od() {
  case "$1" in
    t3a.large) echo 0.0493 ;;
    c6a.large) echo 0.04675 ;;
    c6a.xlarge) echo 0.0935 ;;
    m6a.large) echo 0.05555 ;;
    m6a.xlarge) echo 0.1111 ;;
    c6i.large) echo 0.085 ;;
    *) echo "" ;;
  esac
}

now=$(date +%s)
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# 1. nodes
kubectl get nodes -o json | jq '[.items[] | .metadata.labels as $l | {
  name: .metadata.name,
  type: ($l["node.kubernetes.io/instance-type"] // "?"),
  zone: ($l["topology.kubernetes.io/zone"] // "?"),
  vcpu: (.status.capacity.cpu | tonumber),
  instanceId: ((.spec.providerID // "") | split("/") | last),
  provisioner: (if $l["role"] == "system" then "system"
    elif $l["provisioner.cast.ai/managed-by"] == "cast.ai" then "castai"
    elif $l["karpenter.sh/nodepool"] then "karpenter"
    else "other" end),
  capacity: (if $l["karpenter.sh/capacity-type"] then $l["karpenter.sh/capacity-type"]
    elif $l["scheduling.cast.ai/spot-fallback"] == "true" then "on-demand"
    elif $l["scheduling.cast.ai/spot"] == "true" then "spot"
    elif $l["provisioner.cast.ai/managed-by"] == "cast.ai" then "on-demand"
    elif $l["eks.amazonaws.com/capacityType"] == "SPOT" then "spot"
    elif $l["eks.amazonaws.com/capacityType"] == "ON_DEMAND" then "on-demand"
    else "" end)
}]' > "${tmp}/nodes.json"

# 2. unknown capacity: ask EC2
unknown="$(jq -r '[.[] | select(.capacity == "") | .instanceId] | join(" ")' "${tmp}/nodes.json")"
if [ -n "${unknown}" ]; then
  # shellcheck disable=SC2086
  aws ec2 describe-instances --instance-ids ${unknown} \
    --query 'Reservations[].Instances[].{id:InstanceId,lc:InstanceLifecycle}' --output json \
    > "${tmp}/lc.json" 2>/dev/null || echo '[]' > "${tmp}/lc.json"
  jq --slurpfile lc "${tmp}/lc.json" '
    ($lc[0] | map({key: .id, value: (if .lc == "spot" then "spot" else "on-demand" end)}) | from_entries) as $m
    | map(if .capacity == "" then .capacity = ($m[.instanceId] // "unknown") else . end)' \
    "${tmp}/nodes.json" > "${tmp}/n2.json" && mv "${tmp}/n2.json" "${tmp}/nodes.json"
fi

# 3. prices, cached
od_price() {
  local t="$1" p
  p="$(jq -r --arg t "$t" '.od[$t].usd // empty' "${CACHE}")"
  if [ -z "$p" ]; then
    # Price List API: us-east-1 endpoint
    p="$(aws pricing get-products --region us-east-1 --service-code AmazonEC2 \
      --filters "Type=TERM_MATCH,Field=instanceType,Value=${t}" \
                "Type=TERM_MATCH,Field=regionCode,Value=${AWS_REGION}" \
                "Type=TERM_MATCH,Field=operatingSystem,Value=Linux" \
                "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
                "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" \
                "Type=TERM_MATCH,Field=capacitystatus,Value=Used" \
      --output json 2>/dev/null \
      | jq -r '[.PriceList[] | fromjson | .terms.OnDemand[]?.priceDimensions[]?.pricePerUnit.USD | tonumber | select(. > 0)] | min // empty' 2>/dev/null || true)"
    local src=pricing-api
    if [ -z "$p" ]; then p="$(static_od "$t")"; src=static; fi
    if [ -z "$p" ]; then echo ""; return; fi
    jq --arg t "$t" --argjson p "$p" --arg s "$src" --argjson at "$now" \
      '.od[$t] = {usd: $p, src: $s, at: $at}' "${CACHE}" > "${tmp}/c.json" && mv "${tmp}/c.json" "${CACHE}"
  fi
  echo "$p"
}

spot_price() {
  local t="$1" z="$2" k="$1|$2" p
  p="$(jq -r --arg k "$k" --argjson now "$now" --argjson ttl "${SPOT_TTL}" \
    '.spot[$k] | select(. != null and ($now - .at) < $ttl) | .usd' "${CACHE}")"
  if [ -z "$p" ]; then
    p="$(aws ec2 describe-spot-price-history --instance-types "$t" --availability-zone "$z" \
      --product-descriptions Linux/UNIX --start-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --query 'SpotPriceHistory[0].SpotPrice' --output text 2>/dev/null || true)"
    case "$p" in ''|None) echo ""; return ;; esac
    jq --arg k "$k" --argjson p "$p" --argjson at "$now" \
      '.spot[$k] = {usd: $p, src: "spot-history", at: $at}' "${CACHE}" > "${tmp}/c.json" && mv "${tmp}/c.json" "${CACHE}"
  fi
  echo "$p"
}

echo '[]' > "${tmp}/priced.json"
count="$(jq length "${tmp}/nodes.json")"
i=0
while [ "$i" -lt "$count" ]; do
  row="$(jq -c ".[$i]" "${tmp}/nodes.json")"
  t="$(echo "$row" | jq -r .type)"; z="$(echo "$row" | jq -r .zone)"
  c="$(echo "$row" | jq -r .capacity)"
  if [ "$c" = "spot" ]; then p="$(spot_price "$t" "$z")"; else p="$(od_price "$t")"; fi
  [ -n "$p" ] || { echo "WARN: no price for $t $c $z" >&2; p=0; }
  jq --argjson r "$row" --argjson p "$p" '. + [$r + {usdPerHour: ($p * 1)}]' "${tmp}/priced.json" > "${tmp}/p2.json"
  mv "${tmp}/p2.json" "${tmp}/priced.json"
  i=$((i+1))
done

# 4. requests of scheduled pods
kubectl get pods -A -o json | jq --arg ns "$NS" '
  def cpu: if . == null then 0 elif endswith("m") then (.[:-1] | tonumber) / 1000 else tonumber end;
  [.items[] | select(.spec.nodeName != null and (.status.phase == "Running" or .status.phase == "Pending"))
    | {ns: .metadata.namespace, cpu: ([.spec.containers[].resources.requests.cpu | cpu] | add // 0)}] as $p
  | {all: ([$p[].cpu] | add // 0), shop: ([$p[] | select(.ns == $ns) | .cpu] | add // 0),
     shopPods: ([$p[] | select(.ns == $ns)] | length)}' > "${tmp}/req.json"

# 5. usage via metrics-server
mcores() { awk -v col="$1" '{v=$col; if (v ~ /m$/) {sub(/m$/,"",v); s+=v/1000} else s+=v} END {printf "%.3f", s+0}'; }
used_all="null"; used_shop="null"
if out="$(kubectl top pods -A --no-headers 2>/dev/null)" && [ -n "$out" ]; then
  used_all="$(echo "$out" | mcores 3)"
  used_shop="$(echo "$out" | awk -v ns="$NS" '$1 == ns' | mcores 3)"
else
  echo "WARN: kubectl top failed; usage n/a" >&2
fi

# 6. assemble
jq -n --arg label "${LABEL:-adhoc}" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --slurpfile nodes "${tmp}/priced.json" --slurpfile req "${tmp}/req.json" \
  --argjson usedAll "$used_all" --argjson usedShop "$used_shop" --argjson eks "$EKS_USD_H" '
  ($nodes[0]) as $n | ($req[0]) as $r
  | ($n | map(select(.provisioner != "system"))) as $w
  | def r3: (. * 1000 | round) / 1000;
    def r4: (. * 10000 | round) / 10000;
  {label: $label, timestamp: $ts, nodes: $n,
   totals: {
     nodes: ($n | length), workerNodes: ($w | length),
     spotWorkers: ($w | map(select(.capacity == "spot")) | length),
     provisionedVcpu: ([$n[].vcpu] | add // 0), workerVcpu: ([$w[].vcpu] | add // 0),
     requestedVcpuAll: ($r.all | r3), requestedVcpuShop: ($r.shop | r3), shopPods: $r.shopPods,
     usedVcpuAll: $usedAll, usedVcpuShop: $usedShop,
     usdPerHourWorkers: ([$w[].usdPerHour] | add // 0 | r4),
     usdPerHourNodes: ([$n[].usdPerHour] | add // 0 | r4),
     usdPerHourAllIn: (([$n[].usdPerHour] | add // 0) + $eks | r4)
   }}
  | .totals += {
     usdPerMonthWorkers: (.totals.usdPerHourWorkers * 730 | . * 100 | round / 100),
     usdPerMonthNodes: (.totals.usdPerHourNodes * 730 | . * 100 | round / 100),
     usdPerMonthAllIn: (.totals.usdPerHourAllIn * 730 | . * 100 | round / 100)}' > "${tmp}/snap.json"

# 7. print
jq -r '
  "NODE\tPROVISIONER\tTYPE\tCAPACITY\tZONE\tVCPU\tUSD/H",
  (.nodes | sort_by(.provisioner, .name)[] |
    [.name, (if .provisioner == "system" then "system*" else .provisioner end),
     .type, .capacity, .zone, (.vcpu | tostring), (.usdPerHour | tostring)] | @tsv)' "${tmp}/snap.json" \
  | column -t -s "$(printf '\t')"
echo "(* system node: fixed cost, not autoscaled)"
echo
jq -r '.totals | [
  ["nodes (workers / spot workers)", "\(.nodes) (\(.workerNodes) / \(.spotWorkers))"],
  ["provisioned vCPU (all / workers)", "\(.provisionedVcpu) / \(.workerVcpu)"],
  ["requested vCPU (all ns / shop)", "\(.requestedVcpuAll) / \(.requestedVcpuShop)"],
  ["used vCPU (all ns / shop)", "\(.usedVcpuAll // "n/a") / \(.usedVcpuShop // "n/a")"],
  ["shop pods scheduled", "\(.shopPods)"],
  ["$/h workers", "\(.usdPerHourWorkers)"],
  ["$/h all nodes", "\(.usdPerHourNodes)"],
  ["$/h all-in (+EKS 0.10)", "\(.usdPerHourAllIn)"],
  ["$/month workers (x730)", "\(.usdPerMonthWorkers)"],
  ["$/month all-in (x730)", "\(.usdPerMonthAllIn)"]
  ][] | @tsv' "${tmp}/snap.json" | column -t -s "$(printf '\t')"

if [ -n "${LABEL}" ]; then
  cp "${tmp}/snap.json" "results/${LABEL}.json"
  echo
  echo "saved results/${LABEL}.json"
fi
