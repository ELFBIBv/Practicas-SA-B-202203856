# Diseño: Velero (respaldo y restauración) de P9

**Escrito para:** ti. Cierra el hueco que quedó pendiente en `diseno-sync-waves.md` y `diseno-secretos-dr.md`, que citan un "diseño de Velero" que nunca se había escrito.

**Estado:** implementado en código, **pendiente de ejecución contra Azure**. No corrí nada contra tu suscripción, contra AKS ni contra ningún clúster. Las decisiones de este documento fueron **confirmadas por ti** (storage account, autenticación, modo de respaldo, `Schedule`, BSL); lo que aporta este documento es el razonamiento, la implementación en Terraform/GitOps, la integración con los otros tres diseños y las validaciones. Verifiqué contra fuente primaria, el 2026-09-24:
- El esquema real del provider `azurerm` v5.6.0 (`terraform providers schema -json`) para `azurerm_storage_account`, `azurerm_storage_container`, `azurerm_user_assigned_identity`, `azurerm_federated_identity_credential`, `azurerm_role_assignment` y las `data` correspondientes.
- El chart `vmware-tanzu/velero` 12.2.0 (`values.yaml`, `templates/deployment.yaml`, `templates/node-agent-daemonset.yaml`, `templates/serviceaccount-server.yaml`), descargado del repositorio real.
- El `README.md` del plugin `velero-plugin-for-microsoft-azure` en su release real más reciente (`v1.14.3`, publicado 2026-09-21), incluida su tabla de compatibilidad con Velero.

## 1. Quién instala Velero, y por qué no es una Application

**Decisión:** Velero (CRDs, Deployment `velero`, DaemonSet `node-agent`, `ServiceAccount`, `BackupStorageLocation`, `VolumeSnapshotLocation`) lo instala **Terraform**, en `P9/terraform/02-platform/modules/velero`, con un `helm_release` — el mismo patrón que ya usa `module.argocd`. **No** es una `Application` de ArgoCD.

**Por qué.** Velero se autentica contra Azure con Workload Identity: el SDK de Azure lee `AZURE_CLIENT_ID` (de la anotación del `ServiceAccount`) y el token federado (`AZURE_FEDERATED_TOKEN_FILE`, que el webhook de Workload Identity proyecta en el Pod) **una sola vez, al arrancar el proceso**. Si el Pod arrancara antes de que exista la `azurerm_federated_identity_credential` que ata esa identidad al `ServiceAccount`, el primer intento de autenticación contra Blob Storage fallaría, y no hay garantía de que Velero reintente esa autenticación sin reiniciar el proceso. Es exactamente el mismo problema, con el mismo tipo de solución, que ya resolvió `diseno-secretos-dr.md` §3.3 para el controlador de Sealed Secrets: **el prerrequisito de identidad tiene que existir antes de que el Pod nazca**, no reconciliarse después.

Con Terraform como dueño, el orden es un `depends_on` normal (`helm_release.velero` depende de `azurerm_federated_identity_credential.velero`, ver `modules/velero/main.tf`). Con ArgoCD como dueño, habría dos malas opciones:
- Instalar Velero en una ola normal y esperar que la credencial ya exista: exigiría un `PreSync` hook fuera de ArgoCD que cree la credencial con `az`, con las mismas objeciones que `diseno-secretos-dr.md` §3.3 ya descartó para la llave de Sealed Secrets (imagen externa en el camino crítico, permisos de escritura sobre Azure AD dentro del clúster).
- Instalar Velero y confiar en que el Pod reinicie solo tras la propagación de la credencial: no es determinista, y una corrida de bootstrap no puede depender de "probablemente funcione en el segundo intento".

**Consecuencia sobre `P9/docs/diseno-sync-waves.md`:** ese diseño listaba `velero` como Application en la ola −20 (`P9_WAVES` antiguo: `-20:kyverno,argo-rollouts,velero`). Con esta decisión, **eso ya no aplica**: `velero` desaparece de `P9_WAVES` y de `P9/gitops/apps/`. El efecto práctico es el mismo o mejor: cuando la raíz `p9-root` hace su primer sync, Velero **ya existe** (lo creó Terraform en la etapa 6, antes de que exista la raíz), así que la garantía de orden "Velero antes de `data-restore`" la da la secuencia de Terraform, no un sync-wave. `P9/docs/diseno-sync-waves.md` queda desactualizado en ese punto — no lo edito (es uno de los documentos de diseño que no debo reescribir), pero este documento es la fuente de verdad vigente para todo lo relacionado con Velero, y `P9/scripts/lib/p9-config.sh` ya refleja el `P9_WAVES` correcto.

