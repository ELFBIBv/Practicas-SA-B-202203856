# Decisiones pendientes — Práctica 9

Documento vivo. Cada entrada se cierra cuando: (a) se decide y se justifica, o 
(b) se ejecuta y se registra el resultado. Las decisiones cerradas no se borran: 
se mueven a "Decisiones tomadas" para que el informe de DR pueda citarlas.

Última actualización: 2026-09-29

---

## 1. Decisiones tomadas

### 1.1 Backend remoto de Terraform
**Decisión:** Opción (b) — script con Azure CLI que crea el backend antes de 
`terraform init`. No se usa etapa previa con tfstate local.
**Justificación:** una etapa previa deja un tfstate local en el momento más 
delicado; si falla entre `apply` y `-migrate-state`, ese tfstate queda huérfano 
en una máquina. Un `destroy` en la etapa previa borraría el estado de todo.
**Fuente:** `docs/diseno-bootstrap-terraform.md`.

### 1.2 Autenticación contra el backend
**Decisión:** intentar Entra ID (`use_azuread_auth=true`) primero; caer a 
account key en memoria si la identidad no tiene rol de datos.
**Justificación:** la cuenta es `Owner` (verificado 2026-09-24), así que se 
puede asignar el rol de datos y evitar la key. Si por alguna razón se corre 
desde otra identidad sin permisos, el fallback mantiene el bootstrap funcional.
**Fuente:** `docs/diseno-bootstrap-terraform.md` + verificación Azure.

### 1.3 Continuidad de secretos
**Decisión:** mantener Sealed Secrets; custodia de la llave en Azure Key Vault 
dedicado (`kv-sa-p9-202203856`); reinyección ANTES de instalar ArgoCD; rotación 
desactivada (`keyrenewperiod: "0"`).
**Justificación:** prueba directa de la rúbrica 2.4 (mismo ciphertext se 
descifra), migración casi nula desde P8, menos piezas en el camino crítico que 
ESO.
**Fuente:** `docs/diseno-secretos-dr.md` §1.

### 1.4 Terraform en dos etapas
**Decisión:** `01-cluster` (AKS) y `02-platform` (ArgoCD + siembra), cada una 
con su estado.
**Justificación:** una sola raíz configura los providers `kubernetes`/`helm` 
con valores que aún no existen; en la reconstrucción intenta conectarse con 
credenciales viejas y falla. Las dos etapas aíslan ese problema.
**Fuente:** `docs/diseno-dia-cero.md` §Recomendación.

### 1.5 Ruta A vs Ruta B para la llave de Sealed Secrets
**Decisión:** Ruta A (respaldar la llave viva de P8).
**Estado:** COMPLETADA. Llave respaldada en Key Vault el 2026-09-24 23:37 UTC.
cert-sha256=7DD46ABC19BE6499, 1 llave, origin=aks-sa-p8.
**Fuente:** `docs/diseno-secretos-dr.md` §3.2.

---

## 2. Decisiones abiertas

### 2.1 Dónde vive el Key Vault — CERRADA
**Decisión:** Terraform, en la etapa `00-persistent` (capa persistente).
**Ejecutado:** 2026-09-24. Vault `kv-sa-p9-202203856` en `rg-p9-tfstate` con 
RBAC, purge protection 90 días y prevent_destroy.
**Verificado:** rbac=true, purge=true, retención=90. Roles: Secrets Officer 
(custodio) y Secrets User (bootstrap).
**Fuente:** `docs/diseno-velero.md` §2.2.

### 2.2 Los 2 SealedSecrets faltantes — CERRADA
**Problema:** `ghcr-secret` (en `sa-p5` y en `kyverno`) y 
`sa-platform-nats-auth` se sellaron pero nunca se publicaron en el repo GitOps.
**Acción:** sellarlos desde P8 arrancado y publicarlos en 
`P9/gitops/platform-secrets/`.
**Bloqueante:** requiere la llave viva de P8 → depende de completar 1.5.
3 ciphertexts sellados y publicados en `P9/gitops/platform-secrets/`.

