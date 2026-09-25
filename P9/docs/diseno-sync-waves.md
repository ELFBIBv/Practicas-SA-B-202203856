# Diseño: sync waves del app-of-apps de P9

**Estado:** diseño **pendiente**.
- No ejecuté nada contra Azure, AKS ni el repositorio GitOps.
- No modifiqué `P9/gitops/`, `P9/charts/`, `P9/terraform/` ni `P9/scripts/`, porque los diseños de secretos y de Velero trabajan en paralelo sobre esos archivos.
- La §7 lista archivo por archivo cada cambio que propone este diseño.

**Hechos verificados el 2026-09-24 contra el código fuente**, no contra la memoria. La versión de referencia es ArgoCD **v3.5.3**, la que instala `terraform/02-platform` (`argocd_chart_version = 10.9.2`).

| # | Hecho | Fuente |
|---|---|---|
| H1 | En v3.5.3 **no** hay health integrado para `kyverno.io/ClusterPolicy` ni para `velero.io/Backup`, `Restore` y `Schedule`. Se agregaron en v3.6.0-rc1 (commits del 2026-09-03 y 2026-09-04). `velero.io/BackupStorageLocation` no tiene health en ninguna versión. | `argo-cd/resource_customizations/` en los tags `v3.5.3` y `v3.6.0-rc1` |
| H2 | `argoproj.io/Application` solo tiene `actions/`; no tiene `health.lua`. | ídem |
| H3 | Sí traen health integrado: `SealedSecret`, `Rollout`, `CustomResourceDefinition`, `Job`, `CronJob`, `PersistentVolumeClaim`, `HorizontalPodAutoscaler` y `Service`. | `resource_customizations/` y `gitops-engine/pkg/health/` (v3.5.3) |
| H4 | Una ola cierra solo cuando cada recurso que no es hook está `Healthy`. <br>• `Degraded` hace fallar la operación de sync. <br>• `Progressing` y `Suspended` la dejan esperando. <br>• Un recurso sin health (Secret, ConfigMap, RBAC) cuenta como éxito inmediato. | `gitops-engine/pkg/sync/sync_context.go` (v3.5.3) |
| H5 | Los hooks y los recursos `Missing` **no** cuentan en el health agregado de una Application. En una Application raíz, las hijas en `Missing` o `Unknown` tampoco cuentan. | `controller/health.go` (v3.5.3), `setApplicationHealth` |
| H6 | Estados de health integrados que importan aquí: <br>• PVC `Pending` = `Progressing`. <br>• HPA con `AbleToScale/FailedGetScale` o `ScalingActive/FailedGet*Metric` = `Degraded`. <br>• Service `LoadBalancer` sin IP = `Progressing`. | `gitops-engine/pkg/health/health_{pvc,hpa,service}.go` |
| H7 | Cuando se agota `retry.limit`, auto-sync **no reintenta la misma revisión**, ni siquiera con `selfHeal`. El log dice "Skipping auto-sync: failed previous sync attempt … will not retry". <br>• `retry.limit` negativo = reintentos ilimitados. <br>• `controller.sync.timeout.seconds` vale `"0"` por defecto, es decir, sin timeout. | `controller/appcontroller.go`, `docs/operator-manual/application.yaml`, `argocd-cmd-params-cm.yaml` |
| H8 | `Delete=false` se puede declarar en `syncOptions` de la Application completa. `argocd app delete` hace **cascada por defecto**. | `docs/user-guide/sync-options.md`, `argocd_app_delete.md` |
| H9 | En v3 el health de cada recurso ya no se guarda en `.status.resources[].health` (`controller.resource.health.persist: "false"`). | `argocd-cmd-params-cm.yaml` (v3.5.3) |
| H10 | La restauración FSB de Velero escribe los datos mediante un init container **en el Pod restaurado**. Sin Pod en el restore, no hay datos. | `velero/site/content/docs/main/file-system-backup.md` §Restore |
| H11 | Un `Schedule` nuevo toma como referencia su `creationTimestamp`. El primer backup ocurre en el siguiente tick del cron, no al crearse. | `velero/pkg/controller/schedule_controller.go` (`getNextRunTime`) |
| H12 | `BackupStorageLocation.status.lastSyncedTime` se escribe al terminar cada pasada de sincronización de backups, **aunque el bucket esté vacío**. | `velero/pkg/controller/backup_sync_controller.go` |
| H13 | Chart `velero` 12.2.0 (appVersion 1.18.2): <br>• trae los CRDs en `crds/` y además un Job hook `upgrade-crds` (`helm.sh/hook: pre-install,pre-upgrade`); <br>• `deployNodeAgent: false` y `schedules: {}` por defecto. | `velero-12.2.0.tgz` |
| H14 | Chart `sealed-secrets` 2.20.0: <br>• el CRD está en `crds/` (estático, no se puede anotar con valores); <br>• el único Secret que renderiza es el TLS del Ingress, que está desactivado; <br>• no renderiza ningún Secret de llave. | `sealed-secrets-2.20.0.tgz` |

---

## 0. Correcciones al planteamiento

Lo que sigue contradice o precisa el encargo y cambia el diseño.

1. **El Lua de health de `Application` que ya está en [modules/argocd/main.tf](../terraform/modules/argocd/main.tf) no basta.** Por H5, `data-restore` se declara `Healthy` en cuanto existe su RBAC, aunque su Job de restauración siga corriendo, así que la raíz avanza a `sa-platform`. De ahí sale una pérdida silenciosa de datos:
   1. `sa-platform` crea `sa-platform-mysql-data` vacío.
   2. Velero omite los PVC que ya existen.
   3. Las bases arrancan vacías, sin ningún error visible.

   La §3.1 lo reemplaza por un Lua que también mira `operationState` y `sync.status`.
2. **Un límite de reintentos finito contradice "sin pasos manuales" (rúbrica 2.1).**
   - Hoy la raíz tiene `limit: 10`, y `sealed-secrets`, `kyverno`, `argo-rollouts` y `kyverno-policies` no tienen `retry`.
   - Por H7, una sola falla transitoria deja a la hija en `Failed`. Por ejemplo, que el webhook de Kyverno todavía no responda.
   - A partir de ahí auto-sync no vuelve a intentarlo, y alguien tendría que pulsar `Sync`.

   Diseño: `retry.limit: -1` en la raíz y en todas las hijas. El límite de tiempo lo pone `bootstrap.sh`, que ya falla con diagnóstico.
3. **"Las políticas de Kyverno no pueden entrar antes de que exista `ghcr-secret`" es impreciso.** Kyverno acepta la `ClusterPolicy` aunque el Secret no exista. Lo que falla es la admisión de los Pods de `sa-p5`: `verifyImages` no puede autenticarse en GHCR y `Enforce` los rechaza. La restricción real es que `kyverno/ghcr-secret` exista antes que `sa-platform` (ola 0). El orden −10 → −5 se conserva, pero no es el que evita esa falla (ver §1.1, nota N2).
4. **Quitar el `resources-finalizer` no protege el CRD de `argocd app delete`**, porque ese comando hace cascada por defecto (H8). Se agrega `Delete=false` a nivel de Application en las cuatro Applications de operadores.
5. **Las bases de datos no tienen Application propia.**
   - `mysql` y `mongodb` son subcharts de `sa-platform`.
   - Separarlas reestructuraría el chart, cosa que prohíbe el encargo, y dejaría dos dueños para plantillas compartidas (`sealed-secrets.yaml`, `cronjobs.yaml`, `namespace-quotas.yaml`).
   - El orden con estado se resuelve en dos niveles:
     - la Application `data-restore` restaura antes de que exista `sa-platform`;
     - la ola 0 interna del chart pone las bases antes que los microservicios.
   - El manifiesto "stateful" de la §2.3 es `data-restore`, junto con las anotaciones del chart.
6. **Poner un PVC en una ola anterior a su StatefulSet produce un bloqueo sin salida.** `managed-csi` enlaza con `WaitForFirstConsumer`, así que el PVC queda `Pending` (`Progressing`, H6) hasta que un Pod lo usa. Si el Pod está en una ola posterior, la ola del PVC nunca cierra, y no hay timeout (H7). PVC y StatefulSet van en la misma ola.
7. **[PUNTO DE INTEGRACIÓN CON VELERO] FSB no sirve para "restaurar antes que los workloads".**
   - Por H10, restaurar solo los PVC con FSB deja volúmenes vacíos.
   - El diseño de Velero debe respaldar los PVC de las bases con **snapshot CSI + data mover** (`snapshotMoveData: true`). Así los datos terminan en Blob Storage, fuera del dominio de fallo.
   - Por defecto, un snapshot CSI nativo de Azure Disk vive en el resource group de nodos `MC_*`, que se borra junto con el clúster.
8. **Si el `Schedule` va en la ola del controlador, puede respaldar el namespace vacío.** Se mueve a la ola 5, y la restauración elige solo respaldos tomados antes de que naciera el clúster (§1.1 y §2.3).
9. **Inconsistencias en los archivos actuales:**
   - El comentario de [kyverno.yaml](../gitops/apps/kyverno.yaml) dice que las políticas van en −10, pero están en −5.
   - A `P9_EXPECTED_APPS` ([lib/p9-config.sh](../scripts/lib/p9-config.sh)) le faltan `platform-secrets`, `velero`, `data-restore`, `velero-schedules` y `platform-verify`.
   - [publish-gitops.sh](../scripts/publish-gitops.sh) no publica `platform/` ni `platform-secrets/`.
   - El comentario de `wait_all_applications` dice que "la raíz Healthy implica hijas Healthy". Es falso: por H5, las hijas que todavía no existen no cuentan. El código ya lo compensa, porque verifica cada hija por nombre.

---

## 1. Matriz de olas

### 1.0 Antes de ArgoCD (fuera del app-of-apps)

| Orden | Qué | Quién lo crea | Qué fallo evita |
|---|---|---|---|
| T1 | Backend del estado (`rg-p9-tfstate`) | `bootstrap.sh` con Azure CLI | Sin backend no hay `terraform init` (diseño del backend). |
| T2 | RG + AKS | Terraform `01-cluster` | — |
| T3 | Nodos `Ready`, al menos 2 | `bootstrap.sh` (`wait_nodes_ready`) | La prueba de pérdida de nodo necesita dos nodos. |
| T4 | Llave de Sealed Secrets en `kube-system` **[PUNTO DE INTEGRACIÓN CON SECRETOS]** | `restore-sealed-secrets-key.sh`, invocado por `bootstrap.sh` | El controlador lee sus llaves **solo al arrancar**. Si arrancara antes, escribiría `New key written` y ningún `SealedSecret` de Git se podría descifrar. |
| T5 | ns `sa-p5`, cuotas, LimitRange y RBAC **[PUNTO DE INTEGRACIÓN CON EL DÍA CERO]** | Terraform `02-platform`, `module.tenant` | Hay que evitar dos fallos: <br>• Sin el namespace: `namespaces "sa-p5" not found` en `platform-secrets`, `data-restore` y `sa-platform`. <br>• Si ArgoCD lo creara con `CreateNamespace`: el `kubernetes_namespace_v1` de Terraform fallaría con `already exists` en la siguiente corrida. |
| T6 | ArgoCD + `argocd-cm` con los Lua de la §3 **[PUNTO DE INTEGRACIÓN CON EL DÍA CERO]** | Terraform, `module.argocd` | Los Lua deben existir **antes** del primer sync de la raíz. Sin ellos, las olas del primer sync serían decorativas y no se pueden corregir a posteriori. Están en el mismo `helm_release`, así que el orden está garantizado. |
| T7 | AppProjects `p9-bootstrap` y `p9-platform` + raíz `p9-root` | Terraform, `module.seed` (`depends_on` tenant y argocd) | — |

