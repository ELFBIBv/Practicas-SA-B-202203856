# Velero lo instala Terraform, NO ArgoCD (P9/docs/diseno-velero.md §1, punto
# 3): necesita Workload Identity funcionando (ServiceAccount con la anotación
# correcta + federated credential) ANTES de que el pod arranque, porque el
# SDK de Azure lee AZURE_CLIENT_ID/AZURE_FEDERATED_TOKEN_FILE una sola vez al
# iniciar. Si ArgoCD creara el Deployment antes de que exista la federated
# credential, el primer arranque fallaría en autenticar contra el storage
# account y, según el caso, el Pod no reintentaría solo. Poniendo a Terraform
# como dueño se garantiza el orden con `depends_on` normal, sin inventar un
# hook de ArgoCD que reimplemente lo que Terraform ya hace mejor.
#
# La federated identity credential vive AQUÍ (no en 00-persistent) porque
# necesita el emisor OIDC real del clúster, que no existe hasta que 01-cluster
# ya se aplicó. 00-persistent corre ANTES de 01-cluster (así lo pide el
# contrato del bootstrap), así que no puede conocer ese valor todavía.

resource "azurerm_federated_identity_credential" "velero" {
  name                      = "fic-velero-server"
  user_assigned_identity_id = var.velero_uami_id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = var.oidc_issuer_url
  # Debe coincidir EXACTAMENTE con namespace/nombre del ServiceAccount que
  # crea el chart (serviceAccount.server.name, fijado abajo). El node-agent
  # (data mover) usa el MISMO ServiceAccount (verificado en
  # templates/node-agent-daemonset.yaml del chart: serviceAccountName:
  # {{ include "velero.serverServiceAccount" . }}), así que esta única
  # credencial federada cubre servidor y node-agent.
  subject = "system:serviceaccount:${var.namespace}:velero-server"
}

