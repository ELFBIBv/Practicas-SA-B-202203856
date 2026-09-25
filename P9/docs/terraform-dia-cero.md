# Terraform de día cero: AKS, ArgoCD y siembra del app-of-apps

Criterios de rúbrica: **2.1 Bootstrap automatizado**, **2.2 Disciplina de IaC** y la parte de **2.6** que depende de reconstruir ArgoCD, Rollouts y Kyverno.

**Estado:** *implementado sin ejecutar contra Azure*. Se verificó localmente:

- `terraform fmt`/`validate` con Terraform 1.16.4 y los providers fijados;
- el render de los charts `argo-cd` y `argocd-apps` con los valores reales de los módulos;
- `shellcheck` sobre los scripts;
- una prueba funcional de las esperas con un `kubectl` simulado.

Siguen **pendientes**:

- ningún `plan`/`apply` real ni tiempo medido;
- la publicación de `P9/gitops/` en el repositorio GitOps;
- el script de reinyección de la llave de Sealed Secrets, que pertenece al diseño de secretos.

## 1. Decisiones

| Decisión | Elegido | Motivo |
| --- | --- | --- |
| División del Terraform | **Dos etapas con estado propio**: `01-cluster` (Azure) y `02-platform` (dentro del clúster) | `02-platform` configura los providers `kubernetes`/`helm` con un *data source* del clúster ya creado. En una sola raíz, esos providers reciben valores *known after apply*. En día cero funciona por casualidad, pero tras un desastre fuera de banda (el clúster desaparece y el estado sigue ahí) el refresh intenta conectarse con credenciales viejas y la reconstrucción falla. |
| Instalación de ArgoCD | **`helm_release` en Terraform** (chart `argo-cd` 10.9.2 = ArgoCD v3.5.3) | El enunciado exige que Terraform instale ArgoCD. Con `wait = true`, Terraform no termina hasta que ArgoCD está listo, y `upgrade_install = true` adopta la release si el estado se perdió. Un `kubectl apply` desde el script sacaría a ArgoCD de la IaC y no tendría detección de drift. |
| Siembra de la raíz | **`helm_release` del chart `argocd-apps`** (2 AppProject + Application raíz) | `kubernetes_manifest` consulta el CRD `Application` durante el `plan`, y en día cero ese CRD no existe todavía. Con Helm no hay problema: los CRD ya los instaló la release anterior. |
| ArgoCD administrándose a sí mismo | **No** | Terraform es el único dueño de ArgoCD, de los AppProject y de la raíz. Así se elimina el ciclo en que la raíz intenta recrear o reconfigurar a su padre. |
| Módulo de P8 (namespace/cuotas/RBAC) | **Se conserva como submódulo `modules/tenant`**, sin providers propios y con recursos `_v1` | Era un entregable de P8, y la rúbrica 2.6 pide conservar P8. Además, crea `sa-p5` antes de la siembra, así Terraform y ArgoCD no compiten por crear el namespace. |

## 2. Estructura

```
P9/terraform/
├── 01-cluster/            raíz · estado p9/01-cluster.tfstate · provider azurerm
│   ├── backend.tf         backend "azurerm" {} (parcial; lo completa bootstrap.sh)
│   ├── versions.tf        terraform >= 1.9, azurerm ~> 5.6, provider azurerm
│   ├── main.tf            module "cluster"
│   ├── variables.tf       nombres, región, tamaño de nodos (con justificación de costo)
│   ├── outputs.tf         versión real de k8s, emisor OIDC, RG de nodos
│   └── .terraform.lock.hcl
├── 02-platform/           raíz · estado p9/02-platform.tfstate · azurerm + kubernetes + helm
│   ├── backend.tf  versions.tf  providers.tf  (data "azurerm_kubernetes_cluster")
│   ├── main.tf            tenant → argocd → seed
│   ├── variables.tf  outputs.tf  .terraform.lock.hcl
└── modules/
    ├── cluster/           RG desechable + AKS
    ├── tenant/            namespace sa-p5, ResourceQuota, LimitRange, RBAC (de P8)
    ├── argocd/            helm_release argo-cd + Lua de health de Application
    └── app-of-apps-seed/  helm_release argocd-apps: AppProjects + Application raíz
P9/gitops/apps/            Applications hijas (se publican en el repo GitOps)
P9/scripts/                bootstrap.sh · destroy-cluster.sh · publish-gitops.sh
  lib/                     common.sh · p9-config.sh · tfstate-backend.sh · cluster-checks.sh
```

