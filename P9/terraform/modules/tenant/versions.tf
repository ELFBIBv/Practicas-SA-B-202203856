# Namespace, cuotas, límites y RBAC de la plataforma (heredado de P8). El
# provider kubernetes lo configura el módulo raíz 02-platform contra el
# clúster recién creado; este módulo no conoce kubeconfigs.
terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}
