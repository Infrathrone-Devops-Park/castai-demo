resource "helm_release" "castai" {
  name             = "castai"
  namespace        = "castai-agent"
  create_namespace = true
  repository       = "https://castai.github.io/helm-charts"
  chart            = "castai"
  version          = var.castai_chart_version
  timeout          = 600

  values = [yamlencode({
    global = {
      castai = {
        provider = "eks"
        apiURL   = var.castai_api_url
      }
      # system node taint
      tolerations = [{ key = "CriticalAddonsOnly", operator = "Exists" }]
    }
    tags = {
      readonly = !local.automation
      full     = local.automation
    }
    autoscaler = {
      "castai-agent" = {
        replicaCount = 1
        additionalEnv = {
          STATIC_CLUSTER_ID = castai_eks_cluster.this.id
          EKS_ACCOUNT_ID    = local.account_id
          EKS_REGION        = var.region
          EKS_CLUSTER_NAME  = var.cluster_name
        }
        nodeSelector = { role = "system" }
      }
      "castai-cluster-controller" = {
        replicas     = 1
        nodeSelector = { role = "system" }
      }
      "castai-pod-pinner" = {
        replicaCount = 1
        nodeSelector = { role = "system" }
      }
      "castai-evictor" = {
        scopedMode   = true
        nodeSelector = { role = "system" }
      }
      "castai-workload-autoscaler" = {
        nodeSelector = { role = "system" }
      }
      "castai-live"   = { enabled = false }
      "castai-kvisor" = { enabled = false }
    }
  })]

  set_sensitive = [
    {
      name  = "global.castai.apiKey"
      value = castai_eks_cluster.this.cluster_token
    }
  ]
}