## 3. Recursos de Azure y costo (Azure for Students)

| Recurso | Configuración | Justificación |
| --- | --- | --- |
| `rg-p9-aks` | Resource group desechable | Separado de `rg-p9-tfstate`. Destruirlo no toca el estado. `prevent_deletion_if_contains_resources` evita borrar algo agregado a mano. |
| AKS `aks-sa-p9` | `sku_tier = Free`, `kubernetes_version = null` | Plano de control sin costo. Con `null`, AKS usa su versión por defecto de la región: tras un desastre, una versión fijada puede estar retirada y bloquear la reconstrucción. La versión real queda en el output `kubernetes_version`, para la evidencia. |
| Node pool `system` | 2 × `Standard_DS2_v2` (4 vCPU), disco de SO administrado de 64 GB, `max_surge = 1` | Es el tamaño con el que P8 ya corrió todo el stack en `chilecentral`. Cabe en la cuota regional típica de estudiante (6 vCPU), incluido el nodo extra de un upgrade. Dos nodos es el mínimo para la prueba de drenaje (la variable lo valida). Usar 64 GB en vez de 128 abarata el segundo costo por nodo. |
| `node_provisioning_profile` | `mode = "Manual"` | azurerm 5.x lo exige. Manual significa nodos fijos, sin autoaprovisionamiento: el costo es predecible. |
| Identidad | `SystemAssigned` | Sin service principal ni secreto que custodiar. |
| OIDC issuer + Workload Identity | Habilitados, sin costo | Para Velero (y External Secrets, si se adopta): acceso a Azure sin llaves estáticas en el clúster. |
| Red | Azure CNI overlay + Cilium (igual que P8), LB estándar | Las `NetworkPolicy` del chart requieren un motor de políticas. No hay VNet propia: AKS crea la suya en el RG de nodos y la borra con el clúster. |
| Autenticación a la API | Cuentas locales habilitadas (certificado de cliente) | `02-platform` y `bootstrap.sh` obtienen credenciales con la sesión de `az`, sin exigir `kubelogin` (TF-4 del diseño de secretos). Costo: el certificado queda en el estado de `02-platform`, que es privado, remoto y versionado. |
| **No se crean** | ACR, Log Analytics, VNet propia, NAT Gateway, Application Gateway | Las imágenes están en GHCR (prerrequisito externo) y el enunciado no exige observabilidad de Azure. |

El costo dominante son las 2 VM, sus discos y la IP pública del LoadBalancer. Todo desaparece con `destroy-cluster.sh`.

## 4. Orden completo y criterio de RTO

`./P9/scripts/bootstrap.sh` (o `make -C P9 bootstrap`) después de `az login`:

| Etapa | Qué hace | Espera o verificación observable |
| --- | --- | --- |
| 0 | Prerrequisitos | `az`, `terraform >= 1.9`, `kubectl`, `curl`, `git` y sesión de `az` |
| 1 | Backend remoto (ver [`terraform-backend.md`](terraform-backend.md)) | RG, cuenta y contenedor existen; autenticación resuelta |
| 2 | `01-cluster`: `init` → `plan -out` → `apply` del plan | `apply` termina con el AKS aprovisionado |
| 3 | `az aks get-credentials --file ~/.kube/p9-aks-sa-p9.config` | `kubectl wait --for=condition=Ready nodes --all`, con al menos 2 nodos |
| 4 | **[SECRETOS]** `restore-sealed-secrets-key.sh` | Si el script no existe, falla (`PENDIENTE`) |
| 5 | `02-platform`: `init` → `plan -out` → `apply` (tenant → ArgoCD → siembra) | `helm_release` con `wait = true` |
| 6 | ArgoCD disponible | Deployments `Available`, StatefulSet del controlador `rollout status`, CRD `Established` |
| 7 | Raíz `p9-root` y cada hija esperada | `sync.status/health.status == Synced/Healthy`, sondeo cada 10 s con timeout y diagnóstico; `selfHeal` activo en `sa-platform` |
| 8 | Controladores y políticas | `sealed-secrets-controller`, Argo Rollouts y Kyverno `Available`; 3 `ClusterPolicy` en `Enforce` y `Ready` |
| 9 | Workloads de `sa-p5` | Deployments `Available`, StatefulSets `rollout status`, Rollout del gateway `Healthy` |
| 10 | Endpoint | IP del LoadBalancer asignada; `/ready`, `/api/auth/health`, `/api/catalog/health` y `/api/orders/health` responden 2xx |

