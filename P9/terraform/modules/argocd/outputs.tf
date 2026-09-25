output "namespace" {
  value = helm_release.argocd.namespace
}

output "app_version" {
  description = "Versión de ArgoCD instalada."
  value       = helm_release.argocd.metadata.app_version
}
