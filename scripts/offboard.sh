#!/usr/bin/env bash
# Full CAST AI offboarding (destructive).
# Usage: scripts/offboard.sh --yes-offboard
# Order: WA off, Karpenter back,
# destroy policies/template, cluster, rest,
# in-cluster sweep, AWS orphan sweep.
set -euo pipefail

if [ "${1:-}" != "--yes-offboard" ]; then
  echo "usage: scripts/offboard.sh --yes-offboard" >&2
  echo "Removes CAST AI from cluster and AWS." >&2
  exit 1
fi

cd "$(dirname "$0")/.."
source scripts/env.sh >/dev/null

NS=shop
KNS="${KARPENTER_NAMESPACE}"
SEL=provisioner.cast.ai/managed-by=cast.ai
WA_ANN=workloads.cast.ai/configuration
ROLE="castai-eks-${CLUSTER_NAME}"
IROLE="castai-eks-instance-${CLUSTER_NAME}"
POLICY="CastEKSPolicy-${CLUSTER_NAME}"
MAX_WAIT=900

log() { printf '==> %s\n' "$*"; }
warn() { echo "WARN: $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }
elapsed() { echo $(( $(date +%s) - START )); }

[ -n "${TF_VAR_castai_api_token:-}" ] || die "~/.castai/api-token missing"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"

tf_has_state() { [ -n "$(terraform -chdir=terraform state list 2>/dev/null)" ]; }
PHASE="$(terraform -chdir=terraform output -raw phase 2>/dev/null || echo automation)"
case "${PHASE}" in readonly|automation) ;; *) PHASE=automation ;; esac
TFV=(-input=false -var "phase=${PHASE}" -var autoscaler_enabled=false -var enable_workload_autoscaler=false)

# saved plan, no blind apply
tf_apply() {
  terraform -chdir=terraform plan -out=tfplan "${TFV[@]}" "$@" \
    && terraform -chdir=terraform apply -input=false tfplan
  local rc=$?; rm -f terraform/tfplan; return "${rc}"
}
tf_destroy() {
  terraform -chdir=terraform plan -destroy -out=tfplan "${TFV[@]}" "$@" \
    && terraform -chdir=terraform apply -input=false tfplan
  local rc=$?; rm -f terraform/tfplan; return "${rc}"
}

castai_instances() {
  aws ec2 describe-instances \
    --filters 'Name=tag:castai-demo,Values=managed' \
              'Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped' \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null | tr '\t' ' ' | sed 's/None//' | xargs
}

# 1. Workload Autoscaler off
log "Removing Workload Autoscaler annotations"
for d in $(kubectl -n "${NS}" get deploy -o name 2>/dev/null); do
  kubectl -n "${NS}" annotate "${d}" "${WA_ANN}-" >/dev/null 2>&1 || true
done
kubectl delete -f manifests/12-hpa/burst-job.yaml --ignore-not-found >/dev/null 2>&1 || true

# 2. Karpenter back first
if tf_has_state; then
  kreplicas="$(kubectl -n "${KNS}" get deploy karpenter -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
  cnodes="$(kubectl get nodes -l "${SEL}" -o name 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${kreplicas:-0}" = "0" ] || [ "${cnodes}" != "0" ]; then
    log "Switching back to Karpenter"
    scripts/switch-to-karpenter.sh -var enable_workload_autoscaler=false
  fi

  # 3. autoscaler + WA policy off
  log "terraform apply autoscaler_enabled=false enable_workload_autoscaler=false"
  tf_apply

  # 4. policies and template
  log "Destroying policies, evictor, node template"
  tf_destroy \
    -target=castai_workload_scaling_policy.shop \
    -target=castai_evictor.this \
    -target=castai_autoscaler_policies.this \
    -target=castai_node_template.default \
    || warn "targeted destroy failed; next step retries"

  # 5. cluster; dependents (helm) go first
  log "Destroying castai_eks_cluster (disconnect, delete CAST AI nodes)"
  if ! tf_destroy -target=castai_eks_cluster.this; then
    echo "Helm hook stuck? Recover with:" >&2
    echo "  helm uninstall castai -n castai-agent --no-hooks" >&2
    echo "  terraform -chdir=terraform state rm helm_release.castai" >&2
    die "cluster destroy failed; rerun after recovery"
  fi

  START=$(date +%s)
  while [ -n "$(castai_instances)" ]; do
    echo "    $(elapsed)s: CAST AI instances left: $(castai_instances)"
    [ "$(elapsed)" -ge 600 ] && break
    sleep 15
  done

  # 6. remaining resources (IAM, ids)
  log "Destroying remaining Terraform resources"
  tf_destroy
else
  log "Terraform state empty; skipping Terraform steps"
fi

# 7. in-cluster leftovers
log "Sweeping in-cluster CAST AI leftovers"
kubectl delete ns castai-agent castai-omni liqo-storage --ignore-not-found --wait=false
for kind in mutatingwebhookconfigurations validatingwebhookconfigurations; do
  for o in $(kubectl get "${kind}" -o name | grep -Ei 'castai|cast\.ai|liqo' || true); do
    kubectl delete "${o}" --ignore-not-found
  done
done
for kind in clusterrolebindings clusterroles; do
  for o in $(kubectl get "${kind}" -o name | grep -Ei 'castai|liqo' || true); do
    kubectl delete "${o}" --ignore-not-found
  done
done
for crd in $(kubectl get crd -o name | grep -Ei '\.cast\.ai$|\.liqo\.io$' || true); do
  name="${crd#customresourcedefinition.apiextensions.k8s.io/}"
  # strip finalizers, then delete
  for r in $(kubectl get "${name}" -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' 2>/dev/null || true); do
    ns="${r%%/*}"; obj="${r#*/}"
    if [ -n "${ns}" ]; then
      kubectl -n "${ns}" patch "${name}" "${obj}" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
    else
      kubectl patch "${name}" "${obj}" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
    fi
  done
  kubectl delete "${crd}" --ignore-not-found --wait=false
done
kubectl label nodes --all autoscaling.cast.ai/removal-disabled- >/dev/null 2>&1 || true

START=$(date +%s)
while kubectl get ns castai-agent >/dev/null 2>&1; do
  [ "$(elapsed)" -ge 300 ] && { warn "namespace castai-agent still terminating"; break; }
  sleep 10
done

# 8. original requests back
log "Recreating ${NS} pods resized by CAST AI"
resized="$(kubectl -n "${NS}" get pods -o json 2>/dev/null | jq -r '.items[]
  | select(.metadata.annotations["autoscaling.cast.ai/vertical-recommendation-hash"] != null) | .metadata.name' || true)"
if [ -n "${resized}" ]; then
  # shellcheck disable=SC2086
  kubectl -n "${NS}" delete pod ${resized} --wait=false
else
  echo "    none"
fi

# 9. AWS orphan sweep
log "AWS sweep: instances tag castai-demo=managed"
ids="$(castai_instances)"
if [ -n "${ids}" ]; then
  # shellcheck disable=SC2086
  aws ec2 terminate-instances --instance-ids ${ids} --query 'TerminatingInstances[].InstanceId' --output text
else
  echo "    none"
fi

log "AWS sweep: launch templates tag castai-demo=managed"
lts="$(aws ec2 describe-launch-templates --filters 'Name=tag:castai-demo,Values=managed' \
  --query 'LaunchTemplates[].LaunchTemplateId' --output text | sed 's/None//' | xargs)"
for lt in ${lts}; do
  aws ec2 delete-launch-template --launch-template-id "${lt}" --query 'LaunchTemplate.LaunchTemplateName' --output text
done
[ -n "${lts}" ] || echo "    none"

# report only: owned, not Karpenter/MNG
log "Report: other cluster-owned launch templates"
mng_lts=""
for ng in $(aws eks list-nodegroups --cluster-name "${CLUSTER_NAME}" --query 'nodegroups[]' --output text); do
  mng_lts="${mng_lts} $(aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" --nodegroup-name "${ng}" --query 'nodegroup.launchTemplate.id' --output text 2>/dev/null || true)"
done
aws ec2 describe-launch-templates --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" --output json \
  | jq -r --arg skip "${mng_lts}" '.LaunchTemplates[]
      | select(([.Tags[]?.Key] | index("karpenter.k8s.aws/cluster")) | not)
      | .LaunchTemplateId as $id
      | select(($skip | split(" ") | index($id)) | not)
      | "    review: \(.LaunchTemplateId) \(.LaunchTemplateName)"'

log "AWS sweep: unattached EBS volumes tag castai-demo=managed"
vols="$(aws ec2 describe-volumes --filters 'Name=tag:castai-demo,Values=managed' 'Name=status,Values=available' \
  --query 'Volumes[].VolumeId' --output text | sed 's/None//' | xargs)"
for v in ${vols}; do aws ec2 delete-volume --volume-id "${v}" && echo "    deleted ${v}"; done
[ -n "${vols}" ] || echo "    none"

log "AWS sweep: access entry for ${IROLE}"
irole_arn="arn:aws:iam::${ACCOUNT}:role/${IROLE}"
if aws eks list-access-entries --cluster-name "${CLUSTER_NAME}" --query 'accessEntries[]' --output text | tr '\t' '\n' | grep -qx "${irole_arn}"; then
  aws eks delete-access-entry --cluster-name "${CLUSTER_NAME}" --principal-arn "${irole_arn}"
  echo "    deleted"
else
  echo "    none"
fi

log "AWS sweep: IAM ${ROLE}, ${IROLE}, ${POLICY}"
for r in "${ROLE}" "${IROLE}"; do
  aws iam get-role --role-name "${r}" >/dev/null 2>&1 || { echo "    ${r}: gone"; continue; }
  for p in $(aws iam list-attached-role-policies --role-name "${r}" --query 'AttachedPolicies[].PolicyArn' --output text); do
    aws iam detach-role-policy --role-name "${r}" --policy-arn "${p}"
  done
  for p in $(aws iam list-role-policies --role-name "${r}" --query 'PolicyNames[]' --output text); do
    aws iam delete-role-policy --role-name "${r}" --policy-name "${p}"
  done
  for ip in $(aws iam list-instance-profiles-for-role --role-name "${r}" --query 'InstanceProfiles[].InstanceProfileName' --output text); do
    aws iam remove-role-from-instance-profile --instance-profile-name "${ip}" --role-name "${r}"
    aws iam delete-instance-profile --instance-profile-name "${ip}"
  done
  aws iam delete-role --role-name "${r}" && echo "    ${r}: deleted"
done
if aws iam get-instance-profile --instance-profile-name "${IROLE}" >/dev/null 2>&1; then
  aws iam delete-instance-profile --instance-profile-name "${IROLE}" && echo "    profile ${IROLE}: deleted"
fi
for pname in "${POLICY}" "CastEC2AssignIPv6Policy-${CLUSTER_NAME}"; do
  parn="arn:aws:iam::${ACCOUNT}:policy/${pname}"
  aws iam get-policy --policy-arn "${parn}" >/dev/null 2>&1 || { echo "    ${pname}: gone"; continue; }
  for v in $(aws iam list-policy-versions --policy-arn "${parn}" --query 'Versions[?!IsDefaultVersion].VersionId' --output text); do
    aws iam delete-policy-version --policy-arn "${parn}" --version-id "${v}"
  done
  aws iam delete-policy --policy-arn "${parn}" && echo "    ${pname}: deleted"
done

log "Report: key pairs named *cast*"
aws ec2 describe-key-pairs --query 'KeyPairs[].KeyName' --output text | tr '\t' '\n' | grep -i cast | sed 's/^/    review: /' || echo "    none"

# 10. CAST AI side
log "CAST AI console: cluster record"
if [ -n "${CASTAI_API_KEY:-}" ]; then
  left="$(scripts/castai-api.sh GET /v1/kubernetes/external-clusters 2>/dev/null \
    | jq -r --arg n "${CLUSTER_NAME}" '.items[]? | select(.name == $n) | "\(.id) \(.status)"')"
  if [ -n "${left}" ]; then echo "    still listed: ${left} (console: disconnect + remove)"; else echo "    gone"; fi
fi

echo
kubectl get nodes -L karpenter.sh/nodepool,node.kubernetes.io/instance-type,karpenter.sh/capacity-type
log "Offboarding done. Rotate the CAST AI API key now:"
echo "    console -> API keys / Service Accounts -> delete key"
echo "    then: rm ~/.castai/api-token"
