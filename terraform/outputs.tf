output "castai_cluster_id" {
  value = castai_eks_cluster.this.id
}

output "castai_role_arn" {
  value = module.castai_eks_role_iam.role_arn
}

output "phase" {
  value = var.phase
}

output "autoscaler_enabled" {
  value = var.autoscaler_enabled
}