### 2.3 Ubicación del workflow `promote-to-gitops` de P8 — CERRADA
**Decisión:** neutralizado/filtrado. Verificado sin conflicto con P9.

### 2.4 Validación offline de la llave (V-A4) — CERRADA (re-verificar)
**Pregunta:** ¿el script `verify-sealed-secrets-offline.sh` se implementó? 
**Estado:** ejecutado 2026-09-25 con los 6 SealedSecret en `OK`, `rc=0` 
(`P9/evidencia/secretos/v-a4-2026-09-25.txt`). Los dos `ghcr-secret` se 
re-sellaron después en el repo GitOps: repetir V-A4 antes de la prueba.

### 2.5 RTO/RPO declarados — CERRADA
**RTO declarado:** 45 min.
**RPO declarado:** 15 min.
**Justificación:** 20-25 min AKS + 10 min ArgoCD + 10 min workloads + margen; 
el peor caso de RPO es "justo antes del próximo backup" = 15 min.
**Se contrastarán contra los medidos durante T0.**

### 2.6 Modo de restauración de Velero (D1) — CERRADA
**Decisión:** CSI snapshot con data mover.

### 2.7 Imagen del Job de restauración (D2) — CERRADA
**Decisión:** `alpine/k8s` fijada por digest. Migrar a imagen propia firmada 
solo si sobra tiempo antes de T0.

