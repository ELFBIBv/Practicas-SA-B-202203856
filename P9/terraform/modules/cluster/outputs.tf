output "cluster_name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "resource_group_name" {
  value = azurerm_resource_group.aks.name
}

output "node_resource_group" {
  value = azurerm_kubernetes_cluster.this.node_resource_group
}

output "kubernetes_version" {
  description = "Versión real de Kubernetes del clúster creado."
  value       = azurerm_kubernetes_cluster.this.current_kubernetes_version
}

output "oidc_issuer_url" {
  description = "Emisor OIDC para credenciales federadas (Velero / Workload Identity)."
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "gateway_public_ip" {
  description = "IP pública del gateway (cambia tras una reconstrucción; el nombre no)."
  value       = azurerm_public_ip.gateway.ip_address
}

output "gateway_public_ip_name" {
  value = azurerm_public_ip.gateway.name
}
