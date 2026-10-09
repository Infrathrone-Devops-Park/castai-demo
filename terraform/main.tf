locals {
  automation = var.phase == "automation"
  account_id = data.aws_caller_identity.current.account_id
}

data "aws_caller_identity" "current" {}

data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

data "aws_subnets" "private" {
  filter {
    name   = "tag:karpenter.sh/discovery"
    values = [var.cluster_name]
  }
}

data "aws_security_groups" "node" {
  filter {
    name   = "tag:karpenter.sh/discovery"
    values = [var.cluster_name]
  }
}

# identity + IAM
resource "castai_eks_clusterid" "this" {
  account_id   = local.account_id
  region       = var.region
  cluster_name = var.cluster_name
}

resource "castai_eks_user_arn" "this" {
  cluster_id = castai_eks_clusterid.this.id
}

module "castai_eks_role_iam" {
  source  = "castai/eks-role-iam/castai"
  version = "2.0.4"

  aws_account_id     = local.account_id
  aws_cluster_region = var.region
  aws_cluster_name   = var.cluster_name
  aws_cluster_vpc_id = data.aws_eks_cluster.this.vpc_config[0].vpc_id
  castai_user_arn    = castai_eks_user_arn.this.arn
  enable_ipv6        = false
}

# lets CAST AI nodes join
resource "aws_eks_access_entry" "castai_nodes" {
  cluster_name  = var.cluster_name
  principal_arn = module.castai_eks_role_iam.instance_profile_role_arn
  type          = "EC2_LINUX"
}

resource "castai_eks_cluster" "this" {
  account_id                 = local.account_id
  region                     = var.region
  name                       = var.cluster_name
  assume_role_arn            = module.castai_eks_role_iam.role_arn
  delete_nodes_on_disconnect = true

  depends_on = [aws_eks_access_entry.castai_nodes]
}
