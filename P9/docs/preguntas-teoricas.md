# Preguntas teóricas — análisis del sistema propio ante escenarios de pérdida

Respuestas sobre **este** sistema (P9), con la ruta que lo implementa y su efecto en RTO, RPO y disponibilidad. Donde la respuesta depende de una medición, se cita la prueba de DR ejecutada en AKS el 2026-10-17 ([`informe-dr.md`](informe-dr.md)); estas respuestas no deben contradecir ese informe.

### 1. ¿Qué se pierde de forma irreversible si se destruye `aks-sa-p9` ahora mismo?

Todo lo escrito en MySQL/MongoDB después del **inicio** del último Backup `Completed` del Schedule `sa-p9-schedule` (cada 15 min, [`gitops/platform/velero-schedules/schedule.yaml`](../gitops/platform/velero-schedules/schedule.yaml)): peor caso ≈15 min más la duración del respaldo. También los mensajes de NATS JetStream y el historial de ArgoCD/Rollouts, que no se respaldan (NATS está en `sa-p5` y su PVC entra en el backup, pero no hay marcador que lo verifique: es un límite). No se pierde: estado de Terraform, llave de Sealed Secrets, respaldos, manifiestos ni imágenes, porque viven fuera del RG `rg-p9-aks`.

### 2. ¿Por qué el RPO no es "lo que tarda el restore"?

El RPO mide datos perdidos: `DESASTRE_INICIO − escrito_utc` del último dato recuperado (`M1` en `p9_dr_marker`, [`scripts/dr-rebuild-test.sh`](../scripts/dr-rebuild-test.sh)). La duración del `Restore` (lo que imprime `data-restore.sh`, `restore_inicio`/`restore_fin`) es parte del **RTO**. En este sistema una restauración más rápida no reduce el RPO; solo un Schedule más frecuente lo hace.

### 3. Si el clúster nuevo arrancara sin la llave de Sealed Secrets, ¿qué pasaría y cómo se notaría?

El controlador generaría una llave nueva; los 6 `SealedSecret` quedarían `Synced=False` (`no key could decrypt secret`), no se crearían `sa-platform-mysql`, `ghcr-secret`, etc., y los Pods de `sa-p5` quedarían en `CreateContainerConfigError`/`ImagePullBackOff`; Kyverno rechazaría los Pods al no poder verificar firmas sin `kyverno/ghcr-secret`. El bootstrap lo detecta: la ola `-10` no cierra y [`lib/cluster-checks.sh`](../scripts/lib/cluster-checks.sh) imprime el estado de los SealedSecret antes de fallar. Para evitarlo, [`restore-sealed-secrets-key.sh`](../scripts/restore-sealed-secrets-key.sh) reinyecta la llave **antes** de instalar ArgoCD y el controlador corre con `keyrenewperiod: "0"`. "Re-sellar con la llave nueva" no es continuidad: requiere los valores en claro, que ya no existen.

### 4. ¿Qué pasa si se pierde el backend de Terraform?

Terraform no sabría qué recursos existen. La reconstrucción del clúster seguiría funcionando (el `bootstrap` recrea la cuenta `stp9tf…` vacía y `01-cluster` crea todo de cero), pero `00-persistent` intentaría crear recursos que ya existen (storage de Velero, Key Vault) y fallaría hasta importarlos (`terraform import`). Mitigación actual: el backend está en un RG distinto al del clúster (`rg-p9-tfstate`) y el blob tiene versionado/soft-delete. Riesgo residual: misma región y `Standard_LRS`.

### 5. Durante el drenaje de un nodo, ¿por qué el gateway sigue respondiendo y qué rutas podrían fallar?

