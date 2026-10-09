# Modules 07, 09: second template.
# Off by default; modules pass -var.

variable "enable_batch_template" {
  # module 07 and 09
  type    = bool
  default = false
}

variable "batch_spot" {
  # false on-demand, true spot
  type    = bool
  default = false
}

# like a second, tainted NodePool
resource "castai_node_template" "batch" {
  count = var.enable_batch_template ? 1 : 0

  cluster_id       = castai_eks_cluster.this.id
  name             = "batch"
  configuration_id = castai_node_configuration.default.id
  is_enabled       = true
  should_taint     = true

  # two labels: partial matching demo
  custom_labels = {
    workload = "batch"
    team     = "data"
  }

  custom_taints {
    key    = "workload"
    value  = "batch"
    effect = "NoSchedule"
  }

  constraints {
    architectures       = ["amd64"]
    os                  = ["linux"]
    min_cpu             = 2
    max_cpu             = 2
    on_demand           = !var.batch_spot
    spot                = var.batch_spot
    use_spot_fallbacks  = false
    burstable_instances = "disabled"

    instance_families {
      include = ["c6a", "c5a", "m6a", "m5a"]
    }

    # quota guard: max two nodes
    resource_limits {
      cpu_limit_enabled   = true
      cpu_limit_max_cores = 4
    }
  }
}

output "batch_template_offering" {
  value = var.enable_batch_template ? (var.batch_spot ? "spot" : "on-demand") : "disabled"
}