### 1.1 Nivel raíz: `p9-root` → Applications hijas

La raíz crea las hijas de una ola solo cuando **todas** las de la ola anterior cumplen el Lua de la §3.1. Es decir: `Synced`, `Healthy` y sin operación en curso.

| Ola | Application | Qué instala | La ola cierra cuando | Qué falla si no espera a la ola anterior |
|---|---|---|---|---|
| **−30** | `sealed-secrets` [SECRETOS] | CRD `SealedSecret` + controlador en `kube-system` | El CRD está `Established` y el Deployment `Available` (health integrado) | No depende de ninguna ola: su prerrequisito es T4. Sobre por qué va antes que −20, ver N1. |
| **−20** | `kyverno` | CRDs + motor de admisión; crea el ns `kyverno` | CRDs `Established` y Deployments `Available` | Hoy no depende de −30 (N1). |
| **−20** | `argo-rollouts` | CRDs `Rollout` y `AnalysisTemplate` + controlador | CRDs `Established` y Deployment `Available` | ídem |
| **−20** | `velero` [VELERO] | CRDs, servidor, `node-agent`, BSL `default` y VolumeSnapshotClass | CRDs, Deployment y DaemonSet listos **y** BSL `Available` con `lastSyncedTime` (Lua §3.4) | ídem. Si la BSL usara una credencial sellada, sí dependería de −30 (N1). |
| **−10** | `platform-secrets` [SECRETOS] | `SealedSecret` `sa-p5/ghcr-secret`, `sa-p5/sa-platform-nats-auth` y `kyverno/ghcr-secret` | Los tres `SealedSecret` con `Synced=True` (integrado) | Sin CRD (−30): `no matches for kind "SealedSecret"`. <br>Sin ns `kyverno` (−20): `namespaces "kyverno" not found`. <br>Sin controlador con la llave: se queda en `Progressing` o `Degraded`. |
| **−10** | `data-restore` [VELERO] | RBAC + Job hook que crea un `Restore` solo de los PVC de MySQL y MongoDB y espera `Completed` (§2.3) | Termina su operación de sync, incluido el hook `Complete` (Lua §3.1) | Sin `velero` sano: `no matches for kind "Restore"`. Peor aún, con la BSL todavía sin sincronizar el Job no vería respaldos. Va en paralelo con `platform-secrets` porque no dependen entre sí, y así el paso más largo arranca lo antes posible. |
| **−5** | `kyverno-policies` | 3 `ClusterPolicy` en `Enforce` | `Ready=True` en cada política (Lua §3.3) | Si el motor no está listo, el webhook de Kyverno que valida políticas rechaza la creación (`failed calling webhook … connection refused`) o el CRD todavía no existe. Sobre por qué va después de −10, ver N2. |
| **0** | `sa-platform` [SECRETOS] [VELERO] | Chart heredado de P8 (olas internas en §1.2) | Ver §1.2 | Si entrara antes de −10 o −5 pasaría lo siguiente: <br>(a) sin `sa-p5/ghcr-secret`, los Pods quedan en `ImagePullBackOff`; <br>(b) sin `kyverno/ghcr-secret`, `verifyImages` rechaza todos los Pods de `sa-p5`; <br>(c) los Pods creados antes de que las políticas estén `Ready` se admiten **sin verificar la firma**, y como `verify-image-signatures` tiene `background: false`, nadie lo detecta después; <br>(d) crearía los PVC vacíos antes de la restauración, Velero omitiría los PVC existentes y las bases quedarían vacías sin error. |
| **5** | `velero-schedules` [VELERO] | `Schedule` `p9-sa-p5-db` (cron y TTL los fija el diseño de Velero) | `phase=Enabled` (Lua §3.5) | Si estuviera en −20, un tick del cron durante la ventana del bootstrap (H11) generaría un backup `Completed` de `sa-p5` sin bases o a medio restaurar. Ese backup pasaría a ser el más reciente, y `velero restore create --from-schedule` (la restauración de la rúbrica 2.6) restauraría vacío. |
| **10** | `platform-verify` | Job hook de humo dentro de `sa-p5` (§2.5) | El Job termina `Complete` | "Plataforma antes que verificaciones". Sin esta ola, que la raíz esté `Healthy` significa "Pods listos", no "la API responde". |

- **N1 (−30 frente a −20).** Hoy ninguna Application de −20 contiene un `SealedSecret`, así que la separación **no es obligatoria**. Se conserva por dos motivos:
  - el diseño de Velero puede necesitar una credencial sellada para la BSL, y entonces la dependencia pasa a ser real;
  - el costo es el tiempo que tarda el controlador en quedar `Available`, que se medirá en la corrida.

  Si Velero usa Workload Identity, fusionar `sealed-secrets` en −20 acorta el RTO en ese tiempo.
- **N2 (−10 frente a −5).** La única restricción dura es que ambas terminen antes de 0 (punto 3 de la §0).
  - Se conserva −5 porque ya es el orden publicado y cuesta segundos: ninguna política espera más que el restore, que corre en −10 de todas formas.
  - Además garantiza un invariante útil para diagnosticar: cuando existe una política que referencia `ghcr-secret`, el Secret ya existe.

**Namespaces explícitos:** no hace falta una Application de namespaces.

| Namespace | Lo crea | Antes de |
|---|---|---|
| `sa-p5` | Terraform (T5) | ArgoCD |
| `kyverno` | `kyverno` con `CreateNamespace=true` (−20) | `platform-secrets` (−10) |
| `velero` | `velero` con `CreateNamespace=true` (−20) | `data-restore` (−10) |
| `argo-rollouts` | `argo-rollouts` con `CreateNamespace=true` (−20) | — |

`CreateNamespace` no pone el namespace bajo seguimiento, así que borrar la Application no lo borra.

### 1.2 Dentro de `sa-platform` (anotaciones en el chart)

| Ola | Recursos | La ola cierra cuando | Qué falla si no se respeta |
|---|---|---|---|
| **−1** | Los 3 `SealedSecret` de `templates/sealed-secrets.yaml` (MySQL, MongoDB y auth) [SECRETOS] | `Synced=True` | Con una llave equivocada, el sync se detiene aquí con el mensaje del controlador (`no key could decrypt secret`) y **no se crea ningún workload**. Sin esta ola, los Pods quedan en `CreateContainerConfigError` y la Application se ve `Progressing` hasta que el Deployment agota `progressDeadlineSeconds` (600 s), con la causa real escondida en los eventos. |
| **0** (sin anotar = 0) | MySQL y MongoDB (StatefulSet, **PVC**, Service, ConfigMap de init), NATS (subchart externo, que no se puede anotar), ResourceQuota, LimitRange, NetworkPolicies, ConfigMaps, Services (incluido el `LoadBalancer`), PDBs y AnalysisTemplate | StatefulSets con `readyReplicas=1` (readiness TCP), PVC `Bound` y Service LB con IP | PVC y StatefulSet van **en la misma ola** (punto 6 de la §0). El Service `LoadBalancer` queda `Progressing` hasta que Azure asigna la IP (H6); corre en paralelo con el arranque de las bases. |
| **1** | Deployments `auth`, `catalog`, `orders` y `notifications`; Rollout de `api-gateway`; **sus 5 HPA**; CronJobs `cron1` y `cron2` | Deployments `Available`, Rollout `Healthy` y HPA `Healthy` | **Después de 0:** los servicios se conectan a MySQL, Mongo o NATS al arrancar. Si la base todavía no escucha, entran en `CrashLoopBackOff`, y el backoff del kubelet (hasta 5 min) se suma al RTO aunque la base ya esté lista. <br>**HPA en la misma ola que su objetivo:** un HPA en la ola 0 que apunta a un Deployment de la ola 1 queda en `AbleToScale/FailedGetScale` = `Degraded` (H6), y eso hace fallar el sync. <br>**CronJobs:** no necesitan ola propia, porque su health integrado es `Healthy` mientras no haya un éxito previo. Van en la 1 solo para que `cron1` (`*/2`) no genere Jobs fallidos mientras MySQL arranca, que ensuciarían la evidencia de la restauración. |

El Rollout usa su health integrado (H3).
- En el primer despliegue, Argo Rollouts pasa directo al 100 %, sin pasos canary.
- En una actualización posterior, mientras el canary está en pausa, el Rollout queda `Suspended`, y eso mantiene abierta la ola de `sa-platform` (H4). Es lo esperado: el sync no termina hasta que el canary se promueve o aborta.

### 1.3 Dentro de las demás hijas

| Application | Orden interno |
|---|---|
| `sealed-secrets`, `kyverno`, `argo-rollouts`, `velero` | Son charts de terceros y no se anotan. ArgoCD ordena por tipo (CRD antes que CR; Namespace, RBAC, Deployment…) y omite el dry-run de un CR cuyo CRD viene en el mismo sync. En `velero`: `upgradeCRDs: false`. El Job hook `upgrade-crds` (H13) se convertiría en un `PreSync` de ArgoCD con otra imagen externa en el camino crítico, y es redundante porque ArgoCD ya aplica `crds/`. |
| `data-restore` | Ola 0: SA, Roles, bindings y ConfigMaps. Hook `Sync` en la ola 1: Job `p9-data-restore`. |
| `platform-verify` | Ola 0: ConfigMap del script. Hook `Sync` en la ola 1: Job `p9-platform-verify`. |
| `platform-secrets`, `kyverno-policies`, `velero-schedules` | Una sola ola. |

**Por qué las dos Applications con hooks llevan también un recurso normal:** en una Application que solo tiene hooks, el estado es `Synced` desde el principio. Auto-sync nunca la sincroniza y el hook **nunca corre**. Los ConfigMaps y el RBAC evitan eso.

---

## 2. Manifiestos

Todos usan el repositorio GitOps público `https://github.com/ELFBIBv/Practicas-SA-B-202203856-gitops.git` (rama `main`). Las rutas son rutas en ese repo; su origen en el repo de código está en la §7.

### 2.1 Application raíz `p9-root` [PUNTO DE INTEGRACIÓN CON EL DÍA CERO]

La crea Terraform con el chart `argocd-apps` ([modules/app-of-apps-seed/main.tf](../terraform/modules/app-of-apps-seed/main.tf)) y **no** vive en Git. Este es el objeto que debe quedar en el clúster:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: p9-root
  namespace: argocd
  # Sin finalizers: si Terraform borra la raíz, las hijas quedan (sin cascada).
spec:
  project: p9-bootstrap          # AppProject que solo admite objetos Application en argocd
  source:
    repoURL: https://github.com/ELFBIBv/Practicas-SA-B-202203856-gitops.git
    targetRevision: main
    path: apps
    directory:
      recurse: false
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true                # quitar un archivo de apps/ quita la hija (sin cascada: no tiene finalizer)
      selfHeal: true             # revierte ediciones manuales de las hijas
    retry:
      limit: -1                  # H7: con un límite finito, al agotarse, la raíz deja de crear olas hasta un Sync manual
      backoff:
        duration: 15s
        factor: 2
        maxDuration: 3m
