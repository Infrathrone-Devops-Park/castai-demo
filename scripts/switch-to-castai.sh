#!/usr/bin/env bash
# Karpenter -> CAST AI autoscaler (idempotent).
# Order: freeze NodePools, delete NodeClaims, wait,
# sleep 60, Karpenter 0, CAST on.
# Usage: scripts/switch-to-castai.sh [extra terraform -var args]
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/env.sh >/dev/null

KNS="${KARPENTER_NAMESPACE}"
MAX_WAIT=900
ANN=castai-demo/original-cpu-limit

log() { printf '==> %s\n' "$*"; }
elapsed() { echo $(( $(date +%s) - START )); }
die() { echo "ERROR: $*" >&2; exit 1; }

# extra args go to terraform apply
EXTRA=("$@")
# keep module 11 policy if present
TF_KEEP=()
_wa="$(terraform -chdir=terraform output -raw workload_scaling_policy_name 2>/dev/null || true)"
case "${_wa}" in ""|*Warning*|*Error*|*"No outputs"*) ;; *) TF_KEEP=(-var enable_workload_autoscaler=true) ;; esac

[ -n "${TF_VAR_castai_api_token:-}" ] || die "~/.castai/api-token missing"
kubectl get crd nodepools.karpenter.sh >/dev/null 2>&1 || die "Karpenter CRDs not found"

# 0. Karpenter must run to drain
replicas="$(kubectl -n "${KNS}" get deploy karpenter -o jsonpath='{.spec.replicas}')"
claims="$(kubectl get nodeclaims -o name | wc -l | tr -d ' ')"
if [ "${replicas}" = "0" ] && [ "${claims}" != "0" ]; then
  log "Karpenter at 0 but ${claims} NodeClaims left; scaling to 1 to drain"
  kubectl -n "${KNS}" scale deploy/karpenter --replicas=1
  kubectl -n "${KNS}" rollout status deploy/karpenter --timeout=180s
fi

# 1. freeze every NodePool
log "Freezing NodePools (limits.cpu=0)"
for np in $(kubectl get nodepools -o jsonpath='{.items[*].metadata.name}'); do
  cur="$(kubectl get nodepool "${np}" -o jsonpath='{.spec.limits.cpu}')"
  if [ "${cur}" != "0" ]; then
    # remember limit for switch back
    kubectl annotate nodepool "${np}" --overwrite "${ANN}=${cur:-none}" >/dev/null
    kubectl patch nodepool "${np}" --type merge -p '{"spec":{"limits":{"cpu":"0"}}}' >/dev/null
    echo "    ${np}: ${cur:-none} -> 0"
  else
    echo "    ${np}: already 0"
  fi
done

# 2. delete NodeClaims, wait gone
log "Deleting NodeClaims (shop pods go Pending)"
kubectl delete nodeclaims --all --wait=false >/dev/null 2>&1 || true
START=$(date +%s)
while :; do
  n="$(kubectl get nodeclaims -o name 2>/dev/null | wc -l | tr -d ' ')"
  nodes="$(kubectl get nodes -l karpenter.sh/nodepool -o name 2>/dev/null | wc -l | tr -d ' ')"
  ec2="$(aws ec2 describe-instances \
    --filters 'Name=tag-key,Values=karpenter.sh/nodepool' \
              'Name=instance-state-name,Values=pending,running,shutting-down,stopping' \
    --query 'length(Reservations[].Instances[])' --output text 2>/dev/null || echo '?')"
  echo "    $(elapsed)s: nodeclaims=${n} karpenter-nodes=${nodes} karpenter-instances=${ec2}"
  [ "${n}" = "0" ] && [ "${nodes}" = "0" ] && [ "${ec2}" = "0" ] && break
  [ "$(elapsed)" -ge "${MAX_WAIT}" ] && die "Karpenter capacity not gone after ${MAX_WAIT}s"
  sleep 15
done

# 3. spot quota release lag
log "Sleeping 60s (spot quota release lag)"
sleep 60

# 4. stop Karpenter
log "Scaling Karpenter to 0"
kubectl -n "${KNS}" scale deploy/karpenter --replicas=0 >/dev/null
START=$(date +%s)
while [ -n "$(kubectl -n "${KNS}" get pods -l app.kubernetes.io/name=karpenter -o name 2>/dev/null)" ]; do
  [ "$(elapsed)" -ge 180 ] && die "Karpenter pods still present"
  sleep 5
done
echo "    karpenter pods: 0"

# 5. enable CAST AI autoscaler
log "terraform apply phase=automation autoscaler_enabled=true"
terraform -chdir=terraform apply -auto-approve -input=false \
  -var phase=automation -var autoscaler_enabled=true \
  ${TF_KEEP[@]+"${TF_KEEP[@]}"} ${EXTRA[@]+"${EXTRA[@]}"}

# 6. wait CAST AI nodes, pods
log "Waiting for CAST AI nodes and shop pods"
START=$(date +%s)
while :; do
  cnodes="$(kubectl get nodes -l provisioner.cast.ai/managed-by=cast.ai --no-headers 2>/dev/null | grep -c ' Ready' || true)"
  total="$(kubectl -n shop get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  pending="$(kubectl -n shop get pods --field-selector=status.phase!=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  echo "    $(elapsed)s: castai-nodes-ready=${cnodes} shop-pods=${total} not-running=${pending}"
  [ "${total}" = "0" ] && { echo "    no shop pods; nothing to schedule"; break; }
  [ "${cnodes}" -ge 1 ] && [ "${pending}" = "0" ] && break
  [ "$(elapsed)" -ge "${MAX_WAIT}" ] && die "shop not Running after ${MAX_WAIT}s; check console events"
  sleep 15
done

echo
log "CAST AI is now the autoscaler"
kubectl get nodes -L provisioner.cast.ai/managed-by,node.kubernetes.io/instance-type,scheduling.cast.ai/spot,topology.kubernetes.io/zone