resource "helm_release" "velero" {
  name             = "velero"
  namespace        = var.namespace
  create_namespace = true
  repository       = "https://vmware-tanzu.github.io/helm-charts"
  chart            = "velero"
  version          = var.chart_version

  upgrade_install = true
  wait            = true
  timeout         = 600
  cleanup_on_fail = true

  # El Deployment y el DaemonSet deben nacer con la credencial ya federada.
  depends_on = [azurerm_federated_identity_credential.velero]

  values = [yamlencode({
    # H13 (P9/docs/diseno-sync-waves.md): sin Job PreSync/Helm hook con
    # imagen externa en el camino crítico; upgradeCRDs aquí solo controla el
    # Job propio del chart (esta release igual instala crds/ al aplicar).
    upgradeCRDs = false
    cleanUpCRDs = false

    # Sin Secret de credenciales: autenticación 100% por Workload Identity.
    credentials = { useSecret = false }

    serviceAccount = {
      server = {
        name = "velero-server"
        annotations = {
          "azure.workload.identity/client-id" = var.velero_client_id
        }
      }
    }
    # También hace falta en el DaemonSet de node-agent (values separado:
    # nodeAgent.podLabels, no podLabels): verificado en el chart, ambos
    # Pods (server y node-agent) comparten el mismo ServiceAccount pero
    # renderizan su label de Pod desde claves de values distintas.
    podLabels = {
      "azure.workload.identity/use" = "true"
    }
    nodeAgent = {
      podLabels = {
        "azure.workload.identity/use" = "true"
      }
      # Lee la configuración de abajo (el chart antepone "velero-" al nombre).
      extraArgs = ["--node-agent-configmap=velero-node-agent-config"]
    }

    # managed-csi es WaitForFirstConsumer. Sin ignoreDelayBinding, el data
    # mover espera a que un Pod consuma el PVC restaurado antes de bajar los
    # datos; pero el Job p9-data-restore (ola -10) espera el Restore antes de
    # que exista sa-platform (ola 0), su consumidor: abrazo mortal hasta el
    # timeout de 30 min de Velero y el bootstrap falla. Observado en la prueba
    # local del 2026-10-16 (Velero 1.18.2: "error to wait target PVC
    # consumed"). Con ignoreDelayBinding el volumen se crea sin esperar al Pod;
    # es seguro porque el node pool no es zonal (availability_zones = null en
    # 01-cluster): un disco regional se monta en cualquier nodo. Si se activan
    # zonas, revisar esta decisión (el disco podría quedar en otra zona).
    configMaps = {
      node-agent-config = {
        data = {
          "node-agent-config.json" = jsonencode({
            restorePVC = { ignoreDelayBinding = true }
          })
        }
      }
    }

    initContainers = [{
      name            = "velero-plugin-for-microsoft-azure"
      image           = "velero/velero-plugin-for-microsoft-azure:${var.plugin_version}"
      imagePullPolicy = "IfNotPresent"
      volumeMounts = [{
        mountPath = "/target"
        name      = "plugins"
      }]
    }]

    configuration = {
      # Comma-separated string (no lista): verificado contra values.yaml del
      # chart 12.2.0. Habilita el flujo de snapshot vía CSI VolumeSnapshot.
      features = "EnableCSI"

      backupStorageLocation = [{
        name     = "default" # data-restore.sh y el Lua health/bsl.lua esperan este nombre
        provider = "azure"
        bucket   = var.storage_container_name
        config = {
          resourceGroup  = var.storage_resource_group_name # RG persistente: fuera del dominio de fallo del clúster
          storageAccount = var.storage_account_name
          subscriptionId = var.subscription_id
          useAAD         = "true" # autenticación por token de Entra ID, nunca por llave de cuenta
        }
      }]

      volumeSnapshotLocation = [{
        name     = "default"
        provider = "azure"
        config = {
          # RG del CLÚSTER (rg-p9-aks), no el de nodos MC_*: decisión
          # explícita (P9/docs/diseno-velero.md §1.3). Con snapshotMoveData
          # el snapshot es efímero (el data mover copia el contenido a Blob
          # Storage de inmediato), así que no importa que este RG se destruya
          # junto con el clúster.
          resourceGroup = var.aks_resource_group_name
        }
      }]
    }

    # Data mover (CSI snapshot -> Blob Storage): lo exige la decisión de
    # Velero (CSI snapshot + data mover, nunca FSB puro) y el orden de olas
    # de P9/docs/diseno-sync-waves.md §0.7 (PVC y StatefulSet en la misma
    # ola: con FSB habría que restaurar el Pod antes que el volumen).
    deployNodeAgent  = true
    snapshotsEnabled = true

    # El Schedule NO se define aquí: vive en la Application GitOps
    # velero-schedules (ola 5). Si estuviera en esta release, un tick del
    # cron durante el propio bootstrap podría respaldar el namespace vacío.
    schedules = {}

    # Velero elige la VolumeSnapshotClass por la etiqueta
    # velero.io/csi-volumesnapshot-class, no por nombre. La que AKS crea por
    # defecto (csi-azuredisk-vsc) no la trae: sin esta clase, el backup de los
    # PVC de managed-csi termina PartiallyFailed ("failed to get
    # volumesnapshotclass for provisioner disk.csi.azure.com"). Delete es
    # suficiente: con snapshotMoveData el contenido ya se copió a Blob Storage
    # y el snapshot local es efímero (P9/docs/diseno-velero.md §1.3).
    extraObjects = [{
      apiVersion = "snapshot.storage.k8s.io/v1"
      kind       = "VolumeSnapshotClass"
      metadata = {
        name = "p9-velero-azuredisk"
        labels = {
          "velero.io/csi-volumesnapshot-class" = "true"
        }
      }
      driver         = "disk.csi.azure.com"
      deletionPolicy = "Delete"
      parameters = {
        incremental = "true"
      }
    }]
  })]
}
