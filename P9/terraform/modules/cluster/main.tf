# Clúster AKS de P9. Todo lo que vive aquí se considera DESECHABLE: se destruye
# en la prueba de DR y se recrea desde cero con bootstrap.sh. Nada que deba
# sobrevivir al desastre (estado de Terraform, respaldos de Velero, llave de
# Sealed Secrets) puede vivir en este resource group ni en el de nodos.

resource "azurerm_resource_group" "aks" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_kubernetes_cluster" "this" {
  name                = var.cluster_name
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  dns_prefix          = var.cluster_name
  node_resource_group = "${var.resource_group_name}-nodes"

  # null = versión por defecto de AKS en la región al momento de crear. Tras
  # un desastre, una versión fijada puede haber salido de soporte y bloquear
  # la reconstrucción; la versión real se publica en el output
  # kubernetes_version para la evidencia.
  kubernetes_version = var.kubernetes_version

  # Free: plano de control sin costo ni SLA. Suficiente para la práctica.
  sku_tier = "Free"

  # Credenciales locales (certificado de cliente) habilitadas: el módulo
  # 02-platform y bootstrap.sh las obtienen con la sesión de Azure del
  # operador sin exigir kubelogin. Ver P9/docs/terraform-dia-cero.md.
  local_account_disabled            = false
  role_based_access_control_enabled = true

  # Emisor OIDC + Workload Identity: permiten que Velero (y External Secrets,
  # si se adopta) accedan a Azure con identidades federadas, sin llaves
  # estáticas en el clúster. Sin costo adicional.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  default_node_pool {
    name                        = "system"
    vm_size                     = var.node_vm_size
    node_count                  = var.node_count
    os_disk_size_gb             = var.os_disk_size_gb
    os_disk_type                = "Managed"
    zones                       = var.availability_zones
    temporary_name_for_rotation = "tmpsystem"

    upgrade_settings {
      max_surge = "1"
    }
  }

  # azurerm 5.x lo exige. Manual = node pool fijo de arriba, sin Node Auto
  # Provisioning (Karpenter): el costo y la cantidad de nodos quedan acotados
  # y son predecibles.
  node_provisioning_profile {
    mode = "Manual"
  }

  # Identidad administrada del plano de control: sin service principal ni
  # secreto que rotar o custodiar.
  identity {
    type = "SystemAssigned"
  }

  # Misma red que P8 (Azure CNI overlay + Cilium): las NetworkPolicy del chart
  # necesitan un motor de políticas; Cilium lo trae sin componentes extra. No
  # hace falta VNet propia: AKS crea la suya en el RG de nodos y la destruye
  # junto con el clúster.
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer"
  }

  tags = var.tags
}
