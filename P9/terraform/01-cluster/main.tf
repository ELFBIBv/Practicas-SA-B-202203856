# Etapa 1 del día cero: solo infraestructura de Azure. Estado propio
# (p9/01-cluster.tfstate), separado del de 02-platform para que los providers
# kubernetes/helm nunca se configuren con valores desconocidos de un clúster
# que todavía no existe. Ver P9/docs/terraform-dia-cero.md.

module "cluster" {
  source = "../modules/cluster"

  resource_group_name = var.resource_group_name
  location            = var.location
  cluster_name        = var.cluster_name
  kubernetes_version  = var.kubernetes_version
  node_vm_size        = var.node_vm_size
  node_count          = var.node_count
  os_disk_size_gb     = var.os_disk_size_gb
  availability_zones  = var.availability_zones

  tags = {
    practica       = "p9"
    administrado   = "terraform"
    ciclo-de-vida  = "desechable"
    reconstruye-de = "P9/scripts/bootstrap.sh"
  }
}