**RTO:**

- **Inicio:** `RTO_INICIO`, cuando el operador lanza el comando.
- **Fin:** `RTO_FIN`, la primera respuesta 2xx de los 4 endpoints de la etapa 10.
- **Cómo se mide:** el script imprime ambas marcas en UTC y `RTO_SEGUNDOS`. El log crudo queda en `P9/evidencia/bootstrap/raw/` (ignorado por git; se revisa antes de versionarlo).

Orden dentro de ArgoCD (sync waves). Las waves esperan de verdad gracias al Lua de health de `Application` en `argocd-cm`:

| Wave | Application | Dueño del contenido |
| --- | --- | --- |
| −30 | `sealed-secrets` | Este diseño (valores del diseño de secretos) |
| −20 | `argo-rollouts`, `kyverno` (y `velero`, pendiente) | Este diseño |
| −10 | `platform-secrets` | Diseño de secretos (pendiente) |
| −5 | `kyverno-policies` | Este diseño; las políticas vienen de `P9/kyverno/policies` |
| 0 | `sa-platform` | Heredada de P8 |

## 5. Propiedad y ciclo de administración

| Recurso | Lo crea y administra | Protección |
| --- | --- | --- |
| Backend, Key Vault de custodia, almacenamiento de Velero | Capa persistente (fuera de los dos estados) | Ningún `destroy` de P9 los alcanza |
| RG, AKS | `01-cluster` | — |
| `sa-p5`, cuotas, RBAC | `02-platform` / `modules/tenant` | Se crea antes de la siembra |
| ArgoCD | `02-platform` / `modules/argocd` | Ninguna Application lo referencia |
| AppProject `p9-bootstrap`, `p9-platform` y Application `p9-root` | `02-platform` / `modules/app-of-apps-seed` | — |
| Applications hijas | `p9-root`, desde `apps/` del repo GitOps | `p9-bootstrap` solo admite objetos `Application` en `argocd` y ningún recurso de clúster |
| Workloads | Cada hija, en el proyecto `p9-platform` | Destinos limitados a `sa-p5`, `argo-rollouts`, `kyverno`, `kube-system` y `velero` |

**Por qué la raíz no puede administrarse a sí misma:** aunque alguien agregue a `apps/` un manifiesto de ArgoCD, de un AppProject o de la propia raíz, el AppProject `p9-bootstrap` rechaza el sync. Esto se verificó con `helm template`: `p9-bootstrap` tiene como único `namespaceResourceWhitelist` a `argoproj.io/Application` y no tiene `clusterResourceWhitelist`.

**Permisos:** el `application-controller` del chart tiene un ClusterRole amplio (`createClusterRoles: true`, valor por defecto). Por eso puede crear las Applications hijas en `argocd` y los recursos de cada hija. Los AppProject son la capa que limita qué puede hacer cada Application.

**Conexión con el repo GitOps:** `https://github.com/ELFBIBv/Practicas-SA-B-202203856-gitops.git`, rama `main`, carpeta `apps/`. Es público, así que no hay credenciales. Si pasa a ser privado: **[SECRETOS]** un Secret de repositorio que venga del almacén externo, nunca de Terraform.

## 6. Idempotencia y destrucción para la prueba de DR

