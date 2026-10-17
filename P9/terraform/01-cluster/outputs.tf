output "cluster_name" {
  value = module.cluster.cluster_name
}

output "resource_group_name" {
  value = module.cluster.resource_group_name
}

output "node_resource_group" {
  value = module.cluster.node_resource_group
}

output "kubernetes_version" {
  value = module.cluster.kubernetes_version
}

output "oidc_issuer_url" {
  value = module.cluster.oidc_issuer_url
}

output "gateway_public_ip" {
  value = module.cluster.gateway_public_ip
}

output "gateway_public_ip_name" {
  value = module.cluster.gateway_public_ip_name
}
