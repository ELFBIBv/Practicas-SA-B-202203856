# Runbook de recuperación — Práctica 9

**Para quién:** un operador que nunca vio este sistema y no puede contactar al autor. Todos los comandos se ejecutan en Bash **desde la raíz del repositorio de código** (`Practicas-SA-B-202203856`), son copiables tal cual y no requieren abrir ninguna UI.

**Qué cubre:** R-0 preparación · R-1 reconstrucción total · R-2 restauración de datos · R-3 continuidad de secretos · R-4 pérdida de nodo · R-5 verificación del flujo de P8 · R-6 prueba de DR cronometrada · R-7 tabla de fallos conocidos.

## Datos del sistema

| Elemento | Valor | Dónde está definido |
| --- | --- | --- |
| Suscripción | La activa en `az account show` (o `ARM_SUBSCRIPTION_ID`) | `scripts/lib/tfstate-backend.sh` |
| Región | `chilecentral` | `P9_LOCATION` en `scripts/lib/p9-config.sh` |
| Clúster (desechable) | `aks-sa-p9` en `rg-p9-aks`, nodos en `rg-p9-aks-nodes` | `scripts/lib/p9-config.sh` |
| Backend de Terraform | Azure Storage: RG `rg-p9-tfstate`, cuenta `stp9tf` + 12 hex del SHA-256 de la suscripción, contenedor `tfstate`, blobs `p9/<etapa>.tfstate`; lock = blob lease | `scripts/lib/tfstate-backend.sh` |
| Custodia de la llave | Key Vault `kv-sa-p9-202203856`, secreto `sealed-secrets-keyring` | `terraform/00-persistent` |
| Respaldos | Cuenta `stp9velo…` (en `rg-p9-tfstate`), contenedor `velero-backups`; Schedule `sa-p9-schedule` (`*/15 * * * *`, TTL `1440h`) | `terraform/00-persistent`, `gitops/platform/velero-schedules/schedule.yaml` |
| Repo GitOps (público) | `https://github.com/ELFBIBv/Practicas-SA-B-202203856-gitops`, rama `main` | `terraform/02-platform/variables.tf` |
| Aplicación raíz | `p9-root`, namespace `argocd` | `P9_ROOT_APP` |
| Namespace de la app | `sa-p5` (se conserva de P8: los SealedSecret `strict` están atados a él) | `P9_APP_NAMESPACE` |
| Endpoint | `http://<IP pública del Service sa-platform-api-gateway>`; la IP se llama `pip-sa-p9-gateway` | `terraform/modules/cluster` |

**Definición de RTO usada en todo el runbook:** inicio = `RTO_INICIO` (el operador lanza `bootstrap.sh`); fin = `RTO_FIN` (los 4 endpoints `/ready`, `/api/auth/health`, `/api/catalog/health`, `/api/orders/health` responden 2xx). Ambos los imprime el script en UTC.

---

## R-0. Preparación (una vez por máquina / antes de la prueba)

### R-0.1 Herramientas

- **Objetivo:** tener las CLI que usan los scripts.
- **Comando:**
  ```bash
  for c in az terraform kubectl helm git curl jq yq openssl gunzip rsync kubeseal; do printf '%-10s ' "$c"; command -v "$c" >/dev/null && echo ok || echo FALTA; done
  terraform version | head -1
  ```
- **Resultado esperado:** todas `ok`; Terraform ≥ 1.9.0. `yq` debe ser el de Mike Farah (v4).
- **Validación:** `yq --version` muestra `mikefarah`.
- **Contingencia:** instale lo que falte. `yq` sin `sudo`, verificando su checksum (así se instaló en la máquina del autor el 2026-10-16):
  ```bash
  mkdir -p ~/.local/bin && d="$(mktemp -d)" && cd "$d"
  for f in yq_linux_amd64 checksums checksums_hashes_order; do curl -fsSLO "https://github.com/mikefarah/yq/releases/latest/download/$f"; done
  col=$(($(grep -n '^SHA-256$' checksums_hashes_order | cut -d: -f1) + 1))
  [ "$(grep '^yq_linux_amd64 ' checksums | awk -v c="$col" '{print $c}')" = "$(sha256sum yq_linux_amd64 | cut -d' ' -f1)" ] && install -m 0755 yq_linux_amd64 ~/.local/bin/yq
  cd - >/dev/null
  ```
  `kubeseal`: <https://github.com/bitnami-labs/sealed-secrets/releases> (solo para V-A4 de R-0.3). Terraform: <https://developer.hashicorp.com/terraform/install>. No continúe con herramientas faltantes: los scripts fallan temprano con `Falta el comando requerido`.

