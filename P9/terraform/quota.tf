resource "kubernetes_resource_quota" "platform" {
  metadata {
    name      = "${var.namespace}-platform-quota"
    namespace = kubernetes_namespace.sa_platform.metadata[0].name
  }

  spec {
    hard = {
      "requests.cpu"           = var.platform_quota.requests_cpu
      "requests.memory"        = var.platform_quota.requests_memory
      "limits.cpu"             = var.platform_quota.limits_cpu
      "limits.memory"          = var.platform_quota.limits_memory
      "pods"                   = var.platform_quota.pods
      "services"               = var.platform_quota.services
      "persistentvolumeclaims" = var.platform_quota.pvcs
    }
  }
}

resource "kubernetes_limit_range" "platform" {
  metadata {
    name      = "${var.namespace}-platform-limits"
    namespace = kubernetes_namespace.sa_platform.metadata[0].name
  }

  spec {
    limit {
      type = "Container"

      default = {
        cpu    = var.platform_limit_range.default_cpu
        memory = var.platform_limit_range.default_memory
      }

      default_request = {
        cpu    = var.platform_limit_range.default_request_cpu
        memory = var.platform_limit_range.default_request_memory
      }
    }
  }
}
