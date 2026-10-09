#!/usr/bin/env bash
# CAST AI ACTIVE BASELINE reset (idempotent).
#
# Baseline per module group:
#   Karpenter modules (before the switch):
#     karpenter-demo baseline; use switch-to-karpenter.sh.
#   CAST AI modules (after switch, 11-14):
#     baseline = this script:
#     - Karpenter at 0, NodePools frozen
#     - TF phase=automation, autoscaler on
#     - enable_workload_autoscaler=false (no policy)
#     - only node template default-by-castai
#     - no custom scaling policies
#     - shop: shop.yaml, original requests
#     - no recommender/loadgen/burst/VPA
#     - no castai-lab ns, no PDBs
#   Module 15: end state, no reset.
#
# KEEP_HPA=1 keeps workloads/hpa.yaml deployed.
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/env.sh >/dev/null

NS=shop
KNS="${KARPENTER_NAMESPACE}"
MAX_WAIT=900
DEFAULT_TEMPLATE=default-by-castai
VPA_BASE=https://raw.githubusercontent.com/kubernetes/autoscaler/vertical-pod-autoscaler-1.8.0/vertical-pod-autoscaler/deploy
SYSTEM_POLICIES=" balanced cost-savings stability resiliency burstable readonly default default-statefulset "
WA_ANN=workloads.cast.ai/configuration

log() { printf '==> %s\n' "$*"; }
warn() { echo "WARN: $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }
elapsed() { echo $(( $(date +%s) - START )); }
api() { scripts/castai-api.sh "$@"; }

[ -n "${TF_VAR_castai_api_token:-}" ] || die "~/.castai/api-token missing"
[ -n "$(terraform -chdir=terraform state list 2>/dev/null)" ] || die "terraform state empty (offboarded?)"

# pods whose requests differ from template
drifted_pods() {
  kubectl -n "${NS}" get deploy,pods -o json | jq -r '
    ([.items[] | select(.kind == "Deployment")
      | {key: .metadata.name, value: (.spec.template.spec.containers[0].resources.requests | tostring)}]
     | from_entries) as $want
    | .items[] | select(.kind == "Pod")
    | select(.metadata.labels.app as $a | $want[$a] != null
        and $want[$a] != (.spec.containers[0].resources.requests | tostring))
    | .metadata.name'
}

# 1. annotations first, then policy
log "Removing Workload Autoscaler annotations in ${NS}"
for d in $(kubectl -n "${NS}" get deploy -o name 2>/dev/null); do
  kubectl -n "${NS}" annotate "${d}" "${WA_ANN}-" >/dev/null 2>&1 || true
done

# 2. module 07-13 extras
log "Removing castai-lab, burst job, HPA workload, VPA"
kubectl delete ns castai-lab --ignore-not-found --wait=false >/dev/null
kubectl delete priorityclass castai-lab-headroom --ignore-not-found >/dev/null
kubectl delete -f manifests/12-hpa/burst-job.yaml --ignore-not-found >/dev/null
if [ "${KEEP_HPA:-0}" != "1" ]; then
  kubectl delete -f workloads/hpa.yaml --ignore-not-found >/dev/null
fi
if kubectl get crd verticalpodautoscalers.autoscaling.k8s.io >/dev/null 2>&1; then
  kubectl -n "${NS}" delete vpa --all --ignore-not-found >/dev/null 2>&1 || true
fi
if kubectl -n kube-system get deploy vpa-recommender >/dev/null 2>&1; then
  for f in recommender-deployment.yaml vpa-rbac.yaml vpa-v1-crd-gen.yaml; do
    kubectl delete -f "${VPA_BASE}/${f}" --ignore-not-found >/dev/null 2>&1 || warn "could not delete ${f}"
  done
fi

# 3. CAST AI is the autoscaler
kreplicas="$(kubectl -n "${KNS}" get deploy karpenter -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
if [ "${kreplicas:-0}" != "0" ]; then
  log "Karpenter active (replicas=${kreplicas}); running switch-to-castai.sh"
  scripts/switch-to-castai.sh
fi

# 4. Terraform to baseline vars
log "terraform apply phase=automation autoscaler_enabled=true enable_workload_autoscaler=false"
# saved plan, no blind apply
terraform -chdir=terraform plan -input=false -out=tfplan \
  -var phase=automation -var autoscaler_enabled=true -var enable_workload_autoscaler=false
terraform -chdir=terraform apply -input=false tfplan
rm -f terraform/tfplan
CID="$(terraform -chdir=terraform output -raw castai_cluster_id)"
[ -n "${CID}" ] || die "castai_cluster_id output empty"

# 5. custom scaling policies (console-made)
log "Deleting custom scaling policies"
pols="$(api GET "/v1/workload-autoscaling/clusters/${CID}/policies" \
  | jq -r '.items[]? | select((.isReadonly != true) and (.isDefault != true) and (.isCastware != true)) | "\(.id) \(.name)"')"
while read -r pid pname; do
  [ -n "${pid:-}" ] || continue
  case "${SYSTEM_POLICIES}" in *" ${pname} "*) continue ;; esac
  echo "    delete policy ${pname}"
  api DELETE "/v1/workload-autoscaling/clusters/${CID}/policies/${pid}" >/dev/null || warn "policy ${pname} not deleted"
