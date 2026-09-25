output "root_application" {
  description = "Application raíz del app-of-apps (namespace/nombre)."
  value       = "${module.argocd.namespace}/${module.seed.root_app_name}"
}

output "argocd_version" {
  value = module.argocd.app_version
}

output "app_namespace" {
  value = module.tenant.namespace
}
