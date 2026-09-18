terraform {
  required_version = ">= 1.5.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
  }
}

# Este Terraform NO crea el clúster de AKS (eso se sigue haciendo con
# `az aks create`, documentado en P8/README.md). Su alcance es exactamente
# el que pide el enunciado: namespaces, cuotas, límites y RBAC *dentro* de
# un clúster que ya existe y al que ya se está autenticado localmente
# (`az aks get-credentials`).
provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kube_context
}
