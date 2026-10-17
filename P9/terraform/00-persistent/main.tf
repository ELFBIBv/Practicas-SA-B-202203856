# Capa persistente de Velero: SOBREVIVE a la destrucción del clúster (rúbrica
# 2.3). Vive en el mismo resource group que el backend de Terraform
# (rg-p9-tfstate), fuera del dominio de fallo de 01-cluster/02-platform.
#
# Quién administra qué (sin ciclos, ver P9/docs/diseno-velero.md §6):
#   - rg-p9-tfstate: lo crea bootstrap.sh con Azure CLI (lib/tfstate-backend.sh,
#     etapa 1). Este módulo NUNCA lo crea ni lo borra: solo lo lee con un data
#     source, igual que 02-platform lee el clúster de 01-cluster.
#   - Storage account, contenedor y UAMI: los crea y administra ESTE módulo.
#   - La federated identity credential (que ata la UAMI al Service Account
#     velero-server) NO vive aquí: necesita el emisor OIDC del clúster, que
#     todavía no existe cuando esta etapa corre por primera vez (corre ANTES
#     de 01-cluster). Vive en P9/terraform/02-platform/modules/velero, que
#     corre después de que el clúster ya existe. Ver P9/docs/diseno-velero.md
#     §1 ("Contradicción resuelta").

data "azurerm_resource_group" "persistent" {
  name = var.persistent_resource_group_name
}

data "azurerm_client_config" "current" {}

locals {
  # Nombre global único y estable: prefijo + hash de la suscripción, mismo
  # patrón que TFSTATE_STORAGE_ACCOUNT (lib/tfstate-backend.sh: "stp9tf" +
  # 12 hex de sha256(subscription_id)). Determinista: la siguiente
  # reconstrucción recalcula el mismo nombre sin tener que recordarlo.
  subscription_hash    = substr(sha256(lower(data.azurerm_client_config.current.subscription_id)), 0, 12)
  storage_account_name = "stp9velo${local.subscription_hash}"
}

resource "azurerm_storage_account" "velero" {
  name                     = local.storage_account_name
  resource_group_name      = data.azurerm_resource_group.persistent.name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS" # Standard_LRS

  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  # Autenticación por Workload Identity (RBAC de Entra ID), nunca por llave
  # compartida: coherente con "no exponer secretos" (CLAUDE.md) y con la
  # decisión de que Velero use Workload Identity, no un Secret con
  # accountKey/SAS. Ver P9/docs/diseno-velero.md §1.2.
  shared_access_key_enabled = false

  blob_properties {
    versioning_enabled = true
    delete_retention_policy {
      days = var.velero_storage_retention_days
    }
    container_delete_retention_policy {
      days = var.velero_storage_retention_days
    }
  }

  tags = {
    practica       = "p9"
    proposito      = "velero-backups"
    administrado   = "terraform-00-persistent"
    ciclo-de-vida  = "persistente"
    reconstruye-de = "P9/scripts/bootstrap.sh"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_container" "velero_backups" {
  name                  = var.velero_container_name
  storage_account_id    = azurerm_storage_account.velero.id
  container_access_type = "private"
}

resource "azurerm_user_assigned_identity" "velero" {
  name                = var.velero_uami_name
  resource_group_name = data.azurerm_resource_group.persistent.name
  location            = var.location

  tags = {
    practica  = "p9"
    proposito = "velero-workload-identity"
  }
}

# Permiso mínimo: solo sobre ESTE storage account, no sobre la suscripción ni
# el resource group persistente completo (que también contiene el backend de
# Terraform y el Key Vault de secretos).
resource "azurerm_role_assignment" "velero_storage" {
  scope                = azurerm_storage_account.velero.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.velero.principal_id
}

# Custodia de la llave de Sealed Secrets (P9/docs/diseno-secretos-dr.md §3.1).
# Vault dedicado -> el scope de un role assignment sobre él ya es mínimo
# privilegio: nadie necesita acceso a nada más en rg-p9-tfstate para leer o
# escribir esta llave.
resource "azurerm_key_vault" "sealed_secrets_custody" {
  name                = var.sealed_keyring_vault_name
  resource_group_name = data.azurerm_resource_group.persistent.name
  location            = var.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  # RBAC de Entra ID, no access policies: los role assignments de abajo son
  # la única fuente de permisos sobre este vault.
  rbac_authorization_enabled = true

  # Ni el propio Owner puede purgarlo antes de que expire la retención: si se
  # borra el vault por error, la llave de Sealed Secrets sigue siendo
  # recuperable durante 90 días.
  purge_protection_enabled   = true
  soft_delete_retention_days = 90

  tags = {
    practica  = "p9"
    proposito = "sealed-secrets-custody"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# Custodio: respalda la llave (P9/scripts/backup-sealed-secrets-key.sh). En
# esta práctica es la misma persona que "bootstrap", pero el rol se asigna
# por propósito, no por identidad: si mañana cambia quién ejecuta cada
# script, el modelo de permisos no necesita rediseñarse.
resource "azurerm_role_assignment" "sealed_secrets_custodian" {
  scope                = azurerm_key_vault.sealed_secrets_custody.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = var.custodian_object_id
}

# Bootstrap: solo lee la llave durante la reconstrucción
# (P9/scripts/restore-sealed-secrets-key.sh). Secrets User no permite listar
# ni administrar otros secretos del vault, solo leer los que ya conoce por
# nombre.
resource "azurerm_role_assignment" "sealed_secrets_bootstrap" {
  scope                = azurerm_key_vault.sealed_secrets_custody.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = var.bootstrap_object_id
}
