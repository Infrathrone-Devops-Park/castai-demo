variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "aws_profile" {
  type    = string
  default = "infrathrone-demo"
}

variable "cluster_name" {
  type    = string
  default = "karpenter-demo"
}

variable "castai_api_token" {
  # set via TF_VAR_castai_api_token
  type      = string
  sensitive = true
}

variable "castai_api_url" {
  type    = string
  default = "https://api.cast.ai"
}

variable "phase" {
  # readonly | automation
  type    = string
  default = "readonly"

  validation {
    condition     = contains(["readonly", "automation"], var.phase)
    error_message = "phase must be readonly or automation."
  }
}

variable "autoscaler_enabled" {
  # off until Karpenter drained
  type    = bool
  default = false
}

variable "castai_chart_version" {
  type    = string
  default = "0.43.311"
}
