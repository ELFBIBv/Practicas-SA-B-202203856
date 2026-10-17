# Etapa 2 del día cero: lo mínimo que Terraform instala DENTRO del clúster.
# Del resto se encarga ArgoCD.
#
#   1. tenant   : namespace sa-p5, cuotas, LimitRange y RBAC (heredado de P8).
#                 Va antes de la siembra para que el namespace ya exista
#                 cuando ArgoCD sincronice sa-platform. Si ArgoCD lo creara
#                 primero, el kubernetes_namespace de Terraform fallaría con
#                 "already exists".
#   2. argocd   : chart argo-cd; espera a que esté listo.
#   3. seed     : AppProjects + Application raíz. A partir de aquí todo es GitOps.

module "tenant" {
  source = "../modules/tenant"

  namespace = var.app_namespace
}

module "argocd" {
  source = "../modules/argocd"

  namespace     = var.argocd_namespace
  chart_version = var.argocd_chart_version
}

# [PUNTO DE INTEGRACIÓN CON VELERO] Lee lo que 00-persistent ya creó: storage
# account y UAMI. El nombre de la cuenta se recalcula con la MISMA fórmula
# determinista que P9/terraform/00-persistent/main.tf (local.storage_account_name):
# prefijo fijo + hash de la suscripción, sin pasar por terraform_remote_state
# (mismo patrón que data.azurerm_kubernetes_cluster.this en providers.tf).
data "azurerm_client_config" "current" {}

locals {
  velero_subscription_hash    = substr(sha256(lower(data.azurerm_client_config.current.subscription_id)), 0, 12)
  velero_storage_account_name = "stp9velo${local.velero_subscription_hash}"
}

data "azurerm_storage_account" "velero" {
  name                = local.velero_storage_account_name
  resource_group_name = var.persistent_resource_group_name
}

data "azurerm_user_assigned_identity" "velero" {
  name                = var.velero_uami_name
  resource_group_name = var.persistent_resource_group_name
}

# [PUNTO DE INTEGRACIÓN CON VELERO] Terraform instala Velero (no ArgoCD): ver
# P9/docs/diseno-velero.md §1 y P9/terraform/02-platform/modules/velero/main.tf.
# depends_on tenant: nada estricto lo exige, pero mantiene un único orden
# legible junto al resto del módulo.
module "velero" {
  source = "./modules/velero"

  namespace                   = "velero"
  chart_version               = var.velero_chart_version
  plugin_version              = var.velero_plugin_version
  aks_resource_group_name     = var.resource_group_name
  oidc_issuer_url             = data.azurerm_kubernetes_cluster.this.oidc_issuer_url
  velero_uami_id              = data.azurerm_user_assigned_identity.velero.id
  velero_client_id            = data.azurerm_user_assigned_identity.velero.client_id
  storage_account_name        = data.azurerm_storage_account.velero.name
  storage_container_name      = var.velero_container_name
  storage_resource_group_name = var.persistent_resource_group_name
  subscription_id             = data.azurerm_client_config.current.subscription_id

  depends_on = [module.tenant]
}

# [PUNTO DE INTEGRACIÓN CON SECRETOS]
# La llave del controlador de Sealed Secrets tiene que estar en kube-system
# ANTES de que exista ArgoCD. Si no, la Application hija "sealed-secrets"
# (wave -30) arranca el controlador, este genera una llave nueva y ningún
# SealedSecret del repo se puede descifrar. Esa reinyección NO vive en este
# Terraform: la ejecuta bootstrap.sh (etapa 4, restore-sealed-secrets-key.sh)
# entre el apply de 01-cluster y el de esta etapa. Así la llave nunca entra al
# tfstate y tampoco hace falta un provisioner local-exec.
# Ver P9/docs/diseño-secretos-dr.md §3.3.

module "seed" {
  source = "../modules/app-of-apps-seed"

  argocd_namespace = module.argocd.namespace
  chart_version    = var.argocd_apps_chart_version
  repo_url         = var.gitops_repo_url
  target_revision  = var.gitops_target_revision
  apps_path        = var.gitops_apps_path

  root_app_name     = var.root_app_name
  bootstrap_project = "p9-bootstrap"
  platform_project  = "p9-platform"

  # "velero" queda: la Application velero-schedules (ArgoCD, ola 5) crea el
  # Schedule en ese namespace. El propio operador de Velero ya NO es una
  # Application (lo instala Terraform, module.velero arriba), así que
  # "https://vmware-tanzu.github.io/helm-charts" salió de platform_helm_repos:
  # ninguna Application lo necesita.
  platform_namespaces = [var.app_namespace, "argo-rollouts", "kyverno", "kube-system", "velero"]
  platform_helm_repos = [
    "https://argoproj.github.io/argo-helm",
    "https://kyverno.github.io/kyverno",
    "https://bitnami.github.io/sealed-secrets",
  ]

  depends_on = [module.tenant, module.argocd]
}
