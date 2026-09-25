variable "resource_group_name" {
  description = "Resource group del clúster (desechable). Distinto del RG del backend de estado."
  type        = string
}

variable "location" {
  description = "Región de Azure."
  type        = string
}

variable "cluster_name" {
  description = "Nombre del clúster AKS; también se usa como dns_prefix."
  type        = string
}

variable "kubernetes_version" {
  description = "Versión de Kubernetes. null usa la predeterminada de AKS en la región."
  type        = string
  default     = null
}

variable "node_vm_size" {
  description = "Tamaño de VM de los nodos."
  type        = string
}

variable "node_count" {
  description = "Cantidad de nodos. Mínimo 2: la prueba de pérdida de nodo drena uno."
  type        = number

  validation {
    condition     = var.node_count >= 2
    error_message = "Se requieren al menos 2 nodos para la prueba de drenaje (rúbrica 2.5)."
  }
}

variable "os_disk_size_gb" {
  description = "Disco de SO por nodo, en GB."
  type        = number
}

variable "availability_zones" {
  description = "Zonas de disponibilidad del node pool. null = sin zonas (regional)."
  type        = list(string)
  default     = null
}

variable "tags" {
  description = "Etiquetas comunes."
  type        = map(string)
  default     = {}
}