### R-0.2 Sesión de Azure y permisos

- **Objetivo:** autenticarse con una identidad que pueda crear recursos y asignaciones de rol.
- **Comando:**
  ```bash
  az login
  az account set --subscription "Azure for Students"   # o el ID de la suscripción destino
  az account show --query '{suscripcion:name, usuario:user.name}' -o table
  az role assignment list --assignee "$(az ad signed-in-user show --query id -o tsv)" --all \
    --query "[?roleDefinitionName=='Owner' || roleDefinitionName=='User Access Administrator' || roleDefinitionName=='Contributor'].{rol:roleDefinitionName, ambito:scope}" -o table
  ```
- **Resultado esperado:** `Owner` sobre la suscripción (o `Contributor` + `User Access Administrator`).
- **Validación:** la tabla muestra el rol con ámbito `/subscriptions/…`.
- **Contingencia:** sin permiso de asignar roles, Terraform falla al crear `azurerm_role_assignment`. Pida al dueño de la suscripción el rol `User Access Administrator`. Si la identidad no tiene rol de datos sobre el backend, `bootstrap.sh` intenta asignarse `Storage Blob Data Contributor` y, si no puede, cae a autenticación por llave de cuenta en memoria (`TFSTATE_AUTH=auto`).

### R-0.3 La llave de Sealed Secrets está en custodia

- **Objetivo:** confirmar que existe la llave que descifra los SealedSecret del repo. **Sin ella no hay continuidad de secretos.**
- **Comando:**
  ```bash
  az keyvault secret show --vault-name kv-sa-p9-202203856 --name sealed-secrets-keyring \
    --query '{actualizado:attributes.updated, habilitado:attributes.enabled, etiquetas:tags}' -o json
  ```
- **Resultado esperado:** `habilitado: true` y fecha de actualización. El comando **no** imprime el valor.
- **Validación (opcional, sin clúster):** `SEALED_KEYRING_VAULT=kv-sa-p9-202203856 ./P9/scripts/verify-sealed-secrets-offline.sh` imprime `OK` por cada SealedSecret y termina con `rc=0`. Requiere `kubeseal`.
- **Contingencia:** si el secreto no existe y el clúster anterior sigue vivo, respáldelo antes de continuar: `SEALED_KEYRING_VAULT=kv-sa-p9-202203856 ./P9/scripts/backup-sealed-secrets-key.sh from-cluster <contexto>`. Si el clúster ya no existe y no hay copia, los SealedSecret actuales son **irrecuperables**: registre la pérdida en el informe, genere una llave nueva (`backup-sealed-secrets-key.sh generate`) y vuelva a sellar los secretos desde su fuente original (PAT de GHCR, contraseñas). Eso es génesis, no continuidad.

### R-0.4 Respaldos disponibles y modo de restauración estricto

- **Objetivo:** que la reconstrucción restaure datos reales y falle si no puede (en vez de levantar bases vacías).
- **Comando:**
  ```bash
  curl -fsSL https://raw.githubusercontent.com/ELFBIBv/Practicas-SA-B-202203856-gitops/main/platform/data-restore/data-restore.yaml | grep -E '^\s+RESTORE_MODE:'
  export KUBECONFIG="$HOME/.kube/p9-aks-sa-p9.config"   # lo crea bootstrap.sh; si no existe, ejecute: ./P9/scripts/bootstrap.sh verify
  kubectl -n velero get backups -l velero.io/schedule-name=sa-p9-schedule \
    --sort-by=.status.startTimestamp -o custom-columns='BACKUP:.metadata.name,FASE:.status.phase,INICIO:.status.startTimestamp,EXPIRA:.status.expiration' | tail -5
  ```