```

Cambio en Terraform: un solo valor de [modules/app-of-apps-seed/main.tf](../terraform/modules/app-of-apps-seed/main.tf).

```hcl
          retry = {
            limit = -1   # antes: 10
```

### 2.2 Hija de operador que depende de sus CRDs: `velero` [PUNTO DE INTEGRACIÓN CON VELERO]

Ruta: `apps/velero.yaml`. Es multi-source: el chart viene del repo de vmware-tanzu y los valores del repo GitOps. Así el contenido de Velero (BSL, identidad, plugin) le pertenece a su diseño, sin tocar este manifiesto.

```yaml
# Ola -20: CRDs + servidor + node-agent + BSL. data-restore (-10) crea objetos
# Restore y necesita la BSL sincronizada; velero-schedules (5) crea el Schedule.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: velero
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-20"
spec:
  project: p9-platform
  sources:
    - repoURL: https://vmware-tanzu.github.io/helm-charts
      chart: velero
      targetRevision: 12.2.0            # appVersion 1.18.2 (índice del repo, 2026-09-24)
      helm:
        releaseName: velero
        valueFiles:
          - $values/platform/velero/values.yaml
    - repoURL: https://github.com/ELFBIBv/Practicas-SA-B-202203856-gitops.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: velero
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    retry:
      limit: -1
      backoff:
        duration: 10s
        factor: 2
        maxDuration: 1m                 # corto: la BSL pasa por Unavailable de forma transitoria (§3.4)
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true            # los CRDs de Velero superan el límite de la anotación last-applied
      - Delete=false                    # H8: un `argocd app delete` no borra los CRDs, y con ellos Backups/Restores
```

**Contrato mínimo** que este diseño exige a `platform/velero/values.yaml`. El resto (bucket, cuenta, identidad, plugin de Azure) es del diseño de Velero:

```yaml
upgradeCRDs: false        # H13: sin Job PreSync con imagen externa; ArgoCD aplica crds/
cleanUpCRDs: false
deployNodeAgent: true     # el data mover integrado corre en node-agent
schedules: {}             # el Schedule vive en velero-schedules (ola 5), nunca aquí
configuration:
  backupStorageLocation:
    - name: default       # data-restore y el Lua §3.4 esperan este nombre
      # provider, bucket, config: diseño de Velero
# PVC de las bases: snapshot CSI + snapshotMoveData (§0, punto 7). La VolumeSnapshotClass
# con la etiqueta velero.io/csi-volumesnapshot-class: "true" va en extraObjects.
```

La ola cierra cuando se cumplen estas condiciones:
- los CRDs están `Established`;
- `deploy/velero` está `Available`;
- `ds/node-agent` está listo;
- la BSL `default` está `Available` **y** tiene `lastSyncedTime` (§3.4).

Esa última condición garantiza que, cuando corre `data-restore`, la lista de Backups del bucket ya está completa en el clúster (H12).

### 2.3 Hija con estado: `data-restore` [PUNTO DE INTEGRACIÓN CON VELERO]

Ruta de la Application: `apps/data-restore.yaml`.

```yaml
# Ola -10: restaura los PVC de MySQL y MongoDB ANTES de que exista sa-platform (ola 0).
# Si sa-platform llegara primero, crearía PVC vacíos y Velero los omitiría por existir.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: data-restore
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-10"
spec:
  project: p9-platform
  source:
    repoURL: https://github.com/ELFBIBv/Practicas-SA-B-202203856-gitops.git
    targetRevision: main
    path: platform/data-restore
  destination:
    server: https://kubernetes.default.svc
    namespace: velero
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    retry:
      limit: -1
      backoff:
        duration: 30s
        factor: 2
        maxDuration: 5m
```

**Contenido de `platform/data-restore/`**, en un solo archivo `data-restore.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: p9-data-restore
  namespace: velero
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: p9-data-restore
  namespace: velero
rules:
  - apiGroups: ["velero.io"]
    resources: ["backups", "backupstoragelocations"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["velero.io"]
    resources: ["restores"]
    verbs: ["get", "list", "watch", "create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: p9-data-restore
  namespace: velero
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: p9-data-restore}
subjects: [{kind: ServiceAccount, name: p9-data-restore, namespace: velero}]
---
# Solo lectura de PVC en sa-p5: decidir si hay algo que restaurar.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: p9-data-restore-pvc
  namespace: sa-p5
rules:
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: p9-data-restore-pvc
  namespace: sa-p5
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: p9-data-restore-pvc}
subjects: [{kind: ServiceAccount, name: p9-data-restore, namespace: velero}]
---
# Solo kube-system: su creationTimestamp es el "nacimiento" de este clúster.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: p9-data-restore-cluster-birth
rules:
  - apiGroups: [""]
    resources: ["namespaces"]
    resourceNames: ["kube-system"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: p9-data-restore-cluster-birth
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: p9-data-restore-cluster-birth}
subjects: [{kind: ServiceAccount, name: p9-data-restore, namespace: velero}]
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: p9-data-restore-config
  namespace: velero
data:
  APP_NAMESPACE: sa-p5
  VELERO_NAMESPACE: velero
  BSL_NAME: default
  # Debe coincidir con metadata.name del Schedule de velero-schedules.
  SCHEDULE_NAME: p9-sa-p5-db
  # Nombres que produce el chart con releaseName sa-platform (§2.4).
  PVCS: "sa-platform-mysql-data sa-platform-mongodb-data"
  # required: si no hay respaldo, falla (no se levantan bases vacías).
  # skip-if-empty: SOLO para la génesis (primer despliegue, sin respaldos). §5, paso P0.
  RESTORE_MODE: required
  BSL_TIMEOUT_S: "900"
  RESTORE_TIMEOUT_S: "2700"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: p9-data-restore-script
  namespace: velero
data:
  data-restore.sh: |
    #!/usr/bin/env bash
    # Restaura los PVC de las bases desde el último respaldo Completed tomado ANTES
    # de que existiera este clúster. Idempotente. El log solo contiene nombres,
    # fases y marcas de tiempo UTC: es evidencia de RTO/RPO.
    set -Eeuo pipefail
    log() { printf '%s [data-restore] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
    die() { log "ERROR: $*"; exit 1; }
    trap 'die "falló la línea $LINENO: $BASH_COMMAND"' ERR
    V=$VELERO_NAMESPACE
    SEL=p9.dr/managed-by=data-restore
    TERMINAL_KO='^(Failed|PartiallyFailed|FailedValidation|WaitingForPluginOperationsPartiallyFailed|FinalizingPartiallyFailed)$'

    latest_restore() {  # "<nombre> <fase>" de la última restauración de este Job, o vacío
      kubectl -n "$V" get restores -l "$SEL" --sort-by=.metadata.creationTimestamp \
        -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase}{"\n"}{end}' | tail -n1
    }

    wait_restore() {  # 0 solo si termina Completed
      local name=$1 phase last="" deadline=$((SECONDS + RESTORE_TIMEOUT_S))
      while :; do
        phase=$(kubectl -n "$V" get restore "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)
        if [[ "$phase" != "$last" ]]; then log "restore $name: ${phase:-sin fase}"; last=$phase; fi
        [[ "$phase" == Completed ]] && return 0
        if [[ "$phase" =~ $TERMINAL_KO ]]; then
          kubectl -n "$V" get restore "$name" \
            -o jsonpath='{"razon="}{.status.failureReason}{" errores="}{.status.errors}{" advertencias="}{.status.warnings}{"\n"}' || true
          return 1
        fi
        (( SECONDS < deadline )) || { log "timeout de ${RESTORE_TIMEOUT_S}s esperando $name"; return 1; }
        sleep 10
      done
    }

    report() {  # línea única para la evidencia
      local r=$1
      kubectl -n "$V" get restore "$r" -o jsonpath='{"RESTORE_OK restore="}{.metadata.name}{" backup="}{.spec.backupName}{" restore_inicio="}{.status.startTimestamp}{" restore_fin="}{.status.completionTimestamp}{" items="}{.status.progress.itemsRestored}{" advertencias="}{.status.warnings}{"\n"}'
      kubectl -n "$APP_NAMESPACE" get pvc -l velero.io/restore-name="$r" \
        -o jsonpath='{range .items[*]}{"PVC "}{.metadata.name}{" fase="}{.status.phase}{"\n"}{end}'
    }

    # 0) Una restauración previa de este Job sin terminar: se retoma, no se duplica.
    #    Fase vacía = recién creada, Velero aún no la tomó: también se retoma.
    read -r last_name last_phase <<<"$(latest_restore)"
    if [[ -n "${last_name:-}" && ( -z "${last_phase:-}" || "$last_phase" =~ ^(New|InProgress|WaitingForPluginOperations|Finalizing)$ ) ]]; then
      log "retomando $last_name (${last_phase:-sin fase})"
      wait_restore "$last_name" || die "la restauración $last_name no terminó en Completed"
      report "$last_name"; exit 0
    fi

    # 1) Idempotencia: ¿falta algún PVC?
    missing=()
    for pvc in $PVCS; do
      kubectl -n "$APP_NAMESPACE" get pvc "$pvc" -o name >/dev/null 2>&1 || missing+=("$pvc")
    done
    if (( ${#missing[@]} == 0 )); then
      if [[ -n "${last_name:-}" && "${last_phase:-}" != Completed ]]; then
        die "PVC presentes pero la última restauración ($last_name) terminó en $last_phase: posible volumen parcial. Contingencia R3 (docs/diseño-sync-waves.md §6.4)."
      fi
      log "IDEMPOTENTE: PVC presentes ($PVCS). No se restaura (clúster vivo o segunda corrida)."
      exit 0
    fi
    [[ -z "${last_name:-}" ]] || die "faltan PVC (${missing[*]}) y ya hubo una restauración en este clúster ($last_name $last_phase). No se repite sola: contingencia R3 (docs/diseño-sync-waves.md §6.4)."
    log "PVC ausentes: ${missing[*]}"

    # 2) BSL disponible y con la lista de backups ya sincronizada desde el bucket (H12).
    deadline=$((SECONDS + BSL_TIMEOUT_S)); last=""
    while :; do
      state=$(kubectl -n "$V" get backupstoragelocation "$BSL_NAME" \
        -o jsonpath='{.status.phase}/{.status.lastSyncedTime}' 2>/dev/null || true)
      if [[ "$state" != "$last" ]]; then log "BSL $BSL_NAME: ${state:-sin estado}"; last=$state; fi
      [[ "$state" == Available/?* ]] && break
      (( SECONDS < deadline )) || die "la BSL $BSL_NAME no quedó Available y sincronizada en ${BSL_TIMEOUT_S}s"
      sleep 10
    done

    # 3) Último backup Completed de la schedule tomado ANTES del nacimiento del clúster.
    #    Así ningún backup del propio bootstrap (namespace aún vacío) puede ser el elegido.
    born=$(kubectl get namespace kube-system -o jsonpath='{.metadata.creationTimestamp}')
    backup=$(kubectl -n "$V" get backups -l velero.io/schedule-name="$SCHEDULE_NAME" -o json \
      | jq -r --arg born "$born" '[.items[]
          | select(.status.phase == "Completed" and .status.startTimestamp != null and .status.startTimestamp < $born)]
          | sort_by(.status.startTimestamp) | last | .metadata.name // empty')
    if [[ -z "$backup" ]]; then
      case "$RESTORE_MODE" in
        skip-if-empty) log "GENESIS: no hay respaldos de $SCHEDULE_NAME anteriores a $born; se continúa con volúmenes nuevos (RESTORE_MODE=skip-if-empty)."; exit 0 ;;
        required) die "no hay respaldo Completed de $SCHEDULE_NAME anterior a $born. RESTORE_MODE=required: no se levantan bases vacías." ;;
        *) die "RESTORE_MODE inválido: $RESTORE_MODE" ;;
      esac
    fi
    kubectl -n "$V" get backup "$backup" \
      -o jsonpath='{"RESPALDO_ELEGIDO="}{.metadata.name}{" inicio="}{.status.startTimestamp}{" fin="}{.status.completionTimestamp}{" expira="}{.status.expiration}{" nacimiento_cluster="}'
    echo "$born"

    # 4) Restore limitado a PVC/PV de las bases: nunca restaura Secrets, SealedSecrets
    #    ni workloads (esos vienen de Git; restaurarlos crea dos dueños).
    name="p9-dr-$(date -u +%Y%m%d%H%M%S)"
    kubectl create -f - <<EOF
    apiVersion: velero.io/v1
    kind: Restore
    metadata:
      name: $name
      namespace: $V
      labels:
        p9.dr/managed-by: data-restore
    spec:
      backupName: $backup
      includedNamespaces: ["$APP_NAMESPACE"]
      includedResources: ["persistentvolumeclaims", "persistentvolumes"]
      orLabelSelectors:
        - matchLabels: {app: mysql}
        - matchLabels: {app: mongodb}
      restorePVs: true
      existingResourcePolicy: none
    EOF
    wait_restore "$name" || die "la restauración $name no terminó en Completed"

    # 5) Cada PVC que faltaba existe ahora y lo creó ESTE restore.
    for pvc in "${missing[@]}"; do
      got=$(kubectl -n "$APP_NAMESPACE" get pvc "$pvc" -o jsonpath='{.metadata.labels.velero\.io/restore-name}' 2>/dev/null || true)
      [[ "$got" == "$name" ]] || die "el PVC $pvc no proviene de $name (etiqueta: '${got:-ausente}')"
    done
    report "$name"
---
apiVersion: batch/v1
kind: Job
metadata:
  name: p9-data-restore
  namespace: velero
  annotations:
    argocd.argoproj.io/hook: Sync
    argocd.argoproj.io/sync-wave: "1"                      # después del RBAC y los ConfigMaps (ola 0)
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation   # conserva el Job y su log como evidencia
spec:
  backoffLimit: 0                # los reintentos los hace ArgoCD (Job nuevo, log limpio)
  activeDeadlineSeconds: 3600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: p9-data-restore
    spec:
      serviceAccountName: p9-data-restore
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        runAsGroup: 65534
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: restore
          # bash + kubectl + jq. Namespace velero: fuera del alcance de Kyverno (políticas acotadas a sa-p5).
          image: docker.io/alpine/k8s:1.36.4@sha256:6473c1ce0ef6b2b95b6efaa2769734f2eff00d0387945b1bfb2af9ac07af0ad4
          command: ["bash", "/scripts/data-restore.sh"]
          envFrom:
            - configMapRef: {name: p9-data-restore-config}
          env:
            - {name: HOME, value: /tmp}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: ["ALL"]}
          resources:
            requests: {cpu: 20m, memory: 64Mi}
            limits: {cpu: 200m, memory: 256Mi}
          volumeMounts:
            - {name: script, mountPath: /scripts, readOnly: true}
            - {name: tmp, mountPath: /tmp}
      volumes:
        - name: script
          configMap: {name: p9-data-restore-script}
        - name: tmp
          emptyDir: {}
```

**Decisiones del Job, cada una con el fallo que evita:**

| Decisión | Fallo que evita |
|---|---|
| Esperar `phase=Available` **y** `lastSyncedTime` | Si el Job consulta los Backups antes de la primera sincronización del bucket, no ve ninguno. Con `required` fallaría en falso; con una lógica "si no hay nada, seguir" levantaría las bases vacías sin avisar. |
| Elegir solo backups con `startTimestamp < creationTimestamp(kube-system)` | Que un backup tomado durante el bootstrap (namespace sin bases) sea el más reciente y se restaure vacío. Es la segunda defensa, además de poner el `Schedule` en la ola 5. |
| `RESTORE_MODE=required` por defecto | Una BSL mal configurada (prefijo equivocado) parece "sin respaldos" y levantaría bases vacías. `skip-if-empty` es explícito y solo se usa en la génesis. |
| Omitir la restauración si los PVC ya existen, salvo que la última restauración no haya terminado `Completed` | Pisar datos vivos en una segunda corrida, o arrancar sobre un volumen parcial tras un restore fallido. |
| Retomar un `Restore` en curso | Crear dos restauraciones concurrentes si ArgoCD recrea el Job (por `activeDeadlineSeconds` o por un drenaje del nodo). |
| `includedResources` PVC/PV con `orLabelSelectors` `app=mysql` y `app=mongodb` | Restaurar Secrets o workloads que Git ya declara. Un Secret restaurado choca con su `SealedSecret` (`ErrUpdateFailed`, diseño de secretos §3.6). |
| Verificar la etiqueta `velero.io/restore-name` | Dar por restaurado un PVC que en realidad creó otro actor. |
| Imagen fijada por digest | Que un tag movido cambie el código que corre durante la recuperación. |

**Riesgo aceptado:** `alpine/k8s` es una imagen comunitaria. La alternativa limpia es una imagen propia `ghcr.io/elfbibv/p9-dr-tools` construida y firmada en el CI. Ver la decisión D2 en la §7.

**Anotaciones en el chart de las bases** (sin reestructurar nada). En `charts/mysql/templates/pvc.yaml` y `charts/mongodb/templates/pvc.yaml`:

```yaml
metadata:
  name: "{{ .Release.Name }}-mysql-data"        # (mongodb: "{{ include "mongodb.fullname" . }}-data")
  annotations:
    # Sin sync-wave: ola 0, la misma que su StatefulSet (WaitForFirstConsumer, §0 punto 6).
    # Prune=false: un cambio de nombre o persistence.enabled=false no borra el volumen.
    # Delete=false: borrar la Application no borra el volumen (managed-csi tiene reclaimPolicy Delete).
    argocd.argoproj.io/sync-options: Prune=false,Delete=false
```

Los StatefulSets no se anotan, porque la ola 0 es la de por defecto. En el flujo de recuperación de desastres (DR), cuando `sa-platform` sincroniza, el PVC ya existe (lo creó Velero). ArgoCD le agrega su anotación de seguimiento y desde ese momento lo administra.

### 2.4 Hija que consume secretos descifrados: `sa-platform` [PUNTO DE INTEGRACIÓN CON SECRETOS]

Ruta: `apps/sa-platform.yaml` (reemplaza a la actual).

```yaml
# Ola 0. Llega cuando ya existen:
#   - sa-p5/ghcr-secret, sa-p5/sa-platform-nats-auth, kyverno/ghcr-secret (platform-secrets, -10)
#   - los PVC de MySQL/MongoDB restaurados (data-restore, -10)
#   - las 3 ClusterPolicy en Enforce y Ready (kyverno-policies, -5)
#   - los CRD Rollout/AnalysisTemplate (argo-rollouts, -20)
# Olas internas: -1 SealedSecrets, 0 bases/NATS, 1 microservicios + HPA + CronJobs.
# El namespace sa-p5 lo crea Terraform: aquí NO va CreateNamespace.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: sa-platform
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: p9-platform
  source:
    repoURL: https://github.com/ELFBIBv/Practicas-SA-B-202203856-gitops.git
    targetRevision: main
    path: charts/sa-platform
    helm:
      # Explícito: de él salen los nombres de los PVC que busca data-restore
      # y los Pods que Kyverno excluye por nombre (sa-platform-mysql-0, ...).
      releaseName: sa-platform
      valueFiles:
        - values-azure.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: sa-p5
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    retry:
      limit: -1
      backoff:
        duration: 15s
        factor: 2
        maxDuration: 3m
```

**Anotaciones que se agregan al chart** (solo `metadata.annotations`, sin cambiar la estructura):

| Archivo | Recurso | Anotación |
|---|---|---|
| `templates/sealed-secrets.yaml` | los 3 `SealedSecret` | `argocd.argoproj.io/sync-wave: "-1"` [SECRETOS]. Con scope strict el ciphertext depende solo del nombre y el namespace, así que la anotación no lo invalida (diseño de secretos §3.4). |
| `charts/mysql/templates/pvc.yaml`, `charts/mongodb/templates/pvc.yaml` | PVC | `argocd.argoproj.io/sync-options: Prune=false,Delete=false` (§2.3) |
| `charts/{auth,catalog,orders,notifications}/templates/deployment.yaml` | Deployment | `argocd.argoproj.io/sync-wave: "1"` |
| `charts/{auth,catalog,orders,notifications,api-gateway}/templates/hpa.yaml` | HPA | `argocd.argoproj.io/sync-wave: "1"` (misma ola que su objetivo, H6) |
| `charts/api-gateway/templates/rollout.yaml` | Rollout | `argocd.argoproj.io/sync-wave: "1"` |
| `templates/cronjobs.yaml` | los 2 `CronJob` | `argocd.argoproj.io/sync-wave: "1"` |

El Secret que resulta de cada `SealedSecret` lo crea el controlador, con `ownerReference` al `SealedSecret`. ArgoCD no lo sigue y no lo poda.

### 2.5 Resto de las hijas (cambios respecto a lo publicado)

| Application | Ola | Cambio |
|---|---|---|
| `sealed-secrets` | −30 | Agregar `retry: {limit: -1, backoff: {duration: 10s, factor: 2, maxDuration: 1m}}` y `Delete=false` en `syncOptions`. El CRD está en `crds/` y no se puede anotar (H14), así que `Delete=false` va a nivel de Application. Sin él, `argocd app delete sealed-secrets` borraría el CRD, luego todos los `SealedSecret` y, por `ownerReference`, sus Secrets. |
| `kyverno` | −20 | `retry` ilimitado y `Delete=false`: borrar el CRD `ClusterPolicy` elimina las políticas y deja la admisión sin control. Corregir el comentario "−10" → "−5". |
| `argo-rollouts` | −20 | `retry` ilimitado y `Delete=false`: borrar el CRD `Rollout` borra en cascada el Rollout del gateway, sus ReplicaSets y sus Pods, y eso es una caída total. |
| `platform-secrets` | −10 | Tal como está en el diseño de secretos §3.4, más `retry` ilimitado, `project: p9-platform` (en vez de `default`) y `destination.namespace: sa-p5`. Cada manifiesto declara su propio namespace; el de `kyverno` está permitido en `p9-platform`. |
| `kyverno-policies` | −5 | `retry` ilimitado. |
| `velero-schedules` | 5 | Nueva. Fuente `platform/velero-schedules` y destino `velero`. Contiene solo el `Schedule` `p9-sa-p5-db`, que define el diseño de Velero. Restricciones de este diseño: <br>• el nombre debe coincidir con `SCHEDULE_NAME`; <br>• debe excluir `secrets` y `sealedsecrets.bitnami.com` (diseño de secretos §3.6); <br>• `ttl` explícito y mayor que el tiempo máximo entre el desastre y la reconstrucción, porque el GC del clúster nuevo borra los respaldos vencidos que sincroniza. |
| `platform-verify` | 10 | Nueva (abajo). |

`platform-verify`: la Application (ruta `apps/platform-verify.yaml`) es igual a `data-restore`, salvo en estos campos:
- `name: platform-verify`
- `sync-wave: "10"`
- `path: platform/verify`
- `destination.namespace: sa-p5`

Contenido de `platform/verify/verify.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: p9-platform-verify
  namespace: sa-p5
data:
  smoke.sh: |
    #!/bin/sh
    # Humo desde DENTRO del clúster, por la misma ruta que un cliente.
    set -eu
    BASE="http://sa-platform-api-gateway.sa-p5.svc.cluster.local"
    for path in /ready /api/auth/health /api/catalog/health /api/orders/health; do
      n=0
      until wget -q -T 5 -O /dev/null "$BASE$path"; do
        n=$((n + 1))
        if [ "$n" -ge 24 ]; then echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) FALLA $path"; exit 1; fi
        sleep 5
      done
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) OK $path"
    done
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) VERIFY_OK"
---
apiVersion: batch/v1
kind: Job
metadata:
  name: p9-platform-verify
  namespace: sa-p5
  annotations:
    argocd.argoproj.io/hook: Sync
    argocd.argoproj.io/sync-wave: "1"
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 600
  template:
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      imagePullSecrets: [{name: ghcr-secret}]
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: smoke
          # Imagen del propio CI (nginx alpine: sh + wget de busybox). Pasa por las
          # 3 políticas de Kyverno: sirve también como prueba de que ghcr-secret y la
          # verificación de firma funcionan después de la reconstrucción.
          image: ghcr.io/elfbibv/sa-api-gateway:v8.0.0
          command: ["sh", "/scripts/smoke.sh"]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: ["ALL"]}
          resources:
            requests: {cpu: 10m, memory: 16Mi}
            limits: {cpu: 50m, memory: 32Mi}
          volumeMounts:
            - {name: scripts, mountPath: /scripts, readOnly: true}
      volumes:
        - name: scripts
          configMap: {name: p9-platform-verify}
