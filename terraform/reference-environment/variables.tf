variable "kubeconfig_path" {
  description = "Path to kubeconfig used by the local reference environment."
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "kubectl context for the local reference environment."
  type        = string
  default     = "docker-desktop"
}

variable "namespace" {
  description = "Existing application namespace. Namespace ownership remains outside this Terraform module."
  type        = string
  default     = "demo-app"
}

variable "requests_cpu" {
  description = "Namespace CPU request budget."
  type        = string
  default     = "2"
}

variable "requests_memory" {
  description = "Namespace memory request budget."
  type        = string
  default     = "2Gi"
}

variable "limits_cpu" {
  description = "Namespace CPU limit budget."
  type        = string
  default     = "6"
}

variable "limits_memory" {
  description = "Namespace memory limit budget."
  type        = string
  default     = "6Gi"
}

variable "pod_limit" {
  description = "Maximum Pods allowed in the namespace."
  type        = number
  default     = 40
}
