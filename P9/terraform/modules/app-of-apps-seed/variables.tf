variable "argocd_namespace" {
  type = string
}

variable "chart_version" {
  description = "Versión del chart argocd-apps (argo-helm)."
  type        = string
}

variable "repo_url" {
  description = "Repositorio GitOps (sobrevive al desastre)."
  type        = string
}

variable "target_revision" {
  description = "Rama o tag del repositorio GitOps que sigue la raíz."
  type        = string
}

variable "apps_path" {
  description = "Carpeta del repo GitOps que contiene SOLO manifiestos Application hijos."
  type        = string
}

variable "root_app_name" {
  type = string
}

variable "bootstrap_project" {
  type = string
}

variable "platform_project" {
  type = string
}

variable "platform_namespaces" {
  description = "Namespaces donde las Applications hijas pueden desplegar."
  type        = list(string)
}

variable "platform_helm_repos" {
  description = "Repositorios de charts de terceros que pueden usar las hijas."
  type        = list(string)
}
