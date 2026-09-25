provider "azurerm" {
  features {}
}

# El clúster lo crea 01-cluster, en un apply anterior. Aquí se LEE con un data
# source: cuando se planifica esta etapa, el clúster ya existe y host y
# certificados son valores conocidos. Así se evita configurar providers con
# atributos "known after apply" de un recurso del mismo plan, que falla o usa
# credenciales viejas cuando el clúster se recrea.
data "azurerm_kubernetes_cluster" "this" {
  name                = var.cluster_name
  resource_group_name = var.resource_group_name
}

locals {
  kube = data.azurerm_kubernetes_cluster.this.kube_config[0]
}

provider "kubernetes" {
  host                   = local.kube.host
  client_certificate     = base64decode(local.kube.client_certificate)
  client_key             = base64decode(local.kube.client_key)
  cluster_ca_certificate = base64decode(local.kube.cluster_ca_certificate)
}

provider "helm" {
  kubernetes = {
    host                   = local.kube.host
    client_certificate     = base64decode(local.kube.client_certificate)
    client_key             = base64decode(local.kube.client_key)
    cluster_ca_certificate = base64decode(local.kube.cluster_ca_certificate)
  }
}
