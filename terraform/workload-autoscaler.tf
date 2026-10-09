# Module 11: rightsizing policy, ns shop
# off unless enable_workload_autoscaler=true
# needs phase=automation (WA installed)

variable "enable_workload_autoscaler" {
  # creates shop-rightsizing policy
  type    = bool
  default = false
}

resource "castai_workload_scaling_policy" "shop" {
  count = var.enable_workload_autoscaler ? 1 : 0

  cluster_id = castai_eks_cluster.this.id
  name       = "shop-rightsizing"
  apply_type = "IMMEDIATE"

  # enabled per workload instead
  # manual enable skips gradual caps
  management_option = "READ_ONLY"

  assignment_rules {
    rules {
      namespace {
        names = ["shop"]
      }
    }
  }

  cpu {
    function                 = "QUANTILE"
    args                     = ["0.8"]
    overhead                 = 0.1
    look_back_period_seconds = 10800 # 3h, the minimum

    apply_threshold_strategy {
      type       = "PERCENTAGE"
      percentage = 0.1
    }

    constraints {
      min {
        constant = 0.05 # cores
      }
    }

    # no limit changes
    limit {
      type = "KEEP_LIMITS"
    }
  }

  memory {
    function                 = "MAX"
    overhead                 = 0.1
    look_back_period_seconds = 10800

    apply_threshold_strategy {
      type       = "PERCENTAGE"
      percentage = 0.1
    }

    constraints {
      min {
        constant = 64 # MiB
      }
    }

    limit {
      type = "KEEP_LIMITS"
    }
  }

  # apply downscale now, not later
  downscaling {
    apply_type = "IMMEDIATE"
  }

  # OOM bumps applied now
  memory_event {
    apply_type = "IMMEDIATE"
  }

  lifecycle {
    precondition {
      condition     = local.automation
      error_message = "Workload Autoscaler needs -var phase=automation (castai-workload-autoscaler installed)."
    }
  }

  depends_on = [helm_release.castai]
}

output "workload_scaling_policy_name" {
  value = var.enable_workload_autoscaler ? castai_workload_scaling_policy.shop[0].name : ""
}