- **Resultado esperado:** `RESTORE_MODE: required` y al menos un backup `Completed`.
- **Validación:** `kubectl -n velero get backupstoragelocation default -o jsonpath='{.status.phase}'` → `Available`.
- **Contingencia:** si dice `skip-if-empty`, edite `P9/gitops/platform/data-restore/data-restore.yaml` a `required` y publíquelo (R-0.5). Si no hay backup `Completed`, espere al siguiente tick de 15 min; si sale `PartiallyFailed`, vea R-7 (fila Velero).

### R-0.5 El repo GitOps coincide con `P9/`

- **Objetivo:** que ArgoCD aplique exactamente lo versionado en `P9/`.
- **Comando:**
  ```bash
  rm -rf /tmp/p9-gitops && git clone -q https://github.com/ELFBIBv/Practicas-SA-B-202203856-gitops.git /tmp/p9-gitops
  ./P9/scripts/publish-gitops.sh /tmp/p9-gitops
  git -C /tmp/p9-gitops status --short
  ```
- **Resultado esperado:** sin cambios. Si hay cambios, `publish-gitops.sh` los deja preparados.
- **Validación:** `git -C /tmp/p9-gitops diff --stat` vacío.
- **Contingencia:** si hay diferencias, publíquelas por PR (`git -C /tmp/p9-gitops switch -c sync-p9 && git -C /tmp/p9-gitops commit -am "sync P9" && git -C /tmp/p9-gitops push -u origin sync-p9`, luego `gh pr create -R ELFBIBv/Practicas-SA-B-202203856-gitops --fill && gh pr merge --merge`). ArgoCD toma `main` solo; no hace falta ningún `Sync` manual.

---

## R-1. Reconstrucción total (punto de entrada único)

Úselo tras perder el clúster (o en día cero). Todo lo demás lo hace el script; el operador no interviene hasta el final.

### R-1.1 Plan en seco (recomendado, no cambia nada)

- **Objetivo:** confirmar backend, permisos y el plan de Terraform antes de aplicar.
- **Comando:** `./P9/scripts/bootstrap.sh plan`
- **Resultado esperado:** `[STAGE]` 1, 2, 3 y 6 sin `[ERROR]`; `plan con cambios` o `plan sin cambios` por etapa. `02-platform no se planifica` si el clúster no existe.
- **Validación:** código de salida 0 (`echo $?`).
- **Contingencia:** `Error acquiring the state lock` → otro operador está aplicando; espere. Si el lease quedó huérfano (proceso muerto), rompa el lock: `az storage blob lease break --account-name <cuenta stp9tf…> -c tfstate -b p9/<etapa>.tfstate --auth-mode login` (la cuenta la imprime la etapa 1).

### R-1.2 Reconstrucción

- **Objetivo:** reconstruir infraestructura, plataforma, secretos, datos y aplicación.
- **Comando:** `make -C P9 bootstrap` (equivale a `./P9/scripts/bootstrap.sh all` y guarda el log crudo en `P9/evidencia/bootstrap/raw/`).
- **Resultado esperado (orden observable en el log):**
  1. Backend asegurado · 2. `00-persistent` · 3. `01-cluster` (AKS, ~10-20 min) · 4. nodos `Ready` (≥2) · 5. `restore-sskey` restaura la llave (huella SHA-256 igual al `pub-cert.pem`) · 6. `02-platform` (ArgoCD, Velero, `p9-root`) · 7. ArgoCD disponible · 8. olas `-30 → 10` cerradas, `p9-root Synced/Healthy` · 9. `data-restore: RESTORE_OK …` · 10. controladores y 3 políticas `Enforce` · 11. workloads listos · 12. `Gateway respondiendo en http://<IP>`.
  Última línea: `RTO_INICIO=… RTO_FIN=… RTO_SEGUNDOS=…`.
