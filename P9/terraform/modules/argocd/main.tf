# ArgoCD instalado por Terraform (exigencia del enunciado) con el chart
# oficial. Terraform es su ÚNICO dueño: ninguna Application del repo GitOps
# administra ArgoCD, así el app-of-apps no puede reconfigurar o desinstalar
# el controlador que lo ejecuta.

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = var.namespace
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.chart_version

  # Idempotencia: si el estado se perdió pero la release existe en el
  # clúster, se actualiza en vez de fallar con "cannot re-use a name".
  upgrade_install = true

  # Terraform no termina hasta que los Deployments/StatefulSet estén listos:
  # la etapa siguiente (siembra del app-of-apps) necesita los CRD y el
  # controlador funcionando.
  wait            = true
  timeout         = 900
  cleanup_on_fail = true

  values = [yamlencode({
    # CRD fuera del ciclo de vida de la release: desinstalar ArgoCD no borra
    # las Applications en cascada.
    crds = { keep = true }

    # Componentes que el flujo no usa: menos consumo en 2 nodos pequeños.
    dex           = { enabled = false }
    notifications = { enabled = false }

    configs = {
      cm = {
        # Desde ArgoCD 1.8 una Application no tiene health propio (H2). El Lua
        # que solo copia status.health no basta: los hooks y los recursos
        # Missing no cuentan ahi (H5), asi que una hija con su Job de
        # restauracion en curso ya se veria Healthy y la raiz avanzaria de
        # ola sin esperarla (perdida silenciosa de datos, ver
        # P9/docs/diseno-sync-waves.md §0.1 y §3.1). Los otros 3 Lua son
        # backport de health que ArgoCD v3.6 trae y v3.5.3 (la version
        # instalada, argo-cd 10.9.2) no tiene, para kyverno.io/ClusterPolicy y
        # velero.io/Schedule, mas un HPA mas tolerante a la falta transitoria
        # de metricas. NO hay Lua para velero.io/BackupStorageLocation: el
        # operador de Velero (y su BSL) lo instala Terraform, no ArgoCD
        # (P9/docs/diseno-velero.md §1), asi que ninguna Application expone
        # ese recurso y el Lua quedaria inerte.
        "resource.customizations.health.argoproj.io_Application"             = file("${path.module}/health/application.lua")
        "resource.customizations.health.kyverno.io_ClusterPolicy"            = file("${path.module}/health/clusterpolicy.lua")
        "resource.customizations.health.velero.io_Schedule"                  = file("${path.module}/health/schedule.lua")
        "resource.customizations.health.autoscaling_HorizontalPodAutoscaler" = file("${path.module}/health/hpa.lua")
      }
      params = {
        # H9: en v3 el health de cada recurso ya no se guarda en
        # .status.resources[].health por defecto. Con esto en "true", el
        # diagnóstico de una ola detenida (P9/docs/diseno-sync-waves.md §6.3)
        # se puede hacer con kubectl, sin iniciar sesión en argocd-server.
        "controller.resource.health.persist" = "true"
      }
      # El repositorio GitOps es público: no se declaran credenciales.
      # [PUNTO DE INTEGRACIÓN CON SECRETOS] si el repo pasa a ser privado,
      # su credencial (deploy key o GitHub App) debe llegar como Secret con
      # label argocd.argoproj.io/secret-type=repository desde el almacén de
      # secretos, nunca desde este archivo ni desde variables de Terraform.
    }
  })]
}
