#!/usr/bin/env bash
# Side-by-side diff of two snapshots.
# Usage: scripts/compare.sh <labelA> <labelB>
# Reads results/<label>.json from measure.sh
set -euo pipefail

cd "$(dirname "$0")/.."

if [ $# -ne 2 ]; then
  echo "usage: scripts/compare.sh <labelA> <labelB>" >&2
  exit 2
fi
A="results/${1%.json}.json"
B="results/${2%.json}.json"
for f in "$A" "$B"; do
  [ -s "$f" ] || { echo "ERROR: $f not found (run scripts/measure.sh <label>)" >&2; exit 1; }
done

echo "A = $(jq -r '"\(.label)  \(.timestamp)"' "$A")"
echo "B = $(jq -r '"\(.label)  \(.timestamp)"' "$B")"
echo

jq -rn --slurpfile a "$A" --slurpfile b "$B" '
  ($a[0].totals) as $ta | ($b[0].totals) as $tb
  | def fmt: if . == null then "n/a" elif (type == "number") then (. * 10000 | round / 10000 | tostring) else tostring end;
    def pct($x; $y): if ($x == null or $y == null or $x == 0) then "-"
      else ((($y - $x) / $x * 1000 | round) / 10 | if . > 0 then "+\(.)%" else "\(.)%" end) end;
    def diff($x; $y): if ($x == null or $y == null) then "-"
      else (($y - $x) * 10000 | round / 10000 | if . > 0 then "+\(.)" else tostring end) end;
  ["METRIC", "A", "B", "DELTA", "CHANGE"],
  ( [ ["worker nodes", "workerNodes"], ["spot workers", "spotWorkers"],
      ["provisioned vCPU (all)", "provisionedVcpu"], ["provisioned vCPU (workers)", "workerVcpu"],
      ["requested vCPU (all ns)", "requestedVcpuAll"], ["requested vCPU (shop)", "requestedVcpuShop"],
      ["used vCPU (all ns)", "usedVcpuAll"], ["used vCPU (shop)", "usedVcpuShop"],
      ["$/h workers", "usdPerHourWorkers"], ["$/h all nodes", "usdPerHourNodes"],
      ["$/h all-in", "usdPerHourAllIn"],
      ["$/month workers", "usdPerMonthWorkers"], ["$/month all-in", "usdPerMonthAllIn"] ][]
    | . as [$name, $k]
    | [$name, ($ta[$k] | fmt), ($tb[$k] | fmt), diff($ta[$k]; $tb[$k]), pct($ta[$k]; $tb[$k])] )
  | @tsv' | column -t -s "$(printf '\t')"

echo
echo "Node types:"
for f in "$A" "$B"; do
  printf '  %-22s ' "$(jq -r .label "$f"):"
  jq -r '[.nodes[] | select(.provisioner != "system") | "\(.type)/\(.capacity)"]
    | group_by(.) | map("\(length)x \(.[0])") | join(", ") | if . == "" then "(none)" else . end' "$f"
done
