provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kube_context
}

resource "kubernetes_resource_quota_v1" "demo_app_capacity" {
  metadata {
    name      = "demo-app-capacity"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/part-of"    = "platform-demo"
      "app.kubernetes.io/managed-by" = "terraform"
      "platform.engineering/owner"   = "terraform"
    }
  }

  spec {
    hard = {
      "requests.cpu"    = var.requests_cpu
      "requests.memory" = var.requests_memory
      "limits.cpu"      = var.limits_cpu
      "limits.memory"   = var.limits_memory
      "pods"            = tostring(var.pod_limit)
    }
  }
}
