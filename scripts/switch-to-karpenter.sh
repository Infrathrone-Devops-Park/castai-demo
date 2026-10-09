#!/usr/bin/env bash
# CAST AI autoscaler -> Karpenter (idempotent).
# Disable CAST AI, delete its nodes,
# wait gone, sleep 60, restore Karpenter.
# Usage: scripts/switch-to-karpenter.sh [extra terraform -var args]
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/env.sh >/dev/null

KNS="${KARPENTER_NAMESPACE}"
MAX_WAIT=900
FORCE_AFTER=420
ANN=castai-demo/original-cpu-limit
SEL=provisioner.cast.ai/managed-by=cast.ai

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
[ -f "${KARPENTER_DEMO_DIR}/manifests/base/nodepool.yaml" ] || die "karpenter-demo nodepool.yaml not found"

castai_instances() {
  aws ec2 describe-instances \
    --filters 'Name=tag:castai-demo,Values=managed' \
              'Name=instance-state-name,Values=pending,running,shutting-down,stopping' \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null | tr '\t' ' ' | sed 's/None//'
}

# 1. stop CAST AI scaling
log "terraform apply phase=automation autoscaler_enabled=false"
terraform -chdir=terraform apply -auto-approve -input=false \
  -var phase=automation -var autoscaler_enabled=false \
  ${TF_KEEP[@]+"${TF_KEEP[@]}"} ${EXTRA[@]+"${EXTRA[@]}"}

# 2. delete CAST AI nodes
log "Deleting CAST AI nodes (shop pods go Pending)"
kubectl delete node -l "${SEL}" --wait=false 2>/dev/null || true

# 3. wait nodes and instances gone
START=$(date +%s)
forced=false
while :; do
  nodes="$(kubectl get nodes -l "${SEL}" -o name 2>/dev/null | wc -l | tr -d ' ')"
  ids="$(castai_instances | xargs)"
  cnt=0; [ -n "${ids}" ] && cnt="$(echo "${ids}" | wc -w | tr -d ' ')"
  echo "    $(elapsed)s: castai-nodes=${nodes} castai-instances=${cnt}"
  [ "${nodes}" = "0" ] && [ "${cnt}" = "0" ] && break
  # fallback: terminate our tagged instances
  if [ "$(elapsed)" -ge "${FORCE_AFTER}" ] && ! ${forced} && [ "${cnt}" != "0" ]; then
    log "Instances still running; terminating tag castai-demo=managed: ${ids}"
    # shellcheck disable=SC2086
    aws ec2 terminate-instances --instance-ids ${ids} --query 'TerminatingInstances[].InstanceId' --output text
    forced=true
  fi
  [ "$(elapsed)" -ge "${MAX_WAIT}" ] && die "CAST AI capacity not gone after ${MAX_WAIT}s"
  sleep 15
done

# 4. quota release lag
log "Sleeping 60s (quota release lag)"
sleep 60

# 5. start Karpenter
log "Scaling Karpenter to 1"
kubectl -n "${KNS}" scale deploy/karpenter --replicas=1 >/dev/null
kubectl -n "${KNS}" rollout status deploy/karpenter --timeout=180s

# 6. restore NodePools
log "Restoring NodePool default from karpenter-demo"
kubectl apply -f "${KARPENTER_DEMO_DIR}/manifests/base/nodepool.yaml"
for np in $(kubectl get nodepools -o jsonpath='{.items[*].metadata.name}'); do
  orig="$(kubectl get nodepool "${np}" -o jsonpath="{.metadata.annotations.castai-demo/original-cpu-limit}" 2>/dev/null || true)"
  if [ "${np}" != "default" ] && [ -n "${orig}" ] && [ "${orig}" != "none" ]; then
    kubectl patch nodepool "${np}" --type merge -p "{\"spec\":{\"limits\":{\"cpu\":\"${orig}\"}}}" >/dev/null
    echo "    ${np}: limits.cpu -> ${orig}"
  fi
  kubectl annotate nodepool "${np}" "${ANN}-" >/dev/null 2>&1 || true
done
kubectl get nodepools

# 7. wait Karpenter nodes, pods
log "Waiting for Karpenter nodes and shop pods"
START=$(date +%s)
while :; do
  knodes="$(kubectl get nodes -l karpenter.sh/nodepool --no-headers 2>/dev/null | grep -c ' Ready' || true)"
  total="$(kubectl -n shop get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  pending="$(kubectl -n shop get pods --field-selector=status.phase!=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  echo "    $(elapsed)s: karpenter-nodes-ready=${knodes} shop-pods=${total} not-running=${pending}"
  [ "${total}" = "0" ] && { echo "    no shop pods; nothing to schedule"; break; }
  [ "${knodes}" -ge 1 ] && [ "${pending}" = "0" ] && break
  [ "$(elapsed)" -ge "${MAX_WAIT}" ] && die "shop not Running after ${MAX_WAIT}s"
  sleep 15
done

echo
log "Karpenter is the autoscaler again"
kubectl get nodes -L karpenter.sh/nodepool,node.kubernetes.io/instance-type,karpenter.sh/capacity-type,topology.kubernetes.io/zone