**Lo único que sigue siendo GitOps:** el objeto `Schedule` (`P9/gitops/apps/velero-schedules.yaml`, ola 5). Un `Schedule` no necesita identidad propia — lo procesa el servidor de Velero, que ya está corriendo — así que no tiene el problema de orden que sí tiene el operador. Mantenerlo en GitOps dejó una razón real para declararlo en código con revisión por PR, en vez de un `velero schedule create` imperativo (antipatrón explícito de CLAUDE.md).

## 2. Dónde vive el respaldo: capa persistente `00-persistent`

**Decisión confirmada:** cuenta de almacenamiento dedicada (`stp9velo` + 12 hex del hash de la suscripción, mismo patrón que `stp9tf` del backend de Terraform), en el resource group persistente `rg-p9-tfstate` (el mismo del backend, **no** el del clúster), contenedor privado `velero-backups`, SKU `Standard_LRS`.

**Por qué el mismo RG que el backend, y no uno nuevo.** El backend de Terraform ya es, por definición, el recurso que sobrevive a cualquier `terraform destroy` de `01-cluster`/`02-platform` (`decisiones-pendientes.md` 1.1). Reutilizar `rg-p9-tfstate` no le agrega una responsabilidad nueva al backend: sigue siendo Azure CLI quien lo crea y lo administra (`lib/tfstate-backend.sh`), y Terraform (`00-persistent`) solo **lee** ese resource group con un `data` source, nunca lo crea ni lo administra. Crear un tercer resource group solo para Velero sumaría una superficie más que proteger (candado de borrado, versionado) sin ganar aislamiento real: ambos ya están fuera del dominio de fallo de `01-cluster`.

### 2.1 Por qué Terraform y no Azure CLI (decisión que me aparto del "mismo contrato que el backend")

Se me pidió, como opción por defecto, seguir "el mismo contrato que el backend: lo crea `bootstrap.sh` con Azure CLI, no Terraform", salvo que yo eligiera Terraform y lo justificara. Elijo **Terraform**, con esta justificación:

- El motivo por el que el **backend mismo** no puede ser un recurso de Terraform es un problema de huevo-y-gallina genuino: el backend es el lugar donde Terraform guarda su estado, así que no puede crearse con Terraform sin ya tener un backend (`decisiones-pendientes.md` 1.1, `diseno-bootstrap-terraform.md` "Recomendación"). Ese problema **no existe** para `00-persistent`: cuando esta etapa corre, el backend remoto (para el estado de `00-persistent`) ya lo aseguró `bootstrap.sh` en la etapa 1. `00-persistent` es una tercera etapa de Terraform con su propia `key` (`p9/00-persistent.tfstate`) en el mismo backend que ya usan `01-cluster` y `02-platform` — ningún truco nuevo.
- La UAMI, el role assignment y la cuenta de almacenamiento son exactamente el tipo de recursos que Terraform modela mejor que un script imperativo: drift detection con `terraform plan`, un solo `apply` idempotente en vez de una cadena de `az ... show || az ... create`, y consistencia con cómo ya se documenta "quién administra qué" en el resto del repo.
- Mantenerlo en Terraform es coherente con dónde ya vive la `federated_identity_credential` (necesariamente en Terraform, porque el proveedor `azurerm` es quien expone ese recurso — no hay equivalente directo de un solo comando en `az` que sea tan explícito y revisable en un `plan`).

**Lo que si tomé del "mismo contrato que el backend":** `00-persistent` corre **antes** de `01-cluster` (igual que el backend corre antes que todo) y **nunca** se destruye cuando se destruye el clúster (`destroy-cluster.sh` solo toca `01-cluster`, ver su comentario de cabecera, que ya anticipaba correctamente "el almacenamiento de Velero" como algo fuera de su alcance).

### 2.2 `00-persistent` ya no es "solo Velero": también el Key Vault de secretos

