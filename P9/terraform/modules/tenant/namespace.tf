resource "kubernetes_namespace_v1" "sa_platform" {
  metadata {
    name = var.namespace

    labels = merge(
      {
        "app.kubernetes.io/managed-by" = "terraform"
        "practica"                     = "p9"
      },
      var.namespace_labels,
    )
  }
}
