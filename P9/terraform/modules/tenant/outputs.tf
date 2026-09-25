output "namespace" {
  description = "Namespace administrado por este Terraform."
  value       = kubernetes_namespace.sa_platform.metadata[0].name
}

output "platform_quota_name" {
  value = kubernetes_resource_quota.platform.metadata[0].name
}

output "viewer_service_account" {
  value = kubernetes_service_account.viewer.metadata[0].name
}

output "operator_service_account" {
  value = kubernetes_service_account.operator.metadata[0].name
}
