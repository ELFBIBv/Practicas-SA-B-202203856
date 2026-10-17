output "namespace" {
  value = var.namespace
}

output "service_account_name" {
  value = "velero-server"
}

output "app_version" {
  value = helm_release.velero.metadata.app_version
}