- **Validación:** `./P9/scripts/bootstrap.sh verify` (repite 7-12 sin tocar nada) termina en 0.
- **Contingencia:** el script es idempotente: corrija la causa y **vuelva a ejecutar el mismo comando**; Terraform y ArgoCD retoman donde quedaron. Diagnóstico por etapa en R-7.

---

## R-2. Restauración de datos (clúster vivo, pérdida lógica)

### R-2.1 Prueba de restauración verificada

- **Objetivo:** demostrar que un dato borrado se recupera del respaldo **programado** y medir el RPO.
- **Comando:** `make -C P9 dr-restore-test`
- **Qué hace:** inserta `M1` en `sa_p5.p9_dr_marker` → espera un Backup del Schedule posterior a `M1` (hasta 25 min) → inserta `M2` → borra ambos de producción (`DESASTRE`) → `Restore` de Velero del PVC de MySQL en el namespace aislado `p9-restore-check` → MySQL temporal sobre ese volumen → consulta → reinserta en producción lo recuperado.
- **Resultado esperado:** `M1` presente en el volumen restaurado, `M2` ausente, `RESTAURACION_OK` y `RPO_MEDIDO_S=<n>`.
- **Validación:** log en `P9/evidencia/restauracion/restauracion-<UTC>.log`; en producción: `kubectl -n sa-p5 exec sa-platform-mysql-0 -- sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -N sa_p5 -e "SELECT * FROM p9_dr_marker ORDER BY escrito_utc DESC LIMIT 5"'`.
- **Contingencia:** `Restore … PartiallyFailed` → `kubectl -n velero describe restore <nombre>` y `kubectl -n velero get datadownloads`. Namespace de verificación colgado → `kubectl delete namespace p9-restore-check`.

### R-2.2 Restaurar los volúmenes de producción en su lugar (incidente real)

- **Objetivo:** recuperar MySQL/MongoDB cuando sus PVC se perdieron o corrompieron en un clúster vivo.
- **Comando (orden obligatorio: con autosync activo, ArgoCD recrearía los PVC vacíos antes que Velero):**

