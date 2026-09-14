output "resource_quota_name" {
  value = kubernetes_resource_quota_v1.demo_app_capacity.metadata[0].name
}

output "resource_quota_namespace" {
  value = kubernetes_resource_quota_v1.demo_app_capacity.metadata[0].namespace
}

output "resource_quota_hard" {
  value = kubernetes_resource_quota_v1.demo_app_capacity.spec[0].hard
}