**Hueco detectado y cerrado:** `P9/scripts/bootstrap.sh` (etapa 5, `stage_sealed_key`) y `P9/scripts/lib/p9-config.sh` (`SEALED_KEYRING_VAULT="kv-sa-p9-202203856"`) ya asumían que existe un Key Vault con ese nombre, pero ningún código lo creaba — el diseño de secretos (`diseno-secretos-dr.md` §3.1) lo especificaba como recurso de Terraform "en la capa persistente", pero esa capa (`00-persistent`) todavía no existía cuando se escribió ese diseño, y nadie volvió a cerrar el círculo hasta ahora.

Este módulo (`P9/terraform/00-persistent`) es esa capa persistente, así que el Key Vault vive aquí, junto al storage account y la UAMI de Velero — mismo resource group (`rg-p9-tfstate`), misma región, mismo motivo (sobrevive a la destrucción del clúster). No le cambio el nombre al módulo ni al directorio: `00-persistent` ya describía correctamente "todo lo que sobrevive al clúster", y Velero fue solo el primer inquilino.

**Recurso:** `azurerm_key_vault.sealed_secrets_custody`, `sku_name = "standard"`, `rbac_authorization_enabled = true` (RBAC de Entra ID, no access policies — nota: el atributo en azurerm v5.6.0 es `rbac_authorization_enabled`, no `enable_rbac_authorization`; verificado contra el esquema real del provider, la ambigüedad ya la había señalado `diseno-secretos-dr.md` §3.1 como algo "a verificar con la versión fijada"), `purge_protection_enabled = true`, `soft_delete_retention_days = 90`, `lifecycle { prevent_destroy = true }`.

**Dos roles, misma identidad humana, dos propósitos:**
- `azurerm_role_assignment.sealed_secrets_custodian` → **Key Vault Secrets Officer** sobre `var.custodian_object_id`. Lo usa `P9/scripts/backup-sealed-secrets-key.sh`, que corre **antes** del desastre, como acción humana explícita.
- `azurerm_role_assignment.sealed_secrets_bootstrap` → **Key Vault Secrets User** sobre `var.bootstrap_object_id`. Lo usa `P9/scripts/restore-sealed-secrets-key.sh`, invocado por `bootstrap.sh` durante la reconstrucción.

En esta práctica ambas variables valen lo mismo (una sola persona hace both roles), pero se declaran como dos variables sin default: el modelo de permisos documenta el propósito de cada acceso, no la identidad de quien lo tiene hoy. Ninguna de las dos es secreta — son GUID de Entra ID, no credenciales — pero tampoco tienen un valor por defecto razonable: un default silencioso podría terminar asignando roles sobre el vault a una identidad equivocada sin que nadie lo note. Se obtienen con `az ad signed-in-user show --query id -o tsv`.

## 3. Autenticación: Workload Identity, no Secret

**Decisión confirmada:** `credentials.useSecret: false` en el chart; la UAMI `id-sa-p9-velero` con rol `Storage Blob Data Contributor` **solo sobre el storage account de Velero** (no sobre la suscripción ni sobre el resource group persistente completo, que también contiene el backend de Terraform); `azure.workload.identity/client-id` en la anotación del `ServiceAccount` `velero-server`; `azure.workload.identity/use: "true"` como label de Pod, tanto en el Deployment del servidor como en el DaemonSet `node-agent` (verificado en el chart: ambos comparten el mismo `ServiceAccount`, `{{ include "velero.serverServiceAccount" . }}`, pero el label de Pod sale de dos claves de `values` distintas — `podLabels` para el servidor, `nodeAgent.podLabels` para `node-agent` — así que hay que poner el label en las dos).

**Por qué frente a un Secret con `AZURE_STORAGE_ACCOUNT_ACCESS_KEY` o un service principal con secreto:**
1. Cero material que respaldar o rotar. La llave de una cuenta de almacenamiento es un secreto de vida larga que, si se filtra, da acceso total al contenedor sin expiración; un token federado por Workload Identity se emite por minutos y no vive en ningún Secret de Kubernetes.
2. Coherente con `oidc_issuer_enabled = true` / `workload_identity_enabled = true`, que ya están en `P9/terraform/modules/cluster/main.tf` desde el diseño de día cero, con el comentario explícito "permiten que Velero (y External Secrets, si se adopta) accedan a Azure con identidades federadas, sin llaves estáticas". Este diseño es lo que cumple esa intención.
3. El rol se asigna sobre un recurso (el storage account de Velero), no sobre una credencial que viaja. Revocar acceso es borrar el role assignment, no rotar un secreto en todos los lugares donde se copió.