```

La NetworkPolicy del gateway admite ingreso al puerto 80 desde cualquier origen, y ninguna política de egreso selecciona este Pod, así que puede llegar al gateway.

---

## 3. Health checks personalizados [PUNTO DE INTEGRACIÓN CON EL DÍA CERO]

Todos van en `configs.cm` del `helm_release.argocd` ([modules/argocd/main.tf](../terraform/modules/argocd/main.tf)), con la clave `resource.customizations.health.<grupo>_<Kind>`. Un Lua en `argocd-cm` tiene prioridad sobre el health integrado.

| Recurso | ¿Health integrado en v3.5.3? | ¿Hace falta Lua? | Motivo |
|---|---|---|---|
| `argoproj.io/Application` | No (H2) | **Sí, más estricto** (§3.1) | Sin Lua, las olas de la raíz son decorativas. Con el Lua actual, un hook en curso o un recurso `Missing` no cuentan (H5). |
| `bitnami.com/SealedSecret` | Sí | No | `Synced=True` → `Healthy`; `False` → `Degraded` con el mensaje del controlador; sin estado → `Progressing`. Requiere `updateStatus: true`, que ya está en la app. |
| `kyverno.io/ClusterPolicy` | **No** (llega en v3.6, H1) | **Sí** (§3.3) | Sin Lua, la política está `Healthy` en cuanto se crea, antes de que Kyverno la cargue y configure el webhook. Los Pods de la ola 0 se admitirían sin validar. |
| `argoproj.io/Rollout` | Sí | No | Cubre `Paused`→`Suspended`, `Degraded` por `RolloutAborted` o `ProgressDeadlineExceeded`, y réplicas no disponibles. |
| `velero.io/BackupStorageLocation` | **No**, en ninguna versión | **Sí** (§3.4) | Sin Lua, `velero` está `Healthy` con la BSL `Unavailable`, y `data-restore` arrancaría sin ver respaldos. |
| `velero.io/Schedule` | **No** (llega en v3.6) | **Sí** (§3.5) | Un cron inválido deja el `Schedule` en `FailedValidation` en silencio: nunca más hay respaldos y el RPO real se vuelve infinito sin que nada lo muestre. |
| `velero.io/Restore`, `velero.io/Backup` | No (llegan en v3.6) | **No en este diseño** | ArgoCD no los administra. Los `Backup` salen del `Schedule` o de la sincronización del bucket, y el `Restore` lo crea el Job, que tiene health integrado. Un Lua sin objeto administrado no afecta a ninguna ola. Solo harían falta si se eligiera un `Restore` declarado en Git, alternativa descartada en §2.3 porque no puede elegir el backup ni omitir la restauración. |
| `autoscaling/HorizontalPodAutoscaler` | Sí, pero demasiado estricto en el bootstrap | **Recomendado** (§3.6) | Un HPA recién creado reporta `ScalingActive/FailedGetResourceMetric` hasta que metrics-server mide los Pods nuevos. El integrado lo marca `Degraded` (H6), la ola 1 falla y paga un ciclo de backoff. |
| `PersistentVolumeClaim`, `Job`, `CronJob`, `CustomResourceDefinition`, `Service` | Sí | No | Bastan, siempre que se respete la regla del PVC (§0, punto 6). |

### 3.1 `argoproj.io_Application` (reemplaza al actual)

```lua
-- Health de una Application hija, visto por la raiz. No basta con copiar
-- status.health: los hooks y los recursos Missing no cuentan ahi (H5), asi que
-- una hija con su Job de restauracion en curso ya se ve Healthy.
local hs = { status = "Progressing", message = "Esperando la primera reconciliacion" }
if obj.status == nil then
  return hs