- **Si el clúster ya existe:** los dos `plan` salen sin cambios (código 0), y los `apply` aplican un plan vacío. `helm_release` con `upgrade_install` adopta releases existentes aunque el estado se haya perdido. Las esperas de las etapas 6 a 10 pasan de inmediato.
- **Destruir solo el clúster:**

  ```bash
  ./P9/scripts/destroy-cluster.sh --confirm aks-sa-p9
  ```

  Hace `plan -destroy` + `apply` de `01-cluster`. Registra `DESASTRE_INICIO`/`DESASTRE_FIN` y comprueba que `rg-p9-aks` ya no existe y que el backend sigue disponible. **No** destruye `02-platform`: su estado queda desactualizado a propósito. En la reconstrucción, el refresh contra el clúster nuevo no encuentra releases ni namespace y los recrea. Es el mismo camino que un desastre real.
- **Desastre fuera de banda:** `az group delete -n rg-p9-aks --yes` también se recupera con `bootstrap.sh`. El refresh de `01-cluster` ve que el RG no existe y lo recrea.
- **Lo que se pierde con el clúster:** los discos de los PVC viven en `rg-p9-aks-nodes` y se destruyen con él. **[VELERO]** los respaldos deben ir a almacenamiento de la capa persistente, con file-system backup o snapshots fuera del RG de nodos.

## 7. Contradicciones y pendientes

1. **`P9/gitops/` no está publicado en el repo GitOps.** Hasta abrir y mergear el PR (`./P9/scripts/publish-gitops.sh <clon>`), la raíz no encuentra `apps/` y el bootstrap termina en timeout en la etapa 7. Publicarlo es un cambio remoto que requiere autorización.
2. **Workflow de CI:** `promote-to-gitops` de P8 sincroniza `P8/charts/sa-platform` hacia el repo GitOps y **pisaría** la copia de P9. Se necesita un workflow de P9 o cambiar la fuente, respetando las rutas de P8.
3. **`argocd/application.yaml` (P8) en el repo GitOps** tiene el mismo nombre que la hija `sa-platform`. Hay que borrarlo en el mismo PR para que no haya dos dueños.
4. **Llave de Sealed Secrets:** sin `restore-sealed-secrets-key.sh`, `bootstrap.sh all` falla en la etapa 4. `P9_ALLOW_NEW_SEALED_KEY=1` sirve solo para probar la infraestructura y deja un aviso de que la corrida no vale como evidencia.
5. **Capa persistente:** el diseño de secretos describe el Key Vault en HCL, pero la capa persistente de este diseño se crea con Azure CLI (`tfstate-backend.sh`) y no es un estado de Terraform. Hay que decidir si el Key Vault se agrega a esa capa con el mismo patrón idempotente o a una tercera raíz `00-persistent` con `prevent_destroy`. En ambos casos, las asignaciones de rol requieren Owner.
6. **Nombres heredados:** el namespace `sa-p5` y los nombres de los Secrets no se renombran a P9, porque el ciphertext de Sealed Secrets está ligado a ellos (ver el diseño de secretos, §6).

## 8. Validaciones

| # | Comando (desde la raíz del repo) | Resultado esperado | Estado |
| --- | --- | --- | --- |
| 1 | `terraform -chdir=P9/terraform fmt -check -recursive` | Código 0 | Verificado (1.16.4) |
| 2 | `make -C P9 validate` | `Success!` en `01-cluster` y `02-platform` | Verificado sobre una copia |
| 3 | `helm template` de `argo-cd` 10.9.2 y `argocd-apps` 2.0.5 con los valores de los módulos | Lua en `argocd-cm`; 2 AppProject y raíz con los whitelists de §5 | Verificado. Detectó y corrigió un `:` en `description` que rompía el render |
| 4 | `shellcheck -x` en los scripts nuevos | Sin avisos | Verificado |
| 5 | `./P9/scripts/bootstrap.sh plan` | `01-cluster`: plan de creación. `02-platform`: omitido si no hay clúster | Pendiente (Azure) |
| 6 | `make -C P9 bootstrap` | Etapas 1 a 10 y `RTO_INICIO`/`RTO_FIN` en el log | Pendiente (Azure + puntos 1 y 4 de §7) |
| 7 | Repetir el paso 6 | Ambos planes sin cambios; verificaciones en verde | Pendiente |
| 8 | `./P9/scripts/destroy-cluster.sh --confirm aks-sa-p9` y luego el paso 6 | Reconstrucción completa; backend intacto | Pendiente (prueba cronometrada) |
| 9 | `make -C P9 audit` | `Auditoría superada.` | Verificado |