**Verificado en la fuente:** el `README.md` del plugin confirma `useAAD` como flag soportado y "Storage Blob Data Contributor" como el rol de datos que exige ese modo (fuera del control-plane `Contributor`/rol custom), consistente con lo que ya se le pide a la identidad. El plugin soporta Workload Identity como "Option 3" de sus tres mecanismos de autenticación documentados, con la propia quickstart de Azure AD Workload Identity como referencia.

## 4. Modo de respaldo: CSI snapshot + data mover, no FSB

**Decisión confirmada:** `deployNodeAgent: true`, `snapshotsEnabled: true`, `configuration.features: "EnableCSI"`, `VolumeSnapshotClass` `managed-csi` (la que ya trae AKS por defecto — no se declara una nueva), y `snapshotMoveData: true` en el `Schedule`.

**Por qué, y por qué no File System Backup (FSB/restic-kopia sobre el Pod).** Ya está razonado en `P9/docs/diseno-sync-waves.md` §0.7 y H10: FSB copia el contenido de un volumen **a través del Pod que lo tiene montado**, así que una restauración FSB necesita que el Pod (y por tanto su StatefulSet) exista **antes** que el volumen — exactamente al revés de lo que exige el orden de olas (`data-restore`, ola −10, restaura el PVC **antes** de que `sa-platform`, ola 0, cree el StatefulSet; y dentro del chart, PVC y StatefulSet van en la misma ola, nunca el PVC antes). Con CSI snapshot + data mover, `data-restore.sh` (Job de la ola −10, ver `P9/gitops/platform/data-restore/data-restore.yaml`) crea un `Restore` que solo pide `persistentvolumeclaims`/`persistentvolumes`, sin depender de que exista ningún Pod: el `node-agent` reconstruye el contenido directamente sobre el volumen restaurado.

**Por qué `snapshotMoveData: true` y no solo un snapshot CSI nativo.** Un `VolumeSnapshot`/`VolumeSnapshotContent` de Azure Disk vive, por defecto, en el resource group de nodos (`MC_*`) del clúster — el mismo resource group que se borra al destruir el clúster (`diseno-dia-cero.md` "Qué falta y contradicciones", punto 5: "Los discos de los PVC mueren con el clúster"). Sin `snapshotMoveData`, el snapshot sería una copia que no sobrevive al propio desastre que se está simulando, lo cual invalidaría por completo la rúbrica 2.3/2.6. Con `snapshotMoveData: true`, el `node-agent` copia el contenido del snapshot a Blob Storage (la cuenta de `00-persistent`) inmediatamente después de tomarlo, así que lo que sobrevive es el dato en Blob, no el snapshot efímero de Azure Disk.

**Consecuencia sobre `configuration.volumeSnapshotLocation.config.resourceGroup`:** apunta al **resource group del clúster** (`rg-p9-aks`, `var.aks_resource_group_name` en `modules/velero`), no al de nodos `MC_*`. Es una decisión explícita (así se pidió) y es segura precisamente porque el snapshot ahí es efímero — el dato real vive en Blob Storage en cuanto el data mover termina. Documento esto porque un lector que solo conozca "los snapshots de AKS viven en el RG de nodos" podría leerlo como error; no lo es, dado `snapshotMoveData: true`.

## 5. `BackupStorageLocation` y `Schedule`: valores exactos

`modules/velero/main.tf`, dentro de los `values` del `helm_release`:

```yaml
configuration:
  backupStorageLocation:
    - name: default              # data-restore.sh y P9_WAVE... lo esperan con este nombre
      provider: azure
      bucket: velero-backups      # var.storage_container_name (output de 00-persistent)
      config:
        resourceGroup: rg-p9-tfstate    # persistente; var.storage_resource_group_name
        storageAccount: stp9velo<hash>  # var.storage_account_name
        subscriptionId: <variable, no hardcodeada>
        useAAD: "true"
  volumeSnapshotLocation:
    - name: default
      provider: azure
      config:
        resourceGroup: rg-p9-aks   # RG del CLÚSTER, ver §4
```

`P9/gitops/platform/velero-schedules/schedule.yaml` (ola 5, Application `velero-schedules`):

