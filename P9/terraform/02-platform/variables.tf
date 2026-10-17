# resource_group_name, cluster_name y gitops_*: bootstrap.sh los exporta como
# TF_VAR_* desde P9/scripts/lib/p9-config.sh (misma fuente que 01-cluster).

variable "resource_group_name" {
  type    = string
  default = "rg-p9-aks"
}

variable "cluster_name" {
  type    = string
  default = "aks-sa-p9"
}

variable "app_namespace" {
  description = "Namespace de sa-platform (heredado de P8)."
  type        = string
  default     = "sa-p5"
}

variable "argocd_namespace" {
  type    = string
  default = "argocd"
}

variable "argocd_chart_version" {
  description = "argo-cd 10.9.2 = ArgoCD v3.5.3."
  type        = string
  default     = "10.9.2"
}

variable "argocd_apps_chart_version" {
  type    = string
  default = "2.0.5"
}

variable "gitops_repo_url" {
  description = "Repositorio GitOps público; sobrevive al desastre (prerrequisito externo)."
  type        = string
  default     = "https://github.com/ELFBIBv/Practicas-SA-B-202203856-gitops.git"
}

variable "gitops_target_revision" {
  type    = string
  default = "main"
}

variable "gitops_apps_path" {
  description = "Carpeta del repo GitOps con las Applications hijas (fuente: P9/gitops/apps en el repo de código)."
  type        = string
  default     = "apps"
}

variable "root_app_name" {
  type    = string
  default = "p9-root"
}

# --- Velero: capa persistente (P9/terraform/00-persistent), leída aquí con
# data sources (mismo patrón que data.azurerm_kubernetes_cluster.this en
# providers.tf: cada etapa LEE lo que otra etapa ya creó, sin
# terraform_remote_state). Deben coincidir con 00-persistent/variables.tf.

variable "persistent_resource_group_name" {
  description = "RG persistente donde 00-persistent creó el storage account y la UAMI de Velero (rg-p9-tfstate)."
  type        = string
  default     = "rg-p9-tfstate"
}

variable "velero_uami_name" {
  type    = string
  default = "id-sa-p9-velero"
}

variable "velero_container_name" {
  type    = string
  default = "velero-backups"
}

variable "velero_chart_version" {
  type    = string
  default = "12.2.0" # appVersion 1.18.2
}

variable "velero_plugin_version" {
  type    = string
  default = "v1.14.3" # compatible con Velero v1.18.x
}