```bash
export KUBECONFIG="$HOME/.kube/p9-aks-sa-p9.config"
# 1. Pausar la reconciliación (primero la raíz, que si no revierte el cambio en la hija).
kubectl -n argocd patch application p9-root --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
kubectl -n argocd patch application sa-platform --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
# 2. Detener las bases y retirar los volúmenes dañados.
kubectl -n sa-p5 scale statefulset sa-platform-mysql sa-platform-mongodb --replicas=0
kubectl -n sa-p5 delete pvc sa-platform-mysql-data sa-platform-mongodb-data --wait=true
# 3. Último backup Completed del Schedule.
BACKUP=$(kubectl -n velero get backups -l velero.io/schedule-name=sa-p9-schedule -o json \
  | jq -r '[.items[] | select(.status.phase=="Completed")] | sort_by(.status.startTimestamp) | last | .metadata.name')
echo "Restaurando desde $BACKUP"
# 4. Restore limitado a PVC/PV de las bases (mismo alcance que el Job p9-data-restore).
kubectl create -f - <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata: {name: p9-manual-$(date -u +%Y%m%d%H%M%S), namespace: velero}
spec:
  backupName: $BACKUP
  includedNamespaces: [sa-p5]
  includedResources: [persistentvolumeclaims, persistentvolumes]
  orLabelSelectors: [{matchLabels: {app: mysql}}, {matchLabels: {app: mongodb}}]
  restorePVs: true
EOF
kubectl -n velero get restores --sort-by=.metadata.creationTimestamp -w   # esperar Completed, luego Ctrl+C
# 5. Reactivar la reconciliación: la raíz devuelve el autosync a sa-platform y éste levanta las bases.
kubectl -n argocd patch application p9-root --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

- **Resultado esperado:** Restore `Completed`; PVC `Bound` con la etiqueta `velero.io/restore-name`; `sa-platform` vuelve a `Synced/Healthy` con los StatefulSets en 1 réplica.
- **Validación:** `kubectl -n sa-p5 get pvc -L velero.io/restore-name` y la consulta de R-2.1 sobre `p9_dr_marker`/`cron_logs`.
- **Contingencia:** `PartiallyFailed` → `kubectl -n velero describe restore <nombre>` y `kubectl -n velero get datadownloads`. Si `sa-platform` no recupera el autosync en 3 min, confírmelo con `kubectl -n argocd get application sa-platform -o jsonpath='{.spec.syncPolicy.automated}'` y fuerce la reconciliación de la raíz: `kubectl -n argocd annotate application p9-root argocd.argoproj.io/refresh=hard --overwrite`.
- **Nota:** el Job `p9-data-restore` de la ola `-10` **no** sirve aquí: por diseño solo elige respaldos anteriores al nacimiento del clúster (evita restaurar un respaldo del propio bootstrap) y solo corre en la reconstrucción.

---

## R-3. Continuidad de secretos

### R-3.1 Verificar que el clúster usa la llave custodiada

- **Objetivo:** confirmar que los SealedSecret del repo se descifran tras la reconstrucción.
- **Comando:**
  ```bash
  kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key=active -o jsonpath='{.items[0].data.tls\.crt}' \
    | base64 -d | openssl x509 -noout -fingerprint -sha256
  openssl x509 -in P9/gitops/sealed-secrets/pub-cert.pem -noout -fingerprint -sha256
  kubectl get sealedsecrets -A -o custom-columns='NS:.metadata.namespace,NOMBRE:.metadata.name,SYNCED:.status.conditions[?(@.type=="Synced")].status'
  ```
- **Resultado esperado:** ambas huellas idénticas; los 6 SealedSecret con `SYNCED=True`.
- **Validación:** el consumidor funciona: `kubectl -n sa-p5 get deploy sa-platform-auth` con `AVAILABLE` = réplicas (lee `JWT_SECRET` y `DB_PASSWORD` de Secrets sellados).
- **Contingencia:** huellas distintas → el controlador arrancó sin la llave. Reinyéctela y reinicie el controlador:
  ```bash
  SEALED_KEYRING_VAULT=kv-sa-p9-202203856 AKS_RESOURCE_GROUP=rg-p9-aks AKS_NAME=aks-sa-p9 ./P9/scripts/restore-sealed-secrets-key.sh
  kubectl -n kube-system rollout restart deployment/sealed-secrets-controller
  kubectl -n kube-system logs deployment/sealed-secrets-controller --since=5m | grep -iE 'error|unseal|decrypt'
  ```
  Un `SYNCED=False` con `no key could decrypt secret` confirma llave equivocada. Un `ErrUpdateFailed` indica que existe un `Secret` con el mismo nombre que no pertenece al SealedSecret: bórrelo (`kubectl -n <ns> delete secret <nombre>`) y el controlador lo recrea.

---

## R-4. Prueba de pérdida de nodo

- **Objetivo:** demostrar que el servicio responde mientras se drena un nodo.
- **Comando:** `make -C P9 dr-node-test` (opcional `NODE=<nombre>`; por defecto, el nodo con más réplicas del gateway).
- **Qué hace:** verifica ≥2 nodos y que cada workload replicado ocupa ≥2 nodos → sondea `http://<IP>/ready`, `/api/catalog/health` y `/api/orders/health` cada segundo → `kubectl drain <nodo> --ignore-daemonsets --delete-emptydir-data --timeout=15m` (**sin** `--force` ni `--disable-eviction`: respeta los PDB) → espera Deployments/StatefulSets/Rollout listos → `kubectl uncordon <nodo>`.
- **Resultado esperado:** `VEREDICTO OK` y `NODO_OK`; por ruta, disponibilidad ≥ 99 %.
- **Validación:** log `P9/evidencia/nodo/drenaje-<UTC>.log` y sondeo crudo `P9/evidencia/nodo/sondeo-<UTC>.csv`.
- **Contingencia:** el drenaje se queda en `Cannot evict pod as it would violate the pod's disruption budget` → hay un Pod sin réplica sana en otro nodo; revise `kubectl -n sa-p5 get pods -o wide`. Si el nodo quedó acordonado tras un fallo: `kubectl uncordon <nodo>`. **Solo** en un incidente real (no en la prueba) y si el nodo está perdido: `kubectl drain <nodo> --ignore-daemonsets --delete-emptydir-data --force --disable-eviction` (anula PDB).
- **Antes de repetir la prueba:** tras el `uncordon`, Kubernetes **no** reparte de nuevo los Pods: quedan todos en el nodo que no se drenó, y el script se niega a correr (`Réplicas concentradas en un solo nodo`). Reequilibre y espere a que todo esté listo:
  ```bash
  kubectl -n sa-p5 rollout restart deployment
  kubectl -n sa-p5 patch rollout sa-platform-api-gateway --type merge -p "{\"spec\":{\"restartAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}"
  kubectl -n sa-p5 rollout status deployment --timeout=5m
  ./P9/scripts/wait-for-rollout.sh sa-platform-api-gateway sa-p5 Healthy 300
  kubectl -n sa-p5 get pods -o wide
  ```
