# Rol de solo lectura: puede inspeccionar el estado del namespace (pods,
# deployments, Rollouts, CronJobs) pero no puede modificar ni borrar nada.
resource "kubernetes_service_account" "viewer" {
  metadata {
    name      = var.viewer_service_account
    namespace = kubernetes_namespace.sa_platform.metadata[0].name
  }
}

resource "kubernetes_role" "viewer" {
  metadata {
    name      = "sa-platform-viewer"
    namespace = kubernetes_namespace.sa_platform.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "services", "configmaps", "persistentvolumeclaims", "events"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "statefulsets", "replicasets"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["batch"]
    resources  = ["cronjobs", "jobs"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["argoproj.io"]
    resources  = ["rollouts", "analysisruns", "analysistemplates"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding" "viewer" {
  metadata {
    name      = "sa-platform-viewer-binding"
    namespace = kubernetes_namespace.sa_platform.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.viewer.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.viewer.metadata[0].name
    namespace = kubernetes_namespace.sa_platform.metadata[0].name
  }
}

# Rol de operación: además de lo anterior, puede intervenir manualmente un
# Rollout (promote/abort/retry, vía "kubectl argo rollouts" o parcheando
# rollouts/status) para contener un despliegue defectuoso a mano si hiciera
# falta. Sigue sin acceso a Secrets ni permiso de borrado.
resource "kubernetes_service_account" "operator" {
  metadata {
    name      = var.operator_service_account
    namespace = kubernetes_namespace.sa_platform.metadata[0].name
  }
}

resource "kubernetes_role" "operator" {
  metadata {
    name      = "sa-platform-operator"
    namespace = kubernetes_namespace.sa_platform.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "services", "configmaps", "persistentvolumeclaims", "events"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "statefulsets", "replicasets"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["batch"]
    resources  = ["cronjobs", "jobs"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["argoproj.io"]
    resources  = ["rollouts", "rollouts/status", "analysisruns", "analysistemplates"]
    verbs      = ["get", "list", "watch", "patch"]
  }
}

resource "kubernetes_role_binding" "operator" {
  metadata {
    name      = "sa-platform-operator-binding"
    namespace = kubernetes_namespace.sa_platform.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.operator.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.operator.metadata[0].name
    namespace = kubernetes_namespace.sa_platform.metadata[0].name
  }
}