```yaml
metadata:
  name: sa-p9-schedule
spec:
  schedule: "*/15 * * * *"
  template:
    ttl: 720h0m0s
    includedNamespaces: [sa-p5]
    excludedResources: [secrets, sealedsecrets.bitnami.com]
    snapshotMoveData: true
    storageLocation: default
    volumeSnapshotLocations: [default]
```

**Por qué cada 15 minutos.** `decisiones-pendientes.md` §2.5 ya sugería un rango de RPO de 15-30 minutos para esta práctica, sin cerrarlo. Un `Schedule` cada 15 minutos fija el **peor caso teórico** de RPO por cadencia de backup en 15 minutos (si el desastre ocurre justo antes del siguiente tick). Es el extremo más exigente del rango sugerido, lo cual es preferible a 30 min cuando el costo de correr un backup adicional cada 15 minutos es bajo (namespace pequeño, snapshot incremental). El RPO real medido depende además de la resolución del marcador de datos (`cron1` escribe cada 2 minutos, ver §7) y de en qué punto exacto del intervalo de 15 minutos ocurrió el desastre real — eso se mide, no se declara de antemano (§7).

**Por qué 720h (30 días) de TTL.** `P9/docs/diseno-sync-waves.md` §7.3 ya señala el riesgo: "el TTL del Schedule acota la recuperación. Si el clúster pasa más tiempo muerto que el TTL, el GC del clúster nuevo borra los respaldos vencidos al sincronizarlos." 30 días da margen amplio para cualquier ventana realista entre la prueba de DR y la reconstrucción dentro del calendario de esta práctica, sin acercarse a un problema de costo de almacenamiento (namespace pequeño, `Standard_LRS`).

**Por qué excluir `secrets` y `sealedsecrets.bitnami.com`, y por qué `kube-system` queda fuera por construcción.** Ya está razonado en `P9/docs/diseno-secretos-dr.md` §3.6 [PUNTO DE INTEGRACIÓN CON VELERO]: un `Secret` restaurado por Velero choca con su `SealedSecret` (`ErrUpdateFailed`, porque dos actores reclaman ser dueños del mismo objeto), y la llave del controlador de Sealed Secrets (que vive en `kube-system`) no debe terminar en un bucket que la identidad del clúster puede leer. `includedNamespaces: [sa-p5]` ya excluye `kube-system` por construcción (una lista de inclusión que no lo nombra), así que no hace falta una exclusión explícita adicional — la dejo así en vez de agregar `excludedNamespaces: [kube-system]` redundante.

## 6. Frontera con sync waves — quién administra qué (sin ciclos)

Actualiza la tabla de `P9/docs/diseno-sync-waves.md` §4 en lo que toca a Velero:

| Recurso | Lo administra | Nunca lo toca |
|---|---|---|
| Storage account, contenedor, UAMI de Velero | Terraform, `00-persistent` | `01-cluster`, `02-platform`, ArgoCD |
| Federated identity credential de Velero | Terraform, `02-platform/modules/velero` (necesita el emisor OIDC de `01-cluster`) | ArgoCD |
| CRDs, Deployment `velero`, DaemonSet `node-agent`, `ServiceAccount velero-server`, BSL `default`, VSL `default` | Terraform, `02-platform/modules/velero` (`helm_release`) | ArgoCD: ninguna Application declara estos objetos |
| `Schedule sa-p9-schedule` | Application `velero-schedules` (ArgoCD, ola 5) | el `helm_release` de Velero (`schedules: {}` en sus values) |
| Objetos `Backup` | El `Schedule` y la sincronización del bucket | ArgoCD, Terraform |
| Objetos `Restore` | Job `p9-data-restore` (ola −10, Application `data-restore`) | ArgoCD (no los sigue) |

**Por qué no hay ciclo:** `02-platform/modules/velero` no depende de ninguna Application (es Terraform puro, corre antes de que exista la raíz `p9-root`), y la única pieza que sí es ArgoCD (`velero-schedules`) no puede tocar el operador: su `Application` solo declara un `Schedule`, un tipo que Kyverno/ArgoCD nunca asocian con el `helm_release`. La `p9-platform` `AppProject` (que sí permite `clusterResourceWhitelist: */*`, ver `diseno-sync-waves.md` §4.1 punto 4) podría en teoría dejar que una `Application` maliciosa reconfigure el CRD de Velero, pero eso es el mismo riesgo residual ya documentado para Kyverno/Rollouts, mitigado por revisión en PR — no es un ciclo nuevo introducido por este diseño.