end
local op = obj.status.operationState
if op ~= nil then
  -- Mientras reintenta con backoff, la fase sigue en Running.
  if op.phase == "Running" or op.phase == "Terminating" then
    hs.message = "Sync en curso: " .. (op.message or "")
    return hs
  end
  if op.phase == "Failed" or op.phase == "Error" then
    hs.status = "Degraded"
    hs.message = "Ultimo sync fallido: " .. (op.message or "")
    return hs
  end
end
local sync = "Unknown"
if obj.status.sync ~= nil and obj.status.sync.status ~= nil then
  sync = obj.status.sync.status
end
if sync ~= "Synced" then
  -- Recien creada (antes de su primer auto-sync) o con cambios sin aplicar.
  hs.message = "Hija en " .. sync .. " sin operacion en curso"
  return hs
end
if obj.status.health ~= nil and obj.status.health.status ~= nil then
  hs.status = obj.status.health.status
  hs.message = obj.status.health.message or ""
end
return hs
```

- **Por qué exige `Synced`:** cuando la raíz crea `sa-platform`, los PVC restaurados ya existen y están `Bound`, y el resto de sus recursos cuenta como `Missing`, que no computa (H5). Así, `sa-platform` se vería `Healthy` antes de su primer sync.
- **Costo:** una hija con diferencias benignas permanentes (`OutOfSync` para siempre) bloquea la raíz. Es coherente con `bootstrap.sh`, que ya exige `Synced/Healthy` por hija. Esas diferencias se corrigen con `ignoreDifferences` y se detectan antes de la prueba de DR con la validación V-S4.

### 3.2 `bitnami.com_SealedSecret` y `argoproj.io_Rollout`

Se usa el integrado. No se declara nada.

### 3.3 `kyverno.io_ClusterPolicy`

```lua
-- Backport del health de ArgoCD v3.6 (no existe en v3.5.3).
local hs = { status = "Progressing", message = "Esperando que Kyverno cargue la politica" }
if obj.status ~= nil and obj.status.conditions ~= nil then
  for _, c in ipairs(obj.status.conditions) do
    if c.type == "Ready" then
      if c.status == "True" then
        hs.status = "Healthy"
      else
        hs.status = "Degraded"
      end
      hs.message = c.message or ""
      return hs
    end
  end
end
return hs
```

### 3.4 `velero.io_BackupStorageLocation`

```lua
-- Healthy solo si la BSL es accesible Y ya importo la lista de backups del bucket.
-- lastSyncedTime se escribe aunque el bucket este vacio (H12): la genesis no se cuelga.
local hs = { status = "Progressing", message = "Esperando la primera validacion de la BSL" }
if obj.status ~= nil and obj.status.phase ~= nil then
  if obj.status.phase == "Available" then
    if obj.status.lastSyncedTime == nil then
      hs.message = "Disponible; esperando la primera sincronizacion de backups"
      return hs
    end
    hs.status = "Healthy"
    hs.message = "Disponible; ultima sincronizacion " .. obj.status.lastSyncedTime
  elseif obj.status.phase == "Unavailable" then
    hs.status = "Degraded"
    hs.message = obj.status.message or "BackupStorageLocation no disponible"
  end
end
return hs
```

- **Por qué `Unavailable` es `Degraded` y no `Progressing`:** un bucket o una identidad mal configurados deben verse como falla en el diagnóstico.
- **Consecuencia:** la propagación inicial de la identidad puede pasar por `Unavailable` unos minutos. Por eso `velero` tiene un backoff corto (`maxDuration: 1m`, §2.2): el reintento no suma más de un minuto al RTO.

### 3.5 `velero.io_Schedule`

```lua
-- Backport del health de ArgoCD v3.6 (no existe en v3.5.3).
local hs = { status = "Progressing", message = "Esperando que Velero valide el Schedule" }
if obj.status ~= nil and obj.status.phase ~= nil then
  if obj.status.phase == "Enabled" then
    hs.status = "Healthy"
    hs.message = "Schedule habilitado"
  elseif obj.status.phase == "FailedValidation" then
    hs.status = "Degraded"
    hs.message = "Schedule con validacion fallida"
  else
    hs.message = obj.status.phase
  end
end
return hs
```

### 3.6 `autoscaling_HorizontalPodAutoscaler` (recomendado)

```lua
-- Como el integrado, salvo que la falta TRANSITORIA de metricas (Pods recien
-- creados) es Progressing y no Degraded. Los errores de configuracion siguen Degraded.
local hs = { status = "Progressing", message = "Esperando metricas del HPA" }
if obj.status == nil or obj.status.conditions == nil then
  return hs
end
for _, c in ipairs(obj.status.conditions) do
  if (c.type == "AbleToScale" and (c.reason == "FailedGetScale" or c.reason == "FailedUpdateScale"))
     or (c.type == "ScalingActive" and c.reason == "InvalidSelector") then
    hs.status = "Degraded"
    hs.message = c.message or c.reason
    return hs
  end
end
for _, c in ipairs(obj.status.conditions) do
  if c.type == "ScalingActive" and c.status == "True" then
    hs.status = "Healthy"
    hs.message = c.message or ""
    return hs
  end
end
return hs
```

Si metrics-server no existiera, los HPA quedarían en `Progressing` y el bootstrap fallaría por timeout con este mensaje en el diagnóstico. **Criterio de decisión:** si en la primera corrida real el log de ArgoCD de `sa-platform` no muestra `FailedGetResourceMetric`, este Lua puede quedar fuera.

### 3.7 Cómo se integra en Terraform

```hcl
  values = [yamlencode({
    # ... (sin cambios)
    configs = {
      cm = {
        "resource.customizations.health.argoproj.io_Application"         = file("${path.module}/health/application.lua")
        "resource.customizations.health.kyverno.io_ClusterPolicy"         = file("${path.module}/health/clusterpolicy.lua")
        "resource.customizations.health.velero.io_BackupStorageLocation"  = file("${path.module}/health/bsl.lua")
        "resource.customizations.health.velero.io_Schedule"               = file("${path.module}/health/schedule.lua")
        "resource.customizations.health.autoscaling_HorizontalPodAutoscaler" = file("${path.module}/health/hpa.lua")
      }
      params = {
        # H9: guarda el health de cada recurso en la Application. El diagnóstico de la §6.3
        # puede hacerse con kubectl, sin iniciar sesión en argocd-server.
        "controller.resource.health.persist" = "true"
      }
    }
  })]