- **Límite conocido:** MySQL, MongoDB y NATS tienen 1 réplica con disco RWO; si el nodo drenado los aloja, las rutas que dependen de la base fallan mientras el disco se reasigna (~1-3 min). Se reporta tal cual en el informe.

---

## R-5. Verificación del flujo heredado de P8

- **Objetivo:** confirmar GitOps, entrega progresiva y admisión tras la reconstrucción.
- **Comando:**
  ```bash
  kubectl -n argocd get applications -o custom-columns='APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,AUTO:.spec.syncPolicy.automated.selfHeal'
  kubectl -n sa-p5 get rollout sa-platform-api-gateway -o jsonpath='{.status.phase}{" "}{.spec.template.spec.containers[0].image}{"\n"}'
  kubectl get clusterpolicy -o custom-columns='POLITICA:.metadata.name,ACCION:.spec.validationFailureAction,READY:.status.conditions[?(@.type=="Ready")].status'
  kubectl -n sa-p5 run p9-policy-check --image=nginx:latest --restart=Never --dry-run=server
  ```
- **Resultado esperado:** todas las Applications `Synced/Healthy` con `AUTO=true`; Rollout `Healthy`; 3 políticas `Enforce`/`True`; el `kubectl run` es **rechazado** por `restrict-image-registries`/`require-non-root-user`.
- **Validación:** el rechazo devuelve código ≠ 0 y el mensaje nombra la política.
- **Contingencia:** una política en `Audit` o ausente → revise la Application `kyverno-policies` (`kubectl -n argocd describe application kyverno-policies`). Rollout `Degraded` → `kubectl argo rollouts get rollout sa-platform-api-gateway -n sa-p5` o `kubectl -n sa-p5 describe rollout sa-platform-api-gateway`.

---

## R-6. Prueba de DR cronometrada (destruir y reconstruir)

**Irreversible y con costo. Solo con autorización del dueño de la suscripción.**

- **Objetivo:** medir RTO y RPO reales en una pérdida total del clúster.
- **Comando:** `make -C P9 dr-rebuild-test CONFIRM=aks-sa-p9`
- **Qué hace:** R-0.3/R-0.4 automáticos → marcador `M1` → espera Backup programado posterior → marcador `M2` → `DESASTRE_INICIO` → `destroy-cluster.sh` (borra `rg-p9-aks`; backend, Key Vault y respaldos quedan intactos) → `bootstrap.sh all` → verifica `M1` sí / `M2` no, SealedSecret `Synced`, huella de la llave, Applications, Rollout, políticas y rechazo de Kyverno → imprime `RTO_MEDIDO_S`, `CAIDA_TOTAL_S` y `RPO_MEDIDO_S`.
- **Resultado esperado:** `RECONSTRUCCION_OK`.
- **Validación:** log `P9/evidencia/reconstruccion/reconstruccion-<UTC>.log` (GUID redactados). Copie los valores al [informe](informe-dr.md).
- **Contingencia:** si falla durante `bootstrap.sh`, el clúster ya no existe: siga R-1.2 (repetir el mismo comando). El log conserva `DESASTRE_INICIO` para el cálculo.

---

