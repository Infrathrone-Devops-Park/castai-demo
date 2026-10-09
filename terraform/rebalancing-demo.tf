# Module 09: scheduled rebalancing, off.

variable "enable_rebalancing_schedule" {
  type    = bool
  default = false
}

variable "rebalancing_job_enabled" {
  # schedule exists, job paused
  type    = bool
  default = false
}

# org-wide object
resource "castai_rebalancing_schedule" "batch" {
  count = var.enable_rebalancing_schedule ? 1 : 0

  name = "castai-demo-batch-to-spot"

  schedule {
    cron = "*/10 * * * *"
  }

  # tiny cluster: low threshold
  trigger_conditions {
    savings_percentage = 5
  }

  launch_configuration {
    node_ttl_seconds          = 300
    num_targeted_nodes        = 1
    rebalancing_min_nodes     = 1
    evict_gracefully          = true
    split_nodes_in_batches_of = 1

    # only batch template nodes
    selector = jsonencode({
      nodeSelectorTerms = [{
        matchExpressions = [{
          key      = "scheduling.cast.ai/node-template"
          operator = "In"
          values   = ["batch"]
        }]
      }]
    })

    execution_conditions {
      enabled                     = true
      achieved_savings_percentage = 5
    }
  }
}

resource "castai_rebalancing_job" "batch" {
  count = var.enable_rebalancing_schedule ? 1 : 0

  cluster_id              = castai_eks_cluster.this.id
  rebalancing_schedule_id = castai_rebalancing_schedule.batch[0].id
  enabled                 = var.rebalancing_job_enabled
}

output "rebalancing_schedule_id" {
  value = var.enable_rebalancing_schedule ? castai_rebalancing_schedule.batch[0].id : ""
}
