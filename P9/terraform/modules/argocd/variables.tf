variable "namespace" {
  type    = string
  default = "argocd"
}

variable "chart_version" {
  description = "Versión del chart argo-cd (argo-helm). Fijada para reconstrucciones reproducibles."
  type        = string
}