```

Los Lua van como archivos en `P9/terraform/modules/argocd/health/*.lua`. Así se pueden probar sin conexión (V-S2) y no quedan dentro de un heredoc.

---

## 4. Quién administra cada recurso (prevención de ciclos)

| Recurso | Dueño | Mecanismo | Nunca lo toca |
|---|---|---|---|
| Storage account y contenedor del tfstate | `bootstrap.sh` (Azure CLI) | fuera de cualquier estado | Terraform y ArgoCD |
| Key Vault de custodia | Terraform, capa persistente (diseño de secretos) | — | stacks del clúster y ArgoCD |
| RG + AKS | Terraform `01-cluster` | — | ArgoCD |
| Llave de Sealed Secrets en `kube-system` | `restore-sealed-secrets-key.sh` (field manager `p9-dr-bootstrap`) | sin anotación de seguimiento de ArgoCD; el chart no renderiza ningún Secret de llave (H14) | ArgoCD (no la ve, no la poda) y Velero (el `Schedule` no incluye `kube-system`) |
| ns `sa-p5`, cuotas, LimitRange y RBAC del tenant | Terraform `module.tenant` | — | ArgoCD: `sa-platform` no tiene `CreateNamespace` y el chart no renderiza el `Namespace` (V-S5) |
| ArgoCD, `argocd-cm` (Lua) y `argocd-cmd-params-cm` | Terraform `module.argocd` | `helm_release` | ninguna Application: `p9-platform` no tiene `argocd` como destino |
| AppProjects `p9-bootstrap` y `p9-platform`, raíz `p9-root` | Terraform `module.seed` | `helm_release` `argocd-apps` | la raíz: `p9-bootstrap` solo admite `Application` (§4.1) |
| Las 10 Applications hijas | `p9-root` | `apps/*.yaml` | las hijas: `p9-platform` no puede escribir en `argocd` |
| CRDs y controladores | su Application de operador | `Delete=false` | — |
| ns `kyverno`, `velero` y `argo-rollouts` | la Application con `CreateNamespace=true` | sin seguimiento, no se borran | — |
| `SealedSecret` | `sa-platform` y `platform-secrets` | — | Velero (excluidos del `Schedule`) |
| Secrets descifrados | controlador de Sealed Secrets | `ownerReference` | ArgoCD y Velero |
| PVC de las bases en DR | **creado** por Velero mediante el `Restore` de `data-restore`; **adoptado** por `sa-platform` en su primer sync | `Prune=false,Delete=false` | `data-restore` no los vuelve a tocar (idempotencia) |
| PVC de las bases en la génesis | `sa-platform` | ídem | — |
| PVC de JetStream (NATS) | controlador del StatefulSet (`volumeClaimTemplates`) | ArgoCD no lo sigue | — |
| Objetos `Restore` | Job `p9-data-restore` | etiqueta `p9.dr/managed-by=data-restore` | ArgoCD (no los sigue) |
| Objetos `Backup` | `Schedule` y sincronización del bucket | — | ArgoCD |
| `Schedule` | `velero-schedules` | — | el chart de Velero (`schedules: {}`) |

### 4.1 Barreras contra ciclos

1. **La raíz no puede administrar nada que no sea una hija.** Vive en `p9-bootstrap`, que solo admite `Application` en el namespace `argocd`. Un `AppProject`, un Deployment de ArgoCD o el `argocd-cm` en `apps/` se rechazan.
2. **Una hija no puede crear Applications (nietas) ni tocar ArgoCD.** `p9-platform` no tiene `argocd` entre sus destinos.
3. **Hueco que ningún AppProject cierra: un `apps/p9-root.yaml`.**
   - Es un `Application` en `argocd`, así que `p9-bootstrap` lo admite. La raíz se aplicaría a sí misma la versión de Git.
   - Terraform la revertiría en el siguiente `apply`, y el ciclo seguiría.
   - Se cierra con una validación estática antes de publicar (V-S3) que exige, para cada archivo de `apps/`:
     - `kind: Application`;
     - `metadata.name != p9-root`;
     - `spec.project == p9-platform`;
     - sin `finalizers`;
     - con anotación de ola.
4. **Los `clusterResourceWhitelist: */*` de `p9-platform` permiten que una hija modifique CRDs de ArgoCD** (`applications.argoproj.io`). No es un ciclo, pero es un riesgo residual: un filtro por grupo y kind no distingue el nombre del CRD. Se mitiga con la revisión en PR del repo GitOps.
5. **Velero nunca restaura Applications, Secrets ni workloads.** El `Restore` está acotado a PVC/PV (§2.3). Una restauración completa del namespace traería objetos con la anotación de seguimiento de ArgoCD y Secrets en conflicto con sus `SealedSecret`.
6. **`Delete=false` en los operadores y `Prune=false,Delete=false` en los PVC:** un error en Git o un `argocd app delete` no puede borrar CRDs ni volúmenes en cascada.

---

## 5. Orden completo del bootstrap

**Acciones humanas permitidas:**
- `az login` antes del bootstrap;
- lanzar el comando;
- la génesis P0, que ocurre una sola vez y antes de cualquier desastre.

Todo lo demás es automático.

| Paso | Qué | Quién | Espera observable (sin sleeps ciegos) | Timeout |
|---|---|---|---|---|
| P0 | **Génesis, solo la primera vez:** `RESTORE_MODE: skip-if-empty` en Git → primer despliegue → primer backup `Completed` del `Schedule` → `RESTORE_MODE: required` en Git (PR al repo GitOps). Antes de la prueba de DR debe estar en `required`. | operador, **antes** del desastre | `velero backup get` con al menos un `Completed` de `p9-sa-p5-db` | — |
| H | `az login` y `az account set --subscription "$ARM_SUBSCRIPTION_ID"` | operador | `az account show -o none` sale con 0 | — |
| 0 | `make -C P9 bootstrap` (o `./P9/scripts/bootstrap.sh all`) → `RTO_INICIO` | operador lanza | — | — |
| 1 | Backend del tfstate | `bootstrap.sh` | `terraform init` contra el backend | lock 120 s |
| 2 | `01-cluster`: plan y apply | Terraform | el apply termina | proveedor |
| 3 | kubeconfig propio y nodos | `bootstrap.sh` | `kubectl wait --for=condition=Ready nodes --all --timeout=10m` y al menos 2 nodos | 10 min |
| 4 | **[SECRETOS]** llave en `kube-system` | `restore-sealed-secrets-key.sh` | huella esperada presente y llaves activas = respaldadas | script |
| 5 | **[DÍA CERO]** `02-platform`: tenant → ArgoCD (Lua) → AppProjects + raíz | Terraform | `helm_release` con `wait = true` | 15 min |
| 6 | ArgoCD disponible y **Lua cargado** | `bootstrap.sh` | `kubectl -n argocd wait --for=condition=Available deployment --all --timeout=10m` <br>`kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=10m` <br>`kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=2m` <br>`kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.resource\.customizations\.health\.argoproj\.io_Application}' \| grep -q operationState` (falla temprano si quedó el Lua viejo) | 10 min |
| 7 | **Olas en orden**, con marca de tiempo por ola (desglose del RTO) | `bootstrap.sh` (`wait_waves`, abajo) | cada hija `Synced/Healthy` con `wait_application`, ola por ola | por ola (abajo) |
| 8 | Raíz | `bootstrap.sh` | `p9-root` `Synced/Healthy`. **No basta con que esté Healthy**: por H5 ignora a las hijas que aún no existen. `Synced` garantiza que existen todas. | 5 min |
| 9 | **[VELERO]** resultado de la restauración | `bootstrap.sh` | `kubectl -n velero logs job/p9-data-restore` contiene `RESTORE_OK` (o `IDEMPOTENTE`, o `GENESIS` si `RESTORE_MODE=skip-if-empty`) | — |
| 10 | Controladores | `bootstrap.sh` (`wait_controllers` + Velero) | `kubectl -n velero wait --for=condition=Available deployment/velero --timeout=5m` <br>`kubectl -n velero rollout status daemonset/node-agent --timeout=5m` <br>`kubectl -n velero wait --for=jsonpath='{.status.phase}'=Available backupstoragelocation/default --timeout=5m` <br>`kubectl -n velero wait --for=jsonpath='{.status.phase}'=Enabled schedule/p9-sa-p5-db --timeout=2m` <br>políticas en `Enforce` y `Ready` (ya existe) | 5 min |
| 11 | Workloads | `wait_workloads` (ya existe) | Deployments `Available`, StatefulSets `rollout status`, Rollout `Healthy` | 10 min |
| 12 | Endpoint externo → `RTO_FIN` | `wait_endpoint` | IP del `LoadBalancer`, y luego `curl` con backoff exponencial (abajo) | 10 min |

**`wait_waves`**, que reemplaza a `wait_all_applications`. Las olas se declaran en [lib/p9-config.sh](../scripts/lib/p9-config.sh), en la misma fuente que `P9_EXPECTED_APPS`, para no agregar `yq` a los prerrequisitos del bootstrap. V-S3 comprueba que coincidan con las anotaciones de `P9/gitops/apps/`.

```bash
# lib/p9-config.sh
# ola:app1,app2 — debe coincidir con argocd.argoproj.io/sync-wave en P9/gitops/apps (V-S3).
P9_WAVES="${P9_WAVES:--30:sealed-secrets -20:kyverno,argo-rollouts,velero -10:platform-secrets,data-restore -5:kyverno-policies 0:sa-platform 5:velero-schedules 10:platform-verify}"
# Presupuesto de espera por ola en segundos: es el límite para FALLAR, no una estimación del RTO.
P9_WAVE_TIMEOUTS="${P9_WAVE_TIMEOUTS:--30:600 -20:900 -10:2700 -5:600 0:1200 5:300 10:600}"

# lib/cluster-checks.sh
wait_waves() {
  local entry wave apps app budget t0
  for entry in $P9_WAVES; do
    wave=${entry%%:*}
    apps=${entry#*:}
    budget=$(tr ' ' '\n' <<<"$P9_WAVE_TIMEOUTS" | awk -F: -v w="$wave" '$1 == w {print $2}')
    [[ -n "$budget" ]] || die "Sin presupuesto de espera para la ola $wave."
    t0=$SECONDS
    for app in ${apps//,/ }; do
      wait_application "$app" "$budget"
      local got
      got="$(kubectl -n "$P9_ARGOCD_NAMESPACE" get application "$app" \
        -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/sync-wave}')"
      [[ "$got" == "$wave" ]] || die "La Application $app está en la ola '$got' del repo GitOps, no en $wave."
    done
    log "OLA $wave cerrada en $((SECONDS - t0))s: $apps"
  done
  wait_application "$P9_ROOT_APP" 300
}
```

**Por qué `kubectl` y no `argocd app wait`:** `argocd app wait` necesita una sesión con `argocd-server`, es decir, la contraseña admin leída de un Secret o un port-forward. Eso agrega una credencial y otra pieza al camino crítico. `wait_application` lee el mismo CR y vigila `sync` y `health` en la **misma** lectura. Dos `kubectl wait --for=jsonpath` seguidos (uno para sync y otro para health) podrían pasar con estados de instantes distintos.

**`curl` con backoff exponencial:** el código actual usa `--retry-delay 5`, un intervalo fijo. Si se omite `--retry-delay`, curl duplica la espera en cada intento (1 s, 2 s, 4 s…). `--retry-max-time` acota el total:

```bash
curl --fail --silent --show-error --max-time 10 \
  --retry 12 --retry-max-time 600 --retry-all-errors \
  -o /dev/null "http://$ip$path"
```

**Criterio del RTO:**
- Empieza en la línea `RTO_INICIO` que `bootstrap.sh` imprime al arrancar.
- Termina en `RTO_FIN`, después del último `OK http://…`.
- El log de las olas (`OLA … cerrada en Ns`) da el desglose para el informe.
- Los presupuestos de `P9_WAVE_TIMEOUTS` son límites de falla, **no** tiempos medidos.

---

## 6. Validación

### 6.1 Estática (antes de publicar en el repo GitOps)