## R-7. Fallos conocidos y diagnóstico

| Síntoma (log / estado) | Causa probable | Acción |
| --- | --- | --- |
| `No hay sesión de Azure CLI` | Falta `az login` | R-0.2 |
| `Error acquiring the state lock` | Otro `apply` en curso o lease huérfano | Esperar; si es huérfano, `az storage blob lease break` (R-1.1) |
| `MissingSubscriptionRegistration` | Proveedor no registrado | El backend registra `Microsoft.Storage` y `Microsoft.KeyVault`; para otros: `az provider register -n <proveedor> --wait` |
| `PublicIPCountLimitReached` / Service `<pending>` | Cuota de 3 IP públicas por región | P9 usa una sola IP (`pip-sa-p9-gateway`, salida + gateway). Libere IPs ajenas o pida cuota |
| Ola `-30` no cierra; `no key could decrypt` | Llave no restaurada | R-3.1 contingencia |
| Ola `-10` no cierra; `data-restore … no hay respaldo Completed` | `RESTORE_MODE=required` sin backups previos al clúster | R-0.4; si es génesis real, cambie temporalmente a `skip-if-empty` por PR y documéntelo |
| Backup `PartiallyFailed`, `failed to get volumesnapshotclass` | Falta la `VolumeSnapshotClass` etiquetada | `kubectl get volumesnapshotclass -l velero.io/csi-volumesnapshot-class=true` debe listar `p9-velero-azuredisk` (la crea Terraform `02-platform`) |
| `Restore` en `WaitingForPluginOperations` ~30 min y luego `PartiallyFailed`; `DataDownload` con `error to wait target PVC consumed` | El node-agent no tiene `restorePVC.ignoreDelayBinding` y `managed-csi` es `WaitForFirstConsumer` | `kubectl -n velero get cm velero-node-agent-config -o jsonpath='{.data}'` debe mostrar `ignoreDelayBinding: true` y `kubectl -n velero get ds node-agent -o jsonpath='{.spec.template.spec.containers[0].args}'` debe incluir `--node-agent-configmap`; ambos los pone Terraform `02-platform` |
| Pods `sa-p5` rechazados por `verify-image-signatures` | `kyverno/ghcr-secret` no descifrado | R-3.1; luego `kubectl -n kyverno rollout restart deployment` |
| Ola `0` no cierra; `FailedCreate` con `verify-signature: … ghcr.io/token … DENIED` o `… manifests … DENIED`, y los SealedSecret `ghcr-secret` siguen `Synced=True` | El token de GHCR sellado en `ghcr-secret` expiró, fue revocado o no tiene `read:packages` (ocurrió en la reconstrucción del 2026-10-17) | 1) Cree un token *classic* de la cuenta dueña de los paquetes con solo `read:packages`. 2) En una terminal propia: `./P9/scripts/rotate-ghcr-secret.sh` (lo valida contra GHCR antes de sellar). 3) `./P9/scripts/publish-gitops.sh <clon-del-repo-gitops>` y merge del PR. 4) Para no esperar el backoff de los ReplicaSet: `kubectl -n sa-p5 get rs -o name \| xargs -I{} kubectl -n sa-p5 annotate {} p9.dr/retry=$(date +%s) --overwrite` |
| `kubectl drain` vence esperando que terminen Pods ya `Completed`/`Error`; `kyverno-admission-controller` `Pending` por `Insufficient cpu` | Sin réplica viva del admission controller, su webhook (`failurePolicy: Fail`, también en `DELETE`) bloquea el borrado y los Pods nuevos | `kubectl -n kyverno get pods -l app.kubernetes.io/component=admission-controller -o wide` debe mostrar 2 réplicas en nodos distintos (`gitops/apps/kyverno.yaml`); contingencia: `kubectl uncordon <nodo>` |
| Pods `Pending` con `Insufficient cpu` o `didn't match pod topology spread constraints` durante un drenaje | Falta capacidad N-1 | `kubectl get nodes` debe listar el nodo `aks-spare-*` (`spare_node_count` en `terraform/01-cluster`); contingencia: `kubectl uncordon <nodo>` |