done <<< "${pols}"

# 6. extra node templates
log "Deleting node templates other than ${DEFAULT_TEMPLATE}"
tmpls="$(api GET "/v1/kubernetes/clusters/${CID}/node-templates?includeDefault=true" \
  | jq -r '.items[]?.template.name')"
for t in ${tmpls}; do
  [ "${t}" = "${DEFAULT_TEMPLATE}" ] && continue
  echo "    delete template ${t}"
  api DELETE "/v1/kubernetes/clusters/${CID}/node-templates/${t}" >/dev/null || warn "template ${t} not deleted"
done

# drain their nodes one by one
for n in $(kubectl get nodes -l "scheduling.cast.ai/node-template,scheduling.cast.ai/node-template!=${DEFAULT_TEMPLATE}" -o name); do
  log "Draining ${n} (non-default template)"
  kubectl drain "${n#node/}" --ignore-daemonsets --delete-emptydir-data --force --timeout=300s >/dev/null || warn "drain ${n} incomplete"
  kubectl delete "${n}" --wait=false
  START=$(date +%s)
  while [ -n "$(kubectl -n "${NS}" get pods --field-selector=status.phase=Pending -o name 2>/dev/null)" ]; do
    [ "$(elapsed)" -ge "${MAX_WAIT}" ] && die "shop pods still Pending after ${MAX_WAIT}s"
    sleep 15
  done
done

# 7. shop back to shop.yaml
log "Restoring ${NS} from workloads/shop.yaml"
kubectl apply -f workloads/shop.yaml >/dev/null
want="$(kubectl create --dry-run=client -o name -f workloads/shop.yaml)"
if [ "${KEEP_HPA:-0}" = "1" ]; then
  want="${want}
$(kubectl create --dry-run=client -o name -f workloads/hpa.yaml)"
fi
for d in $(kubectl -n "${NS}" get deploy -o name); do
  echo "${want}" | grep -qx "${d}" || { echo "    delete ${d}"; kubectl -n "${NS}" delete "${d}" --wait=false >/dev/null; }
done
kubectl -n "${NS}" delete jobs,cronjobs,pdb --all --ignore-not-found >/dev/null
if [ "${KEEP_HPA:-0}" != "1" ]; then
  kubectl -n "${NS}" delete hpa --all --ignore-not-found >/dev/null
fi

# recreate rightsized pods
drift="$(drifted_pods)"
if [ -n "${drift}" ]; then
  log "Recreating $(echo "${drift}" | wc -l | tr -d ' ') pods with non-template requests"
  # shellcheck disable=SC2086
  kubectl -n "${NS}" delete pod ${drift} --wait=false >/dev/null
fi

# 8. wait for shop Running
log "Waiting for ${NS} pods"
START=$(date +%s)
while :; do
  total="$(kubectl -n "${NS}" get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  notrun="$(kubectl -n "${NS}" get pods --field-selector=status.phase!=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  cnodes="$(kubectl get nodes -l provisioner.cast.ai/managed-by=cast.ai --no-headers 2>/dev/null | grep -c ' Ready' || true)"
  echo "    $(elapsed)s: pods=${total} not-running=${notrun} castai-nodes-ready=${cnodes}"
  [ "${total}" != "0" ] && [ "${notrun}" = "0" ] && break
  [ "$(elapsed)" -ge "${MAX_WAIT}" ] && die "${NS} not Running after ${MAX_WAIT}s; check console events"
  sleep 15
done

drift="$(drifted_pods)"
[ -z "${drift}" ] || warn "pods still differ from template (webhook still active?): ${drift}"

echo
kubectl get nodes -L provisioner.cast.ai/managed-by,node.kubernetes.io/instance-type,scheduling.cast.ai/spot
kubectl -n "${NS}" get pods -o json | jq -r '"shop requested vCPU: " + ([.items[] | .spec.containers[].resources.requests.cpu // "0"
  | if endswith("m") then (rtrimstr("m") | tonumber / 1000) else tonumber end] | add | tostring)'
log "CAST AI ACTIVE BASELINE reached"
