variable "namespace" {
  type    = string
  default = "velero"
}

variable "chart_version" {
  description = "Versión del chart vmware-tanzu/velero. Fijada para reconstrucciones reproducibles. 12.2.0 = appVersion 1.18.2 (verificado en el índice del repo el 2026-09-24)."
  type        = string
  default     = "12.2.0"
}

variable "plugin_version" {
  description = "velero-plugin-for-microsoft-azure. v1.14.x es la versión compatible con Velero v1.18.x según la matriz de compatibilidad del propio plugin (verificado el 2026-09-24 contra github.com/vmware-tanzu/velero-plugin-for-microsoft-azure)."
  type        = string
  default     = "v1.14.3"
}

variable "aks_resource_group_name" {
  description = "RG del clúster (rg-p9-aks, DESECHABLE). Lo usa volumeSnapshotLocation.config.resourceGroup: ahí es donde el plugin de Azure busca/crea los snapshots de disco antes de que el data mover los mueva a Blob Storage."
  type        = string
}

variable "oidc_issuer_url" {
  description = "Emisor OIDC del clúster (data.azurerm_kubernetes_cluster.this.oidc_issuer_url en 02-platform/providers.tf). Solo existe una vez que 01-cluster ya aplicó: por eso la federated identity credential vive aquí y no en 00-persistent."
  type        = string
}

variable "velero_uami_id" {
  description = "ID de recurso de la UAMI de Velero (output velero_uami_id de 00-persistent)."
  type        = string
}

variable "velero_client_id" {
  description = "clientId de la UAMI de Velero (output velero_client_id de 00-persistent). Va en la anotación azure.workload.identity/client-id del ServiceAccount."
  type        = string
}

variable "storage_account_name" {
  description = "Cuenta de respaldos de Velero (output storage_account_name de 00-persistent)."
  type        = string
}

variable "storage_container_name" {
  type = string
}

variable "storage_resource_group_name" {
  description = "RG persistente donde vive la cuenta de respaldos (output resource_group_name de 00-persistent). Distinto de aks_resource_group_name a propósito: la BSL vive fuera del dominio de fallo del clúster."
  type        = string
}

variable "subscription_id" {
  description = "Suscripción de Azure, explícita y no hardcodeada (decisión de P9/docs/diseno-velero.md §1)."
  type        = string
}