### 2.8 Cambio de `RESTORE_MODE` (D5) — CERRADA
**Responsable:** el autor.
**Momento:** después del primer backup exitoso y antes de T0.
**Acción:** commit fechado en el repo GitOps cambiando `skip-if-empty` → 
`required`.
**Estado:** ejecutado en el repo GitOps (PR #17, 2026-09-25). La fuente 
`P9/gitops/platform/data-restore/data-restore.yaml` se sincronizó el 2026-09-29.
---

## 3. Bloqueantes externos (requieren acción fuera del código)

### 3.1 Publicar `P9/gitops/apps/` al repo GitOps
**Qué falta:** la Application raíz vive en `P9/gitops/apps/`, pero el repo 
GitOps remoto aún no tiene esa ruta. Sin publicarla, la raíz nunca queda 
`Healthy`.
**Herramienta preparada:** `publish-gitops.sh <clon>` prepara el diff.
**Acción:** push + PR (requiere autorización explícita).
**Adicional:** en ese mismo PR hay que borrar `argocd/application.yaml` de P8 
que usa el mismo nombre `sa-platform` y colisiona.

### 3.2 Arrancar `aks-sa-p8` para respaldar la llave
**Estado:** `Stopped`, existe (verificado 2026-09-24).
**Acción:** `az aks start` → respaldar llave → `az aks stop`.
**Prerrequisito:** Key Vault creado (bloqueado por 2.1).
**Costo:** consume crédito de Azure for Students mientras esté arrancado.

### 3.3 PAT de GHCR
**Problema:** publicar `ghcr-secret` sellado en un repo público está permitido, 
pero si la llave se filtra, el PAT queda expuesto.
**Acción:** usar PAT con scope mínimo (`read:packages`), expiración corta y 
rotación periódica. Verificar que el PAT actual en P8 cumple.

---

## 4. Tensiones con CLAUDE.md (excepciones documentadas)

Estas son decisiones que contradicen reglas del CLAUDE.md y deben quedar 
explícitas para que un evaluador no las lea como incumplimiento.

### 4.1 El namespace `sa-p5` no se renombra
**Regla CLAUDE.md:** "actualizar namespaces heredados para P9".
**Excepción:** con `scope: strict` de Sealed Secrets, el ciphertext está 
atado al nombre y namespace originales. Renombrar rompe la continuidad.
**Documentar en:** README de entrega, sección "excepciones".

### 4.2 `kubectl apply` imperativo en el script de restauración
**Regla CLAUDE.md:** "no aplicar manifiestos sueltos manualmente".
**Excepción:** el apply es automático, dentro del punto de entrada, ordenado 
por `depends_on`. No es un paso manual.
**Documentar en:** diagrama del bootstrap, marcar como "automático, invocado 
por bootstrap.sh".

### 4.3 La custodia inicial es una acción humana
**Regla CLAUDE.md:** "bootstrap sin pasos manuales intermedios".
**Excepción:** la custodia de la llave en Key Vault ocurre ANTES del desastre, 
no durante la reconstrucción. Es un prerrequisito, no un paso del bootstrap.
**Documentar en:** informe de DR, sección "puntos únicos de fallo" y "acciones 
previas".

### 4.4 El certificado de administrador de AKS queda en el tfstate
**Regla CLAUDE.md:** "no guardar material sensible en el repositorio".
**Excepción:** el tfstate es remoto, privado y con locking. No está en el 
repositorio. Es material sensible pero fuera del alcance de la regla.
**Documentar en:** `docs/terraform-dia-cero.md`, sección "Qué falta".

### 4.5 Los discos de PVC mueren con el clúster
**Regla CLAUDE.md:** "los respaldos deben estar fuera del clúster".
**Excepción:** los discos de PVC son efímeros por diseño. Lo que persiste es 
el respaldo de Velero, que va a la capa persistente.
**Documentar en:** informe de DR, sección "puntos únicos de fallo".

### 4.6 Ruta B (si se usara): re-sellado una vez
**Regla CLAUDE.md:** "no re-sellar como estrategia de continuidad".
**Excepción:** solo aplica en génesis (antes de la prueba). La continuidad se 
demuestra entre generación 1 y 2 sin re-sellar.
**Estado:** no aplica si se cierra 1.5 como Ruta A.


### 4.7 `retry.limit: -1` en lugar de un número finito
**Regla CLAUDE.md:** "fallo temprano, códigos de salida correctos".
**Excepción:** con `retry.limit` finito, ArgoCD deja de reintentar la misma 
revisión cuando se agotan los intentos, incluso con `selfHeal`. Eso rompe el 
requisito de "cero pasos manuales" porque obliga a un `Sync` manual.
**Mitigación:** `limit: -1` + timeout del lado de `bootstrap.sh`. El script 
falla temprano; ArgoCD reintenta indefinidamente hasta que el script se rinde.
**Fuente:** `docs/diseno-sync-waves.md`, sección "Lo que cambia".

### 4.8 Velero instalado por Terraform, no por ArgoCD
**Regla del enunciado 3.2:** "Terraform instala ArgoCD, y a partir de ahí el patrón 
app-of-apps levanta el resto del sistema."
**Excepción:** Velero se instala vía Terraform porque el `azurerm_federated_identity_credential` 
necesita el `oidc_issuer_url` del clúster, que solo existe tras `01-cluster`. ArgoCD 
llegaría tarde a la cadena de Workload Identity.
**Mitigación documental:** el diagrama del bootstrap marca Velero como 
"Terraform → clúster" y no como "ArgoCD → aplicación". El README lo explica.
**Fuente:** `docs/diseno-velero.md` §2.1 y §4.

---

## 5. Prerrequisitos humanos antes de la prueba cronometrada

Cosas que deben estar listas ANTES de T0 (momento de destrucción).
Última actualización: 2026-09-29.

### Infraestructura persistente
- [x] Backend remoto de Terraform creado y verificado (rbac, purge, retención).
- [x] Key Vault `kv-sa-p9-202203856` creado con RBAC, purge protection 90d, 
      prevent_destroy.
- [x] Storage account de Velero `stp9veloc01f715c2e19` + container 
      `velero-backups` creados.
- [x] UAMI `id-sa-p9-velero` + role assignment Storage Blob Data Contributor.
- [x] `bootstrap.sh` con `az provider register --namespace Microsoft.KeyVault` 
      agregado (mitigación del hallazgo 6.2; `lib/tfstate-backend.sh`).

### Diseños y código
- [x] Los 4 diseños convertidos en código real y validados estáticamente.
- [x] `bootstrap.sh plan` corrido contra Azure sin errores.
- [x] `terraform validate` de las tres etapas pasa.
- [x] `shellcheck -x` de todos los scripts pasa.
- [x] `audit-repo.sh` pasa.

### Secretos (rúbrica 2.4)
- [X] Llave de Sealed Secrets respaldada en Key Vault 
      (secret `sealed-secrets-keyring` verificable con `az keyvault secret list`).
- [X] Los 2 SealedSecrets faltantes sellados y publicados:
      - `ghcr-secret` en `sa-p5`
      - `ghcr-secret` en `kyverno` (scope strict = ciphertext distinto)
      - `sa-platform-nats-auth` en `sa-p5`
- [X] `pub-cert.pem` versionado en `P9/gitops/sealed-secrets/`.
- [ ] PAT de GHCR verificado con scope mínimo (`read:packages`).

### Velero (rúbricas 2.3 y 2.6)
- [x] Diseño de Velero confirmado como CSI snapshot + data mover.
- [x] Storage account dedicado para Velero (fuera del clúster).
- [x] Schedule con cron (`*/15 * * * *`), TTL (`1440h`; era `720h` hasta 2026-10-15) y exclusiones 
      (`kube-system`, `secrets`, `sealedsecrets.bitnami.com`).
- [ ] Primer backup real en estado `Completed` verificado.
- [x] `RESTORE_MODE` cambiado a `required` en el repo GitOps (2.8, PR #17).

### GitOps y sync waves
- [x] Lua de health de `Application` reemplazado (versión que mira operación 
      en curso).
- [x] `Delete=false` en la Application de Sealed Secrets.
- [x] `retry.limit: -1` en todas las Applications.
- [x] PVC y StatefulSet en la misma ola.
- [x] `P9/gitops/apps/` publicado al repo GitOps remoto (verificado 2026-09-29).
- [x] `argocd/application.yaml` de P8 borrado del repo GitOps (404 el 2026-09-29).
- [x] Workflow `promote-to-gitops` de P8 neutralizado o filtrado.
- [x] V-A4 ejecutado (con bugs de forma, ciphertexts reales verificados).

### Objetivos y prueba
- [x] RTO/RPO declarados y justificados (2.5) — `docs/informe-dr.md` §1.
- [X] `aks-sa-p8` detenido de nuevo (después del respaldo de la llave).
- [x] Runbook de recuperación redactado (rúbrica 1.1): `docs/runbook-recuperacion.md`.
- [x] Diagrama del bootstrap (rúbrica 1.3): `docs/diagrama-bootstrap.md`.
- [ ] Video demostrativo 5-8 min con minutaje en README.
---

## 5.1 Auditoría del 2026-09-29 (hallazgos y correcciones en código)

Todas **implementadas sin ejecutar** contra Azure; se validan con `bootstrap.sh plan` y la prueba cronometrada.

1. **VolumeSnapshotClass inexistente.** El diseño asumía una clase `managed-csi`; AKS crea `csi-azuredisk-vsc` y sin la etiqueta `velero.io/csi-volumesnapshot-class=true` el backup CSI de los PVC falla. Terraform (`modules/velero`, `extraObjects`) crea `p9-velero-azuredisk` etiquetada.
2. **IP del gateway no reconstruible.** El repo GitOps apuntaba `azure-pip-name` a la IP de egress autogenerada por AKS (nombre GUID distinto por clúster). Ahora `01-cluster` crea `pip-sa-p9-gateway` (salida de AKS + frontend del Service) con identidad user-assigned y `Network Contributor` solo sobre la IP. **Cambia la identidad del clúster existente** (SystemAssigned → UserAssigned): revisar el plan.
3. **Deriva P9 ↔ repo GitOps.** 8 archivos corregidos directo en el repo GitOps (Kyverno `ignoreDifferences`, tags `c46f099`, `ghcr-secret` re-sellados, `RESTORE_MODE`, anotaciones del Service) se trajeron a `P9/`.
4. **Object IDs implícitos.** `00-persistent` exigía `custodian_object_id`/`bootstrap_object_id` sin default y sin tfvars: el plan fallaba en una máquina limpia. `bootstrap.sh` los deriva de la sesión `az` y conserva al custodio existente.
5. **Resiliencia (2.5).** No había anti-afinidad ni spread. Se agregó `topologySpreadConstraints` (DoNotSchedule + `nodeTaintsPolicy: Honor`) y anti-afinidad preferida en los 5 servicios, y timeouts explícitos en las probes (liveness más tolerante que readiness). El gateway conserva `/ready` en liveness: `/health` devuelve 500 a propósito en el fallo inducido de P8.
6. **Pruebas de DR.** Nuevos `dr-data-restore-test.sh`, `dr-node-drain-test.sh`, `dr-rebuild-test.sh` y workflow `.github/workflows/p9-validate.yml`.
7. **Repositorio de código privado:** incumple 4.1 hasta hacerlo público.

### Seguimiento 2026-10-15/16 (sin Azure)

- **TTL del Schedule 720h → 1440h.** Con 30 días, los respaldos de la prueba de octubre vencerían antes de la calificación (26-11) y el bootstrap de ese día fallaría con `RESTORE_MODE=required`. Los respaldos existentes del 2026-09-25 (`Completed` a las 07:00 y 07:15 UTC) **vencen el 2026-10-25**: la primera reconstrucción debe hacerse antes.
- **Confirmación con datos reales:** el backup `sa-p9-schedule-20260925064541` quedó `PartiallyFailed` exactamente por la `VolumeSnapshotClass` sin etiqueta (hallazgo 1); los siguientes salieron `Completed` porque la clase se creó a mano en el clúster, no en el código. El historial del repo GitOps (PR #12 y posteriores) muestra que compartir la IP de salida con el Service funcionó (hallazgo 2).
- **Herramientas locales:** `yq` 4.54.1, `shellcheck` 0.11.0, `kubeconform` 0.8.0, `actionlint` 1.7.12 y `kind` 0.33.0 instaladas en `~/.local/bin` con checksum verificado (salvo shellcheck, que no publica checksum).
- **Validaciones nuevas:** `kubeconform` (108 recursos del chart, GitOps y Kyverno, más los `Restore`, el Pod de verificación y la `VolumeSnapshotClass` que crean scripts y Terraform), `actionlint`, ensayo de `publish-gitops.sh` (V-S3 OK, 13 archivos a publicar) y `scripts/tests/dr-tests-lib.test.sh` (9 pruebas con `kubectl` simulado). Las tres se agregaron a `.github/workflows/p9-validate.yml`.
- **Prueba de scheduling en `kind`:** primero bloqueada (kernel 6.12.69 sin `veth`); tras volver al 6.17 se hizo el laboratorio completo del 2026-10-16.

### Laboratorio local en kind (2026-10-16)

Detalle, método y logs: `P9/evidencia/laboratorio-kind/README.md`. **No sustituye la evidencia en AKS.** Encontró tres defectos que habrían fallado en Azure, todos corregidos en código:

1. **`preStop` ausente:** al drenar, nginx moría antes de salir de los endpoints (1 conexión rechazada en 100 sondeos). Se agregó `lifecycle.preStop.sleep` (5 s) a los 5 servicios; con eso, 100 % en 470 y 414 sondeos drenando cada nodo.
2. **`backup_times` sin salto de línea:** `read` devolvía 1 bajo `set -e` y abortaba `dr-data-restore-test.sh` y `dr-rebuild-test.sh` justo después de un backup `Completed`. Corregido, con prueba de regresión en `scripts/tests/dr-tests-lib.test.sh`.
3. **Abrazo mortal con `WaitForFirstConsumer` (el más grave):** el data mover de Velero espera a que un Pod consuma el PVC restaurado; el Job `p9-data-restore` (ola -10) espera el `Restore` antes de que exista el consumidor (ola 0). Velero se rinde a los 30 min y el bootstrap falla. Corregido con `restorePVC.ignoreDelayBinding` en el node-agent (`modules/velero`), verificado contra el código de Velero v1.18.2. Seguro mientras el node pool no sea zonal (`availability_zones = null`).

Verificado además en el laboratorio: reparto entre nodos (3/2 y 1/1), guarda de réplicas concentradas, aborto automático del canario de P8, custodia y restauración de la llave con los scripts reales (el controlador nuevo usó la llave custodiada sin generar otra y descifró el ciphertext del clúster destruido), Job `p9-data-restore` real con `RESTORE_MODE: required` y adopción de los PVC restaurados por el manifiesto del chart.

## 6. Notas de tiempo y cupo (uso interno, no va al entregable)

- Reset semanal de cupo: 1:00 PM.
- Reset de sesión de 5 horas: 4:00 PM.
- Estado al 2026-09-24 antes del reset: 53% semanal consumido.
- Los tres prompts de Opus (1, 2, 3) deben cerrarse antes del reset.
- Prompt 4 (PDB/drain) se integra al prompt de Sonnet post-reset.

### 6.1 Punto único de fallo: rol de datos del backend
**Descubierto durante el primer bootstrap (2026-09-24 22:53 UTC).**
Ser Owner en la suscripción no otorga permisos de plano de datos sobre blobs.
El backend requiere el rol "Storage Blob Data Contributor" sobre el storage 
account del tfstate, o caer al fallback con account key.
**Mitigación aplicada:** autoasignación del rol (posible porque Owner).
**Riesgo residual:** si el operador no es Owner, el bootstrap falla y hay que 
caer al fallback con account key (menos seguro).
**Documentado en:** runbook, paso "Autorización del backend".

### 6.2 Punto de fricción: proveedor Microsoft.KeyVault no registrado
Al aplicar 00-persistent por primera vez, el 409 MissingSubscriptionRegistration 
detuvo la creación del vault. Los 4 recursos anteriores (storage, container, UAMI, 
role assignment) sí se crearon; el reintento tras `az provider register` fue 
idempotente y completó solo los 3 faltantes.
**Mitigación en código:** agregar un `az provider register --namespace Microsoft.KeyVault` 
al bootstrap.sh, junto al que ya existe para Microsoft.Storage. Pendiente.

### 6.3 Bug en verify-sealed-secrets-offline.sh
**Detectado:** 2026-09-24 23:49 UTC.
**Síntomas:**
1. Iteración con producto cartesiano namespace/nombre: genera combinaciones 
   inválidas como `kyverno/sa-platform-mysql` que no existen en el conjunto 
   de SealedSecrets. Genera falsos `FALLA`.
2. Repetición masiva: los mismos 6 ciphertexts aparecen ~12 veces en la salida.
3. Exit code incorrecto: calcula `rc=1` pero termina con `exit 0`.

**Impacto en la verificación:** los ciphertexts reales SÍ se descifran 
correctamente (los `OK` de `sa-p5/*` y `kyverno/ghcr-secret`). El bug es 
de forma, no de fondo. La continuidad criptográfica está probada.
**Fix:** aplicado (iteración por documento + `sort -u`, `exit $rc`); la 
evidencia `v-a4-2026-09-25.txt` ya es la corrida corregida.
**Evidencia parcial:** `P9/evidencia/secretos/v-a4-parcial-2026-09-24.txt`. 
Cuando se arregle, re-ejecutar y reemplazar.

### 6.4 Deuda técnica: charts de Bitnami en dependencias
**Contexto:** Broadcom movió las imágenes gratuitas de Bitnami a un repositorio 
"legacy" sin actualizaciones ni parches de seguridad (agosto/septiembre 2025). 
Los charts públicos de Bitnami ya no se mantienen activamente.
**Impacto en P9:** los subcharts `mysql` y `mongodb` de `sa-platform/Chart.yaml` 
usan charts de Bitnami. Funcionan hoy (los .tgz están construidos localmente), 
pero no recibirán parches de seguridad.
**Mitigación futura:** migrar los subcharts a alternativas mantenidas:
- `groundhog2k/helm-charts` (basados en imágenes oficiales de Docker Hub)[reference:4]
- `Chainguard Helm Charts` (40+ charts propios)[reference:5]
- Charts propios usando imágenes oficiales
**Estado:** no bloquea la entrega. Se documenta como riesgo de mantenibilidad.
**Nota importante:** Sealed Secrets NO está afectado — su chart viene de 
`bitnami-labs`, mantenido por el equipo de Sealed Secrets.