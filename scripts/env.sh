# Source from repo root: source scripts/env.sh
# Idempotent; zsh and bash safe.

if [ ! -f scripts/env.sh ] || [ ! -d terraform ]; then
  echo "ERROR: source from castai-demo repo root" >&2
  return 1 2>/dev/null || exit 1
fi

export AWS_PROFILE=infrathrone-demo
export AWS_REGION=ap-south-1
export AWS_DEFAULT_REGION="${AWS_REGION}"
export CLUSTER_NAME=karpenter-demo
export KARPENTER_NAMESPACE=kube-system

# sibling repo, absolute path
if [ -d ../karpenter-demo ]; then
  KARPENTER_DEMO_DIR="$(cd ../karpenter-demo && pwd)"
else
  KARPENTER_DEMO_DIR=""
  echo "WARN: ../karpenter-demo not found" >&2
fi
export KARPENTER_DEMO_DIR

# dedicated kubeconfig; immune to context switches
export KUBECONFIG="${PWD}/.kube/${CLUSTER_NAME}.kubeconfig"
if [ ! -s "${KUBECONFIG}" ]; then
  mkdir -p "${PWD}/.kube"
  aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
    --kubeconfig "${KUBECONFIG}" >/dev/null 2>&1 || echo "WARN: kubeconfig not created" >&2
fi

# CAST AI key: never echoed
export CASTAI_API_URL=https://api.cast.ai
_cd_keyfile="${HOME}/.castai/api-token"
if [ -s "${_cd_keyfile}" ]; then
  CASTAI_API_KEY="$(tr -d '[:space:]' < "${_cd_keyfile}")"
  export CASTAI_API_KEY
  export TF_VAR_castai_api_token="${CASTAI_API_KEY}"
  _cd_keystate="<set, ${#CASTAI_API_KEY} chars, masked>"
else
  unset CASTAI_API_KEY TF_VAR_castai_api_token
  _cd_keystate="<MISSING>"
  echo "WARN: ${_cd_keyfile} missing or empty" >&2
fi

# cluster id from Terraform state
_cd_cid=""
if command -v terraform >/dev/null 2>&1; then
  _cd_cid="$(terraform -chdir=terraform output -raw castai_cluster_id 2>/dev/null)" || _cd_cid=""
  case "${_cd_cid}" in
    ????????-????-????-????-????????????) ;;
    *) _cd_cid="" ;;
  esac
fi
export CASTAI_CLUSTER_ID="${_cd_cid}"

echo "AWS_PROFILE=${AWS_PROFILE} AWS_REGION=${AWS_REGION} CLUSTER_NAME=${CLUSTER_NAME}"
echo "KUBECONFIG=${KUBECONFIG}"
echo "KARPENTER_DEMO_DIR=${KARPENTER_DEMO_DIR:-<not found>}"
echo "CASTAI_API_URL=${CASTAI_API_URL} CASTAI_API_KEY=${_cd_keystate}"
echo "CASTAI_CLUSTER_ID=${CASTAI_CLUSTER_ID:-<not applied yet>}"
unset _cd_keyfile _cd_keystate _cd_cid
