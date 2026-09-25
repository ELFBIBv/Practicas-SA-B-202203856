# Siembra del app-of-apps: dos AppProject y la Application raíz, instalados
# con el chart oficial argocd-apps. Se usa helm_release y no
# kubernetes_manifest porque este último consulta el CRD Application durante
# el plan, y en día cero ese CRD todavía no existe.
#
# Propiedad (quién administra qué):
#   Terraform (este módulo) -> AppProject p9-bootstrap, AppProject p9-platform,
#                              Application raíz.
#   Application raíz        -> solo las Applications hijas de <apps_path>.
#   Applications hijas      -> sus cargas (controladores, políticas, sa-platform).
# La raíz vive en el proyecto p9-bootstrap, que solo permite objetos
# Application en el namespace de ArgoCD. Aunque alguien agregue en Git un
# manifiesto de ArgoCD, de un AppProject o de la propia raíz, el sync se
# rechaza: la raíz no puede administrarse a sí misma, ni a sus proyectos, ni
# a ArgoCD.

locals {
  in_cluster = "https://kubernetes.default.svc"

  values = {
    projects = {
      (var.bootstrap_project) = {
        namespace   = var.argocd_namespace
        description = "Solo la Application raiz del app-of-apps de P9."
        sourceRepos = [var.repo_url]
        destinations = [{
          server    = local.in_cluster
          namespace = var.argocd_namespace
        }]
        clusterResourceWhitelist = []
        namespaceResourceWhitelist = [{
          group = "argoproj.io"
          kind  = "Application"
        }]
      }

      (var.platform_project) = {
        namespace = var.argocd_namespace
        # Sin ":" en description: el chart argocd-apps la inserta sin comillas
        # y un ":" rompe el YAML renderizado (verificado con helm template).
        description = "Aplicaciones hijas de P9 - controladores, politicas y sa-platform."
        sourceRepos = concat([var.repo_url], var.platform_helm_repos)
        destinations = [for ns in var.platform_namespaces : {
          server    = local.in_cluster
          namespace = ns
        }]
        # Los controladores instalan CRD, ClusterRoles, webhooks y
        # ClusterPolicies de Kyverno: necesitan recursos de clúster.
        clusterResourceWhitelist = [{
          group = "*"
          kind  = "*"
        }]
      }
    }

    applications = {
      (var.root_app_name) = {
        namespace = var.argocd_namespace
        project   = var.bootstrap_project
        source = {
          repoURL        = var.repo_url
          targetRevision = var.target_revision
          path           = var.apps_path
          directory      = { recurse = false }
        }
        destination = {
          server    = local.in_cluster
          namespace = var.argocd_namespace
        }
        syncPolicy = {
          automated = {
            prune    = true
            selfHeal = true
          }
          retry = {
            # H7 (P9/docs/diseno-sync-waves.md): con límite finito, ArgoCD deja
            # de reintentar la misma revisión al agotarse, incluso con
            # selfHeal, y exige un `Sync` manual. Ilimitado + backoff.
            limit = -1
            backoff = {
              duration    = "15s"
              factor      = 2
              maxDuration = "3m"
            }
          }
        }
      }
    }
  }
}

resource "helm_release" "seed" {
  name       = "p9-app-of-apps"
  namespace  = var.argocd_namespace
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.chart_version

  upgrade_install = true
  wait            = true
  timeout         = 300

  values = [yamlencode(local.values)]
}
