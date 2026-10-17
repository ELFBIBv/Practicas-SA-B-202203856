variable "namespace" {
  description = "Namespace de la plataforma sa-platform: el mismo que usan el chart de Helm (values-azure.yaml) y la Application de ArgoCD."
  type        = string
  default     = "sa-p5"
}

variable "namespace_labels" {
  description = "Labels adicionales para el namespace, además de las que agrega este módulo."
  type        = map(string)
  default     = {}
}

# Cuota de nivel de PLATAFORMA (tenant): el techo dentro del cual el chart
# de Helm declara su propia cuota, más ajustada, en
# P9/charts/sa-platform/values-azure.yaml (bloque "quota:"). Son dos
# ResourceQuota distintas y coexisten sin conflicto: Kubernetes exige que
# todo pod satisfaga ambas a la vez. Ver P9/terraform/README.md para el
# razonamiento completo.
variable "platform_quota" {
  description = "Cuota de nivel de plataforma para el namespace."
  type = object({
    requests_cpu    = string
    requests_memory = string
    limits_cpu      = string
    limits_memory   = string
    pods            = string
    services        = string
    pvcs            = string
  })
  # Calculado contra la capacidad del clúster que crea
  # P9/terraform/modules/cluster (2 nodos Standard_DS2_v2): ~3.9 vCPU y ~10Gi de memoria
  # asignables en total, después de las reservas de sistema de AKS (antes
  # de contar lo que ya consumen coredns/metrics-server/CNI). Dejar
  # margen debajo de ese techo físico; ver P9/terraform/README.md.
  default = {
    requests_cpu    = "2500m"
    requests_memory = "6Gi"
    limits_cpu      = "3200m"
    limits_memory   = "8Gi"
    pods            = "40"
    services        = "20"
    pvcs            = "10"
  }
}

variable "platform_limit_range" {
  description = "Piso de seguridad a nivel de plataforma para cualquier contenedor del namespace que no declare sus propios límites. El chart de Helm ya declara los suyos, más ajustados; este es solo un respaldo."
  type = object({
    default_cpu            = string
    default_memory         = string
    default_request_cpu    = string
    default_request_memory = string
  })
  default = {
    default_cpu            = "1"
    default_memory         = "1Gi"
    default_request_cpu    = "100m"
    default_request_memory = "128Mi"
  }
}

variable "viewer_service_account" {
  description = "ServiceAccount con acceso de solo lectura (rol 'viewer') sobre el namespace: get/list/watch, sin permiso de escritura."
  type        = string
  default     = "sa-platform-viewer"
}

variable "operator_service_account" {
  description = "ServiceAccount con permiso adicional para intervenir manualmente un Rollout (promote/abort/retry vía 'kubectl argo rollouts'), rol 'operator'. No tiene acceso a Secrets ni puede borrar recursos."
  type        = string
  default     = "sa-platform-operator"
}
