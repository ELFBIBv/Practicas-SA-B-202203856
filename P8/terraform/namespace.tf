resource "kubernetes_namespace" "sa_platform" {
  metadata {
    name = var.namespace

    labels = merge(
      {
        "app.kubernetes.io/managed-by" = "terraform"
        "practica"                     = "p8"
      },
      var.namespace_labels,
    )
  }
}
