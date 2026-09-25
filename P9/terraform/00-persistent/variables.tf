# bootstrap.sh exporta estas mismas variables como TF_VAR_* desde
# P9/scripts/lib/p9-config.sh (misma fuente que TFSTATE_RESOURCE_GROUP y
# TFSTATE_LOCATION en lib/tfstate-backend.sh): el resource group persistente y
# su región son UN SOLO valor en todo el repo, nunca duplicados.

variable "persistent_resource_group_name" {
  description = "RG persistente donde ya vive el backend de Terraform (rg-p9-tfstate). NO se crea aquí: lo asegura bootstrap.sh con Azure CLI antes de esta etapa; este módulo solo lo lee."
  type        = string
  default     = "rg-p9-tfstate"
}

variable "location" {
  description = "Misma región que el backend de Terraform."
  type        = string
  default     = "chilecentral"
}

variable "velero_storage_sku" {
  description = "SKU de la cuenta de respaldos de Velero. Standard_LRS: coherente con el backend de Terraform (mismo dominio de fallo aceptado, documentado como riesgo en P9/docs/diseno-velero.md)."
  type        = string
  default     = "Standard_LRS"
}

variable "velero_container_name" {
  type    = string
  default = "velero-backups"
}

variable "velero_uami_name" {
  description = "Identidad administrada asignada por el usuario que usa Velero (Workload Identity) para escribir en el storage account, sin llaves."
  type        = string
  default     = "id-sa-p9-velero"
}

# Días de versionado/soft-delete de la cuenta de respaldos: protege contra un
# `velero backup delete` accidental o una corrupción del blob, igual que en
# el backend de Terraform (lib/tfstate-backend.sh, TFSTATE_RETENTION_DAYS).
variable "velero_storage_retention_days" {
  type    = number
  default = 30
}

# --- Key Vault: custodia de la llave de Sealed Secrets (P9/docs/diseno-secretos-dr.md §3.1).
# bootstrap.sh y P9_KUBECONFIG/p9-config.sh ya asumen SEALED_KEYRING_VAULT=kv-sa-p9-202203856;
# faltaba crearlo. Vive aquí porque es, por definición, otro recurso que debe
# sobrevivir a la destrucción del clúster (el mismo motivo que el storage
# account de Velero).

variable "sealed_keyring_vault_name" {
  type    = string
  default = "kv-sa-p9-202203856"
}

# Sin default a propósito: no hay un valor "razonable" que adivinar, y un
# default silencioso podría terminar asignando roles sobre el vault a una
# identidad equivocada. Obténgalos con:
#   az ad signed-in-user show --query id -o tsv
# El mismo valor sirve para las dos variables si el custodio y quien ejecuta
# el bootstrap son la misma persona (caso típico de esta práctica); el diseño
# de secretos pide declararlos por separado para que el rol asignado quede
# documentado por su propósito (respaldo vs. lectura durante la
# reconstrucción), no por quién es hoy.
variable "custodian_object_id" {
  description = "Object ID de Entra ID de quien respalda la llave de Sealed Secrets (rol Key Vault Secrets Officer). Obtenerlo con: az ad signed-in-user show --query id -o tsv"
  type        = string
}

variable "bootstrap_object_id" {
  description = "Object ID de Entra ID de quien ejecuta bootstrap.sh y necesita leer la llave durante la reconstrucción (rol Key Vault Secrets User). Obtenerlo con: az ad signed-in-user show --query id -o tsv"
  type        = string
}
