output "resource_group_name" {
  description = "RG persistente donde viven el storage account y la UAMI de Velero. Lo usa el BackupStorageLocation (config.resourceGroup)."
  value       = data.azurerm_resource_group.persistent.name
}

output "storage_account_name" {
  value = azurerm_storage_account.velero.name
}

output "container_name" {
  value = azurerm_storage_container.velero_backups.name
}

output "velero_uami_id" {
  description = "ID de recurso de la UAMI: lo necesita azurerm_federated_identity_credential en 02-platform/modules/velero (user_assigned_identity_id)."
  value       = azurerm_user_assigned_identity.velero.id
}

output "velero_client_id" {
  value = azurerm_user_assigned_identity.velero.client_id
}

output "velero_tenant_id" {
  value = azurerm_user_assigned_identity.velero.tenant_id
}

output "velero_principal_id" {
  description = "Solo para verificación/diagnóstico (confirmar el role assignment); no hace falta para el bootstrap."
  value       = azurerm_user_assigned_identity.velero.principal_id
}

output "key_vault_name" {
  description = "Nombre del vault de custodia (kv-sa-p9-202203856). Lo usan backup-sealed-secrets-key.sh y restore-sealed-secrets-key.sh vía SEALED_KEYRING_VAULT."
  value       = azurerm_key_vault.sealed_secrets_custody.name
}

output "key_vault_uri" {
  description = "Solo para verificación (az keyvault show); ningún script lo necesita: az keyvault secret ... funciona con --vault-name."
  value       = azurerm_key_vault.sealed_secrets_custody.vault_uri
}
