# bootstrap.sh exporta TF_VAR_resource_group_name, TF_VAR_cluster_name y
# TF_VAR_location desde P9/scripts/lib/p9-config.sh, la misma fuente que usa
# 02-platform: los dos estados siempre hablan del mismo clúster.

variable "resource_group_name" {
  description = "RG del clúster (desechable)."
  type        = string
  default     = "rg-p9-aks"
}

variable "location" {
  description = "Región. chilecentral es donde P8 ya verificó cuota para 2x Standard_DS2_v2."
  type        = string
  default     = "chilecentral"
}

variable "cluster_name" {
  type    = string
  default = "aks-sa-p9"
}

variable "kubernetes_version" {
  type    = string
  default = null
}

# 2 vCPU / 7 GiB por nodo, 4 vCPU en total: cabe en la cuota regional de
# 6 vCPU típica de Azure for Students y deja 2 vCPU para el nodo extra
# (max_surge = 1) durante un upgrade. Es el tamaño con el que P8 ya
# corrió ArgoCD + Rollouts + Kyverno + Sealed Secrets + la plataforma.
variable "node_vm_size" {
  type    = string
  default = "Standard_DS2_v2"
}

variable "node_count" {
  type    = number
  default = 2
}

# 64 GB en vez de los 128 GB por defecto: el disco de SO es el segundo costo
# por nodo después de la VM y la plataforma no usa disco local.
variable "os_disk_size_gb" {
  type    = number
  default = 64
}

variable "availability_zones" {
  description = "Ej. [\"1\",\"2\"] si la región y el SKU tienen zonas. null por defecto: no todas las suscripciones de estudiante tienen DS2_v2 zonal en chilecentral."
  type        = list(string)
  default     = null
}
