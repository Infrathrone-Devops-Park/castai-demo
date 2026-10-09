# like EC2NodeClass
resource "castai_node_configuration" "default" {
  cluster_id     = castai_eks_cluster.this.id
  name           = "default"
  subnets        = data.aws_subnets.private.ids
  min_disk_size  = 30
  disk_cpu_ratio = 0

  tags = {
    "castai-demo" = "managed"
    Project       = "castai-demo"
  }

  eks {
    instance_profile_arn = module.castai_eks_role_iam.instance_profile_arn
    security_groups = concat(
      [data.aws_eks_cluster.this.vpc_config[0].cluster_security_group_id],
      data.aws_security_groups.node.ids
    )
    eks_image_family = "al2023"
    imds_v1          = false
    volume_type      = "gp3"
  }
}

resource "castai_node_configuration_default" "this" {
  cluster_id       = castai_eks_cluster.this.id
  configuration_id = castai_node_configuration.default.id
}

# like NodePool
resource "castai_node_template" "default" {
  cluster_id       = castai_eks_cluster.this.id
  name             = "default-by-castai"
  configuration_id = castai_node_configuration.default.id
  is_enabled       = true
  should_taint     = false

  constraints {
    architectures                 = ["amd64"]
    os                            = ["linux"]
    min_cpu                       = 2
    max_cpu                       = 4
    spot                          = true
    on_demand                     = false
    use_spot_fallbacks            = true
    fallback_restore_rate_seconds = 1800

    # quota guard: 8 spot vCPU
    resource_limits {
      cpu_limit_enabled   = true
      cpu_limit_max_cores = 8
    }
  }
}

resource "castai_autoscaler_policies" "this" {
  cluster_id  = castai_eks_cluster.this.id
  enabled     = var.autoscaler_enabled
  scoped_mode = false

  # counts system node too
  cluster_limits {
    enabled = true
    cpu {
      max_cores = 10
    }
  }

  node_downscaler {
    empty_nodes_enabled = true
    empty_nodes_delay   = "60s"
  }

  unschedulable_pods {
    enabled = true
    pod_pinner {
      enabled = true
    }
  }

  depends_on = [helm_release.castai]
}

resource "castai_evictor" "this" {
  cluster_id                = castai_eks_cluster.this.id
  enabled                   = var.autoscaler_enabled
  dry_run                   = false
  aggressive_mode           = false
  scoped_mode               = true
  cycle_interval            = "60s"
  node_grace_period_minutes = 5

  depends_on = [helm_release.castai]
}