El gateway tiene 5 réplicas, `topologySpreadConstraints` por `kubernetes.io/hostname` (maxSkew 1, `nodeTaintsPolicy: Honor`) y anti-afinidad preferida ([`charts/sa-platform/charts/api-gateway/templates/rollout.yaml`](../charts/sa-platform/charts/api-gateway/templates/rollout.yaml)), así que ≈2-3 réplicas quedan en el otro nodo; el PDB (`minAvailable: 1`) obliga a `kubectl drain` a desalojar gradualmente y el readiness (`timeoutSeconds: 3`) no saca Pods sanos del endpoint por lentitud. Además, cada contenedor tiene `lifecycle.preStop.sleep` de 5 s: el Pod desalojado sigue sirviendo mientras el Service y el balanceador lo retiran de los endpoints. Sin eso, la prueba local en `kind` (2026-10-16) registró 1 conexión rechazada en 100 sondeos; con `preStop`, 0 fallos en 470 y 414 sondeos drenando cada uno de los dos nodos. Esa prueba local no sustituye la evidencia en AKS. Lo mismo aplica a auth, catalog, orders y notifications (2 réplicas). **Pueden fallar** las rutas que tocan MySQL/MongoDB si su único Pod está en el nodo drenado: el disco Azure RWO se desmonta y vuelve a montar en el otro nodo (1-3 min). Resultado medido en AKS el 2026-10-17 ([`evidencia/nodo/`](../evidencia/nodo/), [informe §5](informe-dr.md#5-puntos-únicos-de-fallo-detectados)): 100 % de disponibilidad en tres drenajes (1 740, 1 355 y 1 230 sondeos). En la segunda corrida MongoDB y NATS quedaron `Pending` sin que fallara ningún sondeo, porque los endpoints de salud no consultan las bases: la disponibilidad medida no cubre las rutas con estado. Las dos primeras corridas destaparon que el drenaje no terminaba (Kyverno con 1 réplica) y que faltaba capacidad N-1; ambas cosas están corregidas.

### 6. ¿Por qué el respaldo excluye `secrets` y `sealedsecrets`?

Porque tendrían dos dueños: Velero restauraría un `Secret` y el controlador de Sealed Secrets intentaría escribir el mismo objeto (`ErrUpdateFailed`). Los secretos vienen siempre de Git (cifrados) + la llave custodiada. Además, la llave (en `kube-system`) nunca entra al bucket: el Schedule solo incluye `sa-p5`.

### 7. ¿Por qué `data-restore` corre en la ola `-10`, antes de `sa-platform`?

Si `sa-platform` (ola 0) llegara primero, el chart crearía PVC **vacíos** y Velero no sobrescribe PVC existentes (`existingResourcePolicy: none`): el sistema arrancaría "sano" pero sin datos. Con `RESTORE_MODE: required`, si no hay respaldo el Job falla y la reconstrucción se detiene en vez de levantar bases vacías sin avisar ([`gitops/platform/data-restore/data-restore.yaml`](../gitops/platform/data-restore/data-restore.yaml)). Ese orden tiene una consecuencia: `managed-csi` es `WaitForFirstConsumer` y, por defecto, el data mover de Velero espera a que un Pod use el PVC antes de restaurarlo; como el Pod llega en la ola 0, se bloquearía. Por eso el node-agent usa `restorePVC.ignoreDelayBinding` (seguro porque el node pool no es zonal). Ensayado en el laboratorio local (`P9/evidencia/laboratorio-kind/`).

### 8. ¿Qué hace un respaldo inútil aunque esté `Completed`?

(a) Que se haya tomado del namespace vacío durante el propio bootstrap — por eso el Schedule llega en la ola 5 y `data-restore` solo elige respaldos anteriores al nacimiento del clúster; (b) que contenga datos ya corruptos (Velero no distingue un `DELETE` accidental de uno legítimo: la retención de 60 días permite volver a un punto anterior); (c) que su TTL venza antes de reconstruir (`1440h`).

### 9. ¿Qué no está cubierto (límites reconocidos)?

Desastre regional (todo en `chilecentral`), bases sin réplica, custodio único de la llave, dependencia de GitHub/GHCR disponibles durante la reconstrucción, y la cuota de 3 IP públicas. Detalle y plan en [`informe-dr.md`](informe-dr.md) §5-6.