## 7. Cálculo de RPO

Mismo marcador que ya usa `diseno-sync-waves.md` §6.2: `cron1` inserta una fila en `cron_logs` cada 2 minutos (`P9/cronjobs/cron1/main.py`), en hora de Guatemala (UTC−6).

```bash
kubectl -n sa-p5 exec sa-platform-mysql-0 -- sh -c \
  'MYSQL_PWD="$MYSQL_PASSWORD" mysql -u"$MYSQL_USER" -D"$MYSQL_DATABASE" -N -e \
   "SELECT CONVERT_TZ(MAX(execution_time), \"-06:00\", \"+00:00\") FROM cron_logs"'
```

`RPO = T_desastre(UTC) − último execution_time recuperado (convertido a UTC)`.

**No confundir con la duración del `Restore`** (antipatrón explícito, `CLAUDE.md` y `diseno-sync-waves.md` §0.9/H10-H12): la duración del `Restore` es cuánto tarda `data-restore.sh` en terminar; el RPO es cuánto dato se perdió, medido contra el momento real del desastre, no contra cuándo empezó o terminó la restauración.

**Cota teórica vs. medida:** con `schedule: "*/15 * * * *"` y `cron1` escribiendo cada 2 minutos, el peor caso teórico de RPO por cadencia de backup es 15 minutos (el desastre ocurre justo antes del siguiente tick del `Schedule`); el mejor caso son unos segundos (el desastre ocurre justo después de que un backup terminó). El valor real se mide una vez, con la prueba de DR, y se reporta con marca de tiempo real — nunca se declara de antemano como si fuera el resultado (regla explícita de `CLAUDE.md`: "no ajustes RTO/RPO después de medir" aplica en la dirección inversa también: no declares un RPO medido antes de medirlo).

## 8. Validaciones para la rúbrica 2.3 y 2.6

Mismo formato que `diseno-secretos-dr.md` §5. Evidencia en `P9/evidencia/velero/`, marcas de tiempo UTC ISO 8601.

| ID | Comando | Resultado esperado |
|---|---|---|
| V-VL1 | `kubectl -n velero get backupstoragelocation default -o jsonpath='{.status.phase}{" "}{.status.lastSyncedTime}{"\n"}'` | `Available` y una marca de tiempo no vacía (H12: se escribe aunque el bucket esté vacío la primera vez). |
| V-VL2 | `kubectl -n velero get schedule sa-p9-schedule -o jsonpath='{.status.phase}{" "}{.spec.schedule}{" "}{.spec.template.ttl}{"\n"}'` | `Enabled`, `*/15 * * * *`, `720h0m0s`. |
| V-VL3 | `kubectl -n velero get backups -l velero.io/schedule-name=sa-p9-schedule -o json \| jq -r '.items[] \| select(.status.phase=="Completed") \| .metadata.name + " " + .status.startTimestamp + " " + .status.completionTimestamp'` | Al menos una fila. Sin esto no hay evidencia real de 2.3: un `Schedule` creado sin ningún `Backup` `Completed` no basta (bloqueante 8.1). |
| V-VL4 | `kubectl -n velero get backuprepositories -A` y `kubectl -n velero logs ds/node-agent --tail=50 \| grep -i error` | Sin errores de autenticación (`AADSTS`, `403`, `no such host`); confirma que Workload Identity está funcionando de punta a punta. |
| V-VL5 | `az role assignment list --scope "$(az storage account show -n <storage_account_name> -g rg-p9-tfstate --query id -o tsv)" --query "[?principalId=='<velero_principal_id de 00-persistent>'].roleDefinitionName" -o tsv` | `Storage Blob Data Contributor`. |
| V-VL6 | `az storage blob list --account-name <storage_account_name> --container-name velero-backups --auth-mode login --query "length(@)"` (requiere que quien ejecute el comando tenga también el rol de datos, o usar `az storage blob list --account-name ... --auth-mode key` con la llave, solo para auditoría puntual) | `> 0`: hay objetos reales en el bucket, no solo el registro del `Backup` en el clúster. |
| V-VL7 (RPO, §7) | Query SQL de §7 antes y después de una restauración real | Fila más reciente con `execution_time` menor al momento del desastre; RPO = diferencia. |

