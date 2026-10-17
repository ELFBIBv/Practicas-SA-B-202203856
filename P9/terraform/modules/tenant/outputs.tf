output "namespace" {
  description = "Namespace administrado por este Terraform."
  value       = kubernetes_namespace_v1.sa_platform.metadata[0].name
}

output "platform_quota_name" {
  value = kubernetes_resource_quota_v1.platform.metadata[0].name
}

output "viewer_service_account" {
  value = kubernetes_service_account_v1.viewer.metadata[0].name
}

output "operator_service_account" {
  value = kubernetes_service_account_v1.operator.metadata[0].name
}