| ID | Comando | Resultado esperado |
|---|---|---|
| V-S1 | `helm dependency build P9/charts/sa-platform && helm template sa-platform P9/charts/sa-platform -n sa-p5 -f P9/charts/sa-platform/values-azure.yaml \| yq ea -N '[.kind, .metadata.name, (.metadata.annotations["argocd.argoproj.io/sync-wave"] // "0")] \| join(" ")' \| sort -k3,3n` | `SealedSecret` en −1; PVC y StatefulSets de las bases en 0; Deployments, Rollout, HPA y CronJob en 1. **Ningún PVC en una ola menor que la de su StatefulSet.** |
| V-S2 | Se construye el ConfigMap con los mismos archivos que usa Terraform: `kubectl create configmap argocd-cm --dry-run=client -o yaml --from-file=resource.customizations.health.argoproj.io_Application=P9/terraform/modules/argocd/health/application.lua` (una `--from-file` por Lua) `> /tmp/argocd-cm.yaml`. Luego, por cada objeto de prueba en `P9/terraform/modules/argocd/health/testdata/*.yaml` (hija `Running`, hija `OutOfSync`, BSL `Available` sin `lastSyncedTime`, ClusterPolicy sin estado, HPA con `FailedGetResourceMetric`): `argocd admin settings resource-overrides health "$obj" --argocd-cm-path /tmp/argocd-cm.yaml`, con el CLI `argocd` v3.5.3 | El estado que declara cada Lua (§3). Los 5 Lua ya se probaron con 22 casos en Lua 5.1, el dialecto de gopher-lua que usa ArgoCD (ver la nota al final de la §6.1). |
| V-S3 | `for f in P9/gitops/apps/*.yaml; do yq -e '.kind == "Application" and .metadata.name != "p9-root" and .spec.project == "p9-platform" and .metadata.finalizers == null and .metadata.annotations["argocd.argoproj.io/sync-wave"] != null' "$f" >/dev/null \|\| echo "FALLA $f"; done`, y además comparar el conjunto `nombre:ola` con `P9_WAVES` | Ninguna línea `FALLA` y los conjuntos idénticos. Va en `audit-repo.sh` o en `publish-gitops.sh`. |
| V-S4 | Con el sistema desplegado, **antes de la prueba de DR**: `kubectl -n argocd get applications -o custom-columns=APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status` | Todas `Synced/Healthy`. Una hija `OutOfSync` permanente bloquearía la raíz (§3.1): se corrige con `ignoreDifferences` antes de destruir nada. |
| V-S5 | `helm template ... \| yq ea 'select(.kind == "Namespace" or (.kind == "Secret" and .metadata.name == "sa-platform-mysql"))'` | Vacío: `sa-platform` no crea `sa-p5` ni un Secret que compita con el `SealedSecret` (diseño de secretos, V-C9). |
| V-S6 | `kubeconform` o `kubectl apply --dry-run=server` de `platform/*` contra un clúster de prueba, y `shellcheck` del script extraído del ConfigMap | Sin errores. |

**Validaciones ejecutadas sobre este documento** el 2026-09-24. Se hicieron en un directorio temporal, sin tocar el repositorio, Azure ni ningún clúster.

| Qué | Herramienta | Resultado |
|---|---|---|
| Los 8 bloques YAML, incluidos los 10 objetos de `data-restore` | PyYAML 6.0.3 | parsean |
| `data-restore.sh` y `smoke.sh`, extraídos de sus ConfigMaps | `bash -n` / `sh -n` y shellcheck 0.11.0 | sin avisos |
| Los 5 Lua de la §3 con 22 casos (7 `Application`, 3 `ClusterPolicy`, 4 BSL, 4 `Schedule`, 4 HPA) | Lua 5.1 (lupa 2.8) | 0 fallas |
| Aserción de olas de la §6.2 | jq 1.8.1 | orden correcto → código 0; una ola creada antes de que cierre la anterior → 1; hija sin `history` → 1 |
| V-S3 | yq 4.47.2 | pasan las 5 Applications actuales de `P9/gitops/apps/`; detecta `apps/p9-root.yaml`, una hija con finalizer y una hija con `project: default`. La forma `(.metadata.finalizers \| length) == 0` da `false` dentro de un `and` en yq; por eso se usa `== null`. |
| `helm template` de una **copia** del chart con `values-azure.yaml` | helm 3.19.0 | • PVC `sa-platform-mysql-data` (`app=mysql`) y `sa-platform-mongodb-data` (`app=mongodb`), montados por `claimName`. <br>• NATS con `volumeClaimTemplates` (`sa-platform-nats-js`). <br>• Ningún `Namespace` ni `Secret` (V-S5 pasa hoy). <br>• Hoy **todos** los recursos están en la ola 0, porque las anotaciones de la §2.4 no están aplicadas. |

**No ejecutado:**
- V-S1 sobre el chart anotado.
- V-S2 con el CLI `argocd`.
- V-S4 a V-S6.
- Todas las validaciones de la §6.2 a la §6.5, que requieren un clúster.

### 6.2 ¿Se respetaron las olas? (durante y después del bootstrap)

Se prueba con **marcas de tiempo de los objetos**, no con texto de logs, que cambia entre versiones. Todo va a `P9/evidencia/bootstrap/`, en UTC.

**Nivel raíz: línea de tiempo y aserción.** La raíz crea las hijas de la ola k+1 solo después de que las de la ola k terminaron su primer sync:

```bash
ts=$(date -u +%Y%m%dT%H%M%SZ)
kubectl -n argocd get applications -o json | jq -r '.items[] | select(.metadata.name != "p9-root")
  | [(.metadata.annotations["argocd.argoproj.io/sync-wave"] // "0"), .metadata.name, .metadata.creationTimestamp,
     (((.status.history // []) | sort_by(.id) | first | .deployedAt) // "-"), .status.sync.status, .status.health.status]
  | @tsv' | sort -t$'\t' -k1,1n -k3,3 > "P9/evidencia/bootstrap/olas-$ts.tsv"

# Aserción: toda hija tiene un primer sync y min(creación de la ola k+1) >= max(primer deployedAt de la ola k).
# Sale con 0 solo si se cumple.
kubectl -n argocd get applications -o json | jq -e '
  [ .items[] | select(.metadata.name != "p9-root")
    | { w: (.metadata.annotations["argocd.argoproj.io/sync-wave"] // "0" | tonumber),
        c: .metadata.creationTimestamp,
        f: ((.status.history // []) | sort_by(.id) | first | .deployedAt) } ] as $a
  | ($a | all(.f != null))
    and ($a | group_by(.w) | map({w: .[0].w, minC: (map(.c) | min), maxF: (map(.f) | max)})
         | [range(1; length) as $i | .[$i].minC >= .[$i - 1].maxF] | all)'
```

- Se usa el **primer** elemento de `status.history`, y no `operationState`, porque un `selfHeal` posterior reemplaza a `operationState`.
- La condición `all(.f != null)` es necesaria: en jq `null` ordena por debajo de cualquier texto. Sin ella, una hija que nunca sincronizó haría pasar la comparación.

**Restauración antes que las bases** [VELERO]:

```bash
kubectl -n velero get restore -l p9.dr/managed-by=data-restore \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.status.startTimestamp}{"\t"}{.status.completionTimestamp}{"\n"}{end}'
kubectl -n sa-p5 get pvc -L velero.io/restore-name,velero.io/backup-name
kubectl -n sa-p5 get pod sa-platform-mysql-0 sa-platform-mongodb-0 -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.creationTimestamp}{"\n"}{end}'
```

Resultado esperado:
- el `Restore` está `Completed`;
- ambos PVC tienen `velero.io/restore-name` igual al nombre del `Restore`;
- `completionTimestamp` del `Restore` ≤ `creationTimestamp` de `sa-platform-mysql-0` y de `sa-platform-mongodb-0`.

**Olas dentro de `sa-platform`:**

```bash
kubectl -n sa-p5 get pods -o json | jq -r '.items[]
  | [.metadata.creationTimestamp, .metadata.name,
     ((.status.conditions // [])[] | select(.type == "Ready") | .lastTransitionTime)] | @tsv' | sort
```

Resultado esperado: los Pods de `auth`, `catalog`, `orders`, `notifications`, `api-gateway` y de los Jobs de `cron1`/`cron2` se crearon **después** del `Ready` de `sa-platform-mysql-0`, `sa-platform-mongodb-0` y `sa-platform-nats-0`. Los Pods recreados más tarde por HPA o por reinicios tienen marcas posteriores, así que no invalidan la aserción.

**Verificación funcional:** `kubectl -n sa-p5 logs job/p9-platform-verify` termina en `VERIFY_OK`.

**[VELERO] Marcador del RPO:** `cron1` inserta una fila en `cron_logs` cada 2 minutos. Tras la restauración, la última fila recuperada fija el punto de recuperación:

```bash
kubectl -n sa-p5 exec sa-platform-mysql-0 -- sh -c \
  'MYSQL_PWD="$MYSQL_PASSWORD" mysql -u"$MYSQL_USER" -D"$MYSQL_DATABASE" -N -e \
   "SELECT CONVERT_TZ(MAX(execution_time), \"-06:00\", \"+00:00\") FROM cron_logs"'
```

`execution_time` se guarda en hora de Guatemala, UTC−6 ([cron1/main.py](../cronjobs/cron1/main.py)). La consulta lo pasa a UTC para compararlo con los demás timestamps. RPO = `T_desastre` (UTC) − ese valor, con resolución de ±2 min. No debe confundirse con la duración del `Restore`.

### 6.3 Una hija queda en `Progressing`: diagnóstico

Se sigue en este orden y solo con `kubectl`. El paso 2 requiere `controller.resource.health.persist = "true"` (§3.7).

Primero se define `APP` con el nombre de la hija detenida. `bootstrap.sh` lo imprime en el mensaje "La Application … no llegó a Synced/Healthy" y en la columna `APP` del diagnóstico. Por ejemplo:

```bash
APP=sa-platform
```

1. **Qué está esperando la hija:**
   ```bash
   kubectl -n argocd get application "$APP" -o jsonpath='{.status.operationState.phase}{" | "}{.status.operationState.message}{"\n"}{.status.sync.status}{" / "}{.status.health.status}{" | "}{.status.health.message}{"\n"}'
   ```
   `Running` con "Retrying attempt #N" indica que la hija falla y reintenta; la razón viene en el mensaje. `OutOfSync` sin operación indica que el auto-sync no arrancó: revisar `.status.conditions`.
2. **Qué recurso no está `Healthy` o no está `Synced`:**
   ```bash
   kubectl -n argocd get application "$APP" -o json | jq -r '.status.resources[]
     | select((.health.status // "Healthy") != "Healthy" or .status != "Synced")
     | [.kind, (.namespace // "-"), .name, .status, (.health.status // "-"), (.health.message // "")] | @tsv'
   ```
3. **Qué hook o recurso detiene la ola:**
   ```bash
   kubectl -n argocd get application "$APP" -o json | jq -r '.status.operationState.syncResult.resources[]?
     | select(.hookPhase == "Running" or .hookPhase == "Failed" or .status == "SyncFailed")
     | [.kind, .name, (.syncPhase // "-"), (.hookPhase // "-"), .message] | @tsv'
   ```
4. **Causas conocidas en este sistema:**