**Antes de la prueba de DR** (equivalente al P0 de `diseno-sync-waves.md` §5): debe existir al menos un `Backup` `Completed` anterior al `T0` de la prueba (V-VL3), y `RESTORE_MODE` debe estar en `required` en el repo GitOps (decisión 2.8, ya reflejada en `P9/gitops/platform/data-restore/data-restore.yaml`, hoy en `skip-if-empty` porque **todavía no existe ningún backup real** — ver runbook para el paso exacto de cambiarlo).

## 9. Riesgos y puntos únicos de fallo (para el informe de DR)

- **`rg-p9-tfstate` es un punto único de fallo compartido entre el backend de Terraform, los respaldos de Velero y AHORA también el Key Vault de custodia de secretos (§2.2).** Los tres sobreviven juntos o caen juntos. Mitigación: cada recurso tiene su propia protección (versionado + soft-delete de 30 días en el storage, `purge_protection_enabled` + soft-delete de 90 días en el vault), y los tres sobreviven a la pérdida del clúster, que es el escenario que pide la rúbrica. Ninguno sobrevive a una caída de toda la región `chilecentral` — mismo riesgo que ya declaraba `diseno-bootstrap-terraform.md` para el backend; se puede mitigar con `TFSTATE_LOCATION`/una región distinta para `00-persistent`, no implementado por defecto.
- **El scope de los role assignments del Key Vault es el vault mismo, no el resource group.** Aun así, quien tenga esos roles no tiene automáticamente acceso al storage account de Velero ni al backend de Terraform: son recursos distintos dentro del mismo RG, con sus propios role assignments (mínimo privilegio por recurso, no por resource group).
- **La cuenta de Velero prohíbe la llave compartida** (`shared_access_key_enabled = false`): si la Workload Identity fallara (propagación de RBAC, error de configuración del federated credential), no hay una vía de emergencia con llave. Es una decisión deliberada (menos superficie de fuga), documentada aquí como trade-off, no como omisión.
- **El plugin `velero-plugin-for-microsoft-azure` es de un tercero** (VMware Tanzu, no Microsoft ni Anthropic/Claude ni de este equipo): se fija por tag (`v1.14.3`), no por `latest`, y su compatibilidad con la versión del chart se verificó contra la tabla oficial del propio proyecto el 2026-09-24.

## 10. Supuestos y puntos de integración

- **[PUNTO DE INTEGRACIÓN CON DÍA CERO]** `oidc_issuer_enabled`/`workload_identity_enabled` ya estaban en `modules/cluster/main.tf` antes de este diseño, previstos exactamente para este uso. `02-platform/providers.tf` ya expone `data.azurerm_kubernetes_cluster.this`, de donde sale `oidc_issuer_url` sin necesitar un nuevo `data` source.
- **[PUNTO DE INTEGRACIÓN CON SECRETOS]** exclusiones del `Schedule` (§5); el `Schedule`, igual que la llave de Sealed Secrets, nunca pasa por Git en texto plano porque no contiene ningún secreto — es un objeto de configuración, no de credenciales.
- **[PUNTO DE INTEGRACIÓN CON SYNC WAVES]** `P9_WAVES` ya no incluye `velero`; `data-restore` (ola −10) asume que el operador de Velero, la BSL y el `Schedule`... **no**, el `Schedule` en sí (ola 5) llega **después** de `data-restore` (ola −10) a propósito — lo que `data-restore` necesita antes de él es la BSL disponible y sincronizada (garantizada por Terraform, no por una ola) y al menos un `Backup` `Completed` **previo al nacimiento del clúster**, que ya puede existir de una corrida anterior del `Schedule` aunque el objeto `Schedule` de esta reconstrucción todavía no se haya vuelto a crear.
- **Supuesto:** la cuenta de Azure usada para `az login` puede asignar roles RBAC (`Storage Blob Data Contributor`) y crear identidades administradas. Ya se verificó `Owner` para la cuenta usada (`decisiones-pendientes.md` 1.2), lo cual cubre esto.

## 11. Próximo paso

Con tu autorización, contra Azure real: `./P9/scripts/bootstrap.sh backend` (ya cubre `00-persistent` en su `tf_init`/`tf_plan`), y luego `./P9/scripts/bootstrap.sh plan` para revisar el primer `terraform plan` de `00-persistent` antes de cualquier `apply`.