| Recurso detenido | Comando | Causa típica y acción |
|---|---|---|
| PVC `Pending` | `kubectl -n sa-p5 describe pvc sa-platform-mysql-data sa-platform-mongodb-data` | `waiting for first consumer`: hay un consumidor en una ola posterior, lo cual es un error del diseño (V-S1). Otra posibilidad es la cuota de discos o la zona. |
| StatefulSet de MySQL o Mongo no listo | `kubectl -n sa-p5 logs sa-platform-mysql-0` | Recuperación de InnoDB en curso: esperar. `Access denied`: el Secret no coincide con el volumen restaurado (diseño de secretos, V-C7). |
| Deployment `Progressing` | `kubectl -n sa-p5 get events --field-selector reason=FailedCreate` y `kubectl -n sa-p5 get events --field-selector reason=Failed` | `admission webhook … denied`: política de Kyverno (firma o registro). `ImagePullBackOff`: `ghcr-secret`. `CreateContainerConfigError`: Secret ausente. |
| Rollout `Suspended` o `Progressing` | `kubectl -n sa-p5 get rollout sa-platform-api-gateway -o jsonpath='{.status.phase}{" "}{.status.message}{"\n"}'` | Pausa del canary (esperada en una actualización) o análisis fallido. |
| `SealedSecret` `Progressing` o `Degraded` | diseño de secretos §3.5 | Controlador caído, o `no key could decrypt secret`. |
| `ClusterPolicy` `Progressing` | `kubectl get clusterpolicy -o custom-columns='NOMBRE:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,MENSAJE:.status.conditions[?(@.type=="Ready")].message'` y `kubectl -n kyverno logs deploy/kyverno-admission-controller` | Kyverno todavía no configura el webhook, o hay un error en la política. |
| BSL `Degraded` | `kubectl -n velero get bsl default -o jsonpath='{.status.message}'` | Identidad o permisos sobre la cuenta de Blob; bucket o prefijo equivocados. |
| Hook `p9-data-restore` `Running` | `kubectl -n velero logs job/p9-data-restore -f` y `kubectl -n velero get restores,datadownloads` | Descarga del data mover en curso: esperar hasta `RESTORE_TIMEOUT_S`. `ERROR` en el log: seguir el runbook, contingencia R3. |
| Service `LoadBalancer` `Progressing` | `kubectl -n sa-p5 describe svc sa-platform-api-gateway` | Cuota de IP públicas o de balanceadores en la suscripción. |
| HPA `Degraded` | `kubectl -n sa-p5 describe hpa` | `FailedGetScale`: su objetivo está en otra ola (V-S1). Métricas: aplicar §3.6. |
| Hija `OutOfSync` permanente | paso 2 con `select(.status == "OutOfSync")` | Diferencia benigna (campo defaultado o mutado por un controlador): agregar `ignoreDifferences`. |

5. **Después de corregir la causa no hace falta pulsar `Sync`:** el reintento ilimitado toma el cambio.
   - Contingencia, solo si alguien dejó una hija con `retry` finito y quedó en `Failed` terminal:
     ```bash
     kubectl -n argocd patch application "$APP" --type merge -p '{"operation":{"initiatedBy":{"username":"runbook-contingencia"},"sync":{"revision":"main"}}}'
     ```
   - Esto es una intervención manual y se registra como brecha del bootstrap en el informe.

### 6.4 Contingencia R3: restauración fallida o volumen parcial

**Síntoma:** `p9-data-restore` termina con `ERROR` y cita R3.

**Alcance:** la ola −10 no cerró, así que `sa-platform` todavía no existe y ningún Pod usa los PVC.

**Qué dejó cada acción anterior:**
- En `sa-p5`: los PVC que llegó a crear el `Restore` fallido, con la etiqueta `velero.io/restore-name`.
- En `velero`: el objeto `Restore`, que hace que el Job se niegue a repetir.

1. **Guardar la evidencia**, que solo contiene fases, conteos y mensajes:
   ```bash
   r=$(kubectl -n velero get restores -l p9.dr/managed-by=data-restore --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}')
   kubectl -n velero get restore "$r" -o jsonpath='{.status}' > "P9/evidencia/restauracion/$r-status.json"
   kubectl -n velero get datadownloads -o custom-columns=NOMBRE:.metadata.name,FASE:.status.phase,MENSAJE:.status.message >> "P9/evidencia/restauracion/$r-status.json"
   ```
2. **Corregir la causa** según el mensaje: identidad o permisos de la BSL, cuota de discos, `DataDownload` fallido.
3. **Con autorización explícita**, porque es destructivo: borrar los PVC parciales y el `Restore` fallido.
   ```bash
   kubectl -n sa-p5 delete pvc -l velero.io/restore-name="$r"
   kubectl -n velero delete restore "$r"
   ```
4. **No hace falta pulsar `Sync`.** El reintento ilimitado de `data-restore` crea un Job nuevo (`BeforeHookCreation`), que ya no ve restauraciones previas y vuelve a empezar desde el paso 1 del script.
5. **Validación:** el log del Job nuevo termina en `RESTORE_OK` y los PVC tienen la etiqueta con el nombre del `Restore` nuevo.

Toda aplicación de R3 se registra en el informe como intervención manual y como punto de falla detectado.

### 6.5 Idempotencia: un segundo bootstrap no recrea nada

Se ejecuta con el sistema ya `Synced/Healthy`:

```bash
out=/tmp/p9-idem; mkdir -p "$out"
snap_apps() { kubectl -n argocd get applications -o json | jq -S '[.items[] | {n: .metadata.name, uid: .metadata.uid,
  op: .status.operationState.startedAt, hist: ((.status.history // []) | map(.id)), rev: .status.sync.revision}]'; }
snap_work() { kubectl -n sa-p5 get deploy,sts,rollout,pvc -o jsonpath='{range .items[*]}{.kind}/{.metadata.name} {.metadata.uid} {.metadata.generation}{"\n"}{end}' | sort; }
snap_keys() { kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.resourceVersion}{"\n"}{end}' | sort; }

snap_apps > "$out/apps-antes.json"; snap_work > "$out/work-antes.txt"; snap_keys > "$out/keys-antes.txt"
n_restores_antes=$(kubectl -n velero get restores -l p9.dr/managed-by=data-restore --no-headers 2>/dev/null | wc -l)
T=$(date -u +%Y-%m-%dT%H:%M:%SZ)

./P9/scripts/bootstrap.sh all 2>&1 | tee "$out/bootstrap-2.log"

snap_apps > "$out/apps-despues.json"; snap_work > "$out/work-despues.txt"; snap_keys > "$out/keys-despues.txt"
diff "$out/apps-antes.json" "$out/apps-despues.json" && diff "$out/work-antes.txt" "$out/work-despues.txt" && diff "$out/keys-antes.txt" "$out/keys-despues.txt"
[ "$(kubectl -n velero get restores -l p9.dr/managed-by=data-restore --no-headers 2>/dev/null | wc -l)" -eq "$n_restores_antes" ]
kubectl -n argocd get events --field-selector involvedObject.kind=Application,reason=OperationStarted \
  -o jsonpath='{range .items[*]}{.lastTimestamp}{" "}{.involvedObject.name}{"\n"}{end}' | awk -v t="$T" '$1 >= t'
grep -cE '\[(01-cluster|02-platform)\] plan sin cambios' "$out/bootstrap-2.log"
```

Resultado esperado:

| Qué | Esperado | Qué demuestra |
|---|---|---|
| Los tres `diff` | vacíos | No hubo operaciones nuevas en ArgoCD (`startedAt` y `history` iguales), no se recrearon workloads ni PVC (`uid` iguales) y no cambió ningún spec (`generation` igual). La llave no se reescribió (`resourceVersion` igual). |
| Conteo de `Restore` | igual | `data-restore` no volvió a correr: la Application no cambió, así que no hubo sync ni hook. |
| `awk` sobre los eventos | ninguna línea | ArgoCD no inició operaciones desde `T`. |
| `grep -c` | `2` | Terraform no planificó cambios en ninguna de las dos etapas. |

Complemento: con `kubectl -n argocd annotate application sa-platform argocd.argoproj.io/refresh=hard --overwrite`, la hija debe seguir `Synced/Healthy`, sin una operación nueva.

---

## 7. Cambios propuestos y decisiones pendientes

### 7.1 Archivo por archivo (ninguno aplicado todavía)

| Archivo | Cambio | Dueño del diseño |
|---|---|---|
| `P9/terraform/modules/argocd/main.tf` + `health/*.lua` (nuevos) | Los 5 Lua de la §3 y `controller.resource.health.persist` | este documento [DÍA CERO] |
| `P9/terraform/modules/app-of-apps-seed/main.tf` | `retry.limit = -1` | este documento [DÍA CERO] |
| `P9/gitops/apps/{sealed-secrets,kyverno,argo-rollouts,kyverno-policies,sa-platform}.yaml` | `retry` ilimitado; `Delete=false` en los operadores; `releaseName` en `sa-platform`; corregir el comentario de `kyverno.yaml` | este documento |
| `P9/gitops/apps/{velero,data-restore,velero-schedules,platform-verify}.yaml` | nuevos (§2.2, §2.3, §2.5) | este documento + [VELERO] |
| `P9/gitops/apps/platform-secrets.yaml` y `P9/gitops/platform-secrets/*` | nuevos | diseño de secretos (§2.5 ajusta el proyecto y el namespace) |
| `P9/gitops/platform/data-restore/data-restore.yaml`, `P9/gitops/platform/verify/verify.yaml` | nuevos (§2.3, §2.5) | este documento |
| `P9/gitops/platform/velero/values.yaml`, `P9/gitops/platform/velero-schedules/*.yaml` | nuevos; deben cumplir el contrato de §2.2 y §2.5 | diseño de Velero |
| `P9/charts/sa-platform/**` | solo anotaciones (§2.4) | este documento + [SECRETOS] (ola −1) |
| `P9/scripts/lib/p9-config.sh` | `P9_WAVES`, `P9_WAVE_TIMEOUTS` y `P9_EXPECTED_APPS` con las 10 hijas | este documento |
| `P9/scripts/lib/cluster-checks.sh` | `wait_waves`, comprobación del Lua cargado, Velero en `wait_controllers`, `curl` con backoff exponencial y corregir el comentario de la raíz | este documento |
| `P9/scripts/bootstrap.sh` | `stage_verify`: `wait_waves` y el paso 9 (log de `data-restore`) | este documento |
| `P9/scripts/publish-gitops.sh` | publicar `P9/gitops/platform/` → `platform/` y `P9/gitops/platform-secrets/` → `platform-secrets/`; ejecutar V-S3 antes del `rsync` | este documento |

### 7.2 Decisiones que requieren tu confirmación

- **D1. Cómo respalda Velero los PVC** [VELERO]. Este orden **solo funciona con snapshot CSI + data mover**. Si el diseño de Velero elige FSB, `data-restore` tendría que restaurar también los Pods, y eso choca con el StatefulSet que después crea ArgoCD. Habría que rediseñar.
- **D2. Imagen del Job de restauración:** `alpine/k8s` fijada por digest (lista hoy) o una imagen propia firmada en `ghcr.io/elfbibv` (más limpia; requiere un job de CI).
- **D3. HPA Lua (§3.6):** aplicarlo desde el inicio, o decidir según la primera corrida.
- **D4. Fusionar `sealed-secrets` en −20 (N1),** si Velero usa Workload Identity.
- **D5. Cadencia de la génesis (P0):** hay que definir quién hace el commit `skip-if-empty` → `required` y cuándo. Mientras quede en `skip-if-empty`, una BSL mal configurada levantaría bases vacías sin fallar.

### 7.3 Riesgos y límites que van al informe

- **GitHub (repo GitOps público) y GHCR son puntos únicos de fallo en tiempo de reconstrucción.** Sin ellos, las hijas quedan en `Unknown` o `ImagePullBackOff`, y el bootstrap falla por timeout con diagnóstico.
- **El TTL del `Schedule` acota la recuperación.** Si el clúster pasa más tiempo muerto que el TTL, el GC del clúster nuevo borra los respaldos vencidos al sincronizarlos.
- **La prueba de restauración de la rúbrica 2.6 dentro del clúster vivo (borrar un PVC y restaurar)** compite con `selfHeal`: `sa-platform` recrea el PVC vacío antes que Velero. El runbook debe suspender el auto-sync en este orden:
  1. primero en la raíz (Terraform es su dueño, así que un parche temporal no entra en ciclo);
  2. luego en `sa-platform`.

  Al final se reactiva en orden inverso. Otra opción es tomar como evidencia de 2.6 la propia reconstrucción total (se pierde el disco y se recupera el contenido). [VELERO]
- **Una hija `OutOfSync` permanente bloquea la raíz.** Es a propósito (§3.1): V-S4 lo detecta antes de la prueba.
