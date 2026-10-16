#!/usr/bin/env bash
# Prueba de restauración de datos verificada (rúbricas 2.3 y 2.6) contra el
# clúster vivo de P9. No destruye el clúster.
#
# Escenario (pérdida lógica de datos: borrado accidental en producción):
#   1. Inserta el marcador M1 en MySQL (sa_p5.p9_dr_marker), con hora del servidor.
#   2. Espera a que el Schedule sa-p9-schedule complete un Backup iniciado
#      DESPUÉS de M1 (respaldo programado, no manual).
#   3. Inserta M2, posterior al respaldo: es el dato que se espera perder (RPO).
#   4. DESASTRE: borra M1 y M2 de producción y comprueba que ya no están.
#   5. Restaura con Velero el PVC de MySQL de ese Backup en un namespace
#      aislado (sa-p5 -> p9-restore-check), levanta un MySQL temporal sobre el
#      volumen restaurado y consulta el contenido exacto.
#   6. Recupera: reinserta en producción las filas que el respaldo contenía y
#      las vuelve a consultar en producción.
#   7. Calcula RPO = T_desastre - escrito_utc del último dato recuperado.
#
# Por qué un namespace aislado: sa-platform tiene selfHeal. Si se borra el PVC
# de producción, ArgoCD lo recrea vacío antes de que Velero lo restaure (dos
# dueños del mismo objeto). La restauración del PVC "en su lugar" se prueba en
# la reconstrucción completa (job p9-data-restore, dr-rebuild-test.sh).
#
# Uso, desde la raíz del repositorio:
#   ./P9/scripts/dr-data-restore-test.sh
# Variables: BACKUP_WAIT_S (1500), P9_RESTORE_NS (p9-restore-check),
#            KEEP_RESTORE_NS=1 para conservar el namespace de verificación.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/p9-config.sh
source "$SCRIPT_DIR/lib/p9-config.sh"
# shellcheck source=lib/dr-tests.sh
source "$SCRIPT_DIR/lib/dr-tests.sh"

BACKUP_WAIT_S="${BACKUP_WAIT_S:-1500}"
RESTORE_NS="${P9_RESTORE_NS:-p9-restore-check}"
PVC="sa-platform-mysql-data"

require_cmd kubectl jq
use_p9_kubeconfig
evidence_log restauracion restauracion
trap 'die "Falló la línea $LINENO: $BASH_COMMAND"' ERR

cleanup() {
  if [[ "${KEEP_RESTORE_NS:-0}" != 1 ]]; then
    kubectl delete namespace "$RESTORE_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

stage "0. Prerrequisitos"
kubectl -n "$P9_VELERO_NS" wait --for=jsonpath='{.status.phase}'=Available backupstoragelocation/default --timeout=2m
kubectl -n "$P9_VELERO_NS" get schedule "$P9_SCHEDULE" -o jsonpath='{"Schedule "}{.metadata.name}{" cron="}{.spec.schedule}{" ttl="}{.spec.template.ttl}{" fase="}{.status.phase}{"\n"}'
kubectl -n "$P9_APP_NAMESPACE" wait --for=condition=Ready "pod/$P9_MYSQL_POD" --timeout=2m
! kubectl get namespace "$RESTORE_NS" >/dev/null 2>&1 ||
  die "El namespace $RESTORE_NS ya existe (corrida anterior). Bórrelo: kubectl delete namespace $RESTORE_NS"
run_id="p9dr-$(date -u +%Y%m%dT%H%M%SZ)"
log "Identificador de la corrida: $run_id"

stage "1. Dato identificable previo al respaldo (M1)"
marker_init
m1_at="$(marker_write "$run_id-M1" pre-backup)"
log "M1 id=$run_id-M1 escrito_utc=$m1_at"

stage "2. Respaldo PROGRAMADO posterior a M1"
backup="$(wait_backup_completed "$m1_at" "$BACKUP_WAIT_S")"
read -r b_start b_end < <(backup_times "$backup")
log "RESPALDO=$backup inicio=$b_start fin=$b_end"
kubectl -n "$P9_VELERO_NS" get backup "$backup" -o jsonpath='{"items_respaldados="}{.status.progress.itemsBackedUp}{" operaciones_data_mover="}{.status.backupItemOperationsCompleted}{"/"}{.status.backupItemOperationsAttempted}{" expira="}{.status.expiration}{"\n"}'

stage "3. Dato posterior al respaldo (M2, se espera perderlo)"
m2_at="$(marker_write "$run_id-M2" post-backup)"
log "M2 id=$run_id-M2 escrito_utc=$m2_at"

stage "4. DESASTRE: borrado de los datos en producción"
t_disaster="$(ts)"
mysql_q "DELETE FROM p9_dr_marker WHERE id LIKE '$run_id-%'" >/dev/null
left="$(mysql_q "SELECT COUNT(*) FROM p9_dr_marker WHERE id LIKE '$run_id-%'")"
[[ "$left" == 0 ]] || die "El borrado no eliminó los marcadores (quedan $left)."
log "DESASTRE=$t_disaster: marcadores de $run_id borrados de producción (filas restantes: $left)."

stage "5. Restauración con Velero en $RESTORE_NS"
restore="p9-restore-test-$(date -u +%Y%m%d%H%M%S)"
kubectl create -f - <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: $restore
  namespace: $P9_VELERO_NS
  labels:
    p9.dr/managed-by: dr-data-restore-test
spec:
  backupName: $backup
  includedNamespaces: ["$P9_APP_NAMESPACE"]
  namespaceMapping:
    $P9_APP_NAMESPACE: $RESTORE_NS
  includedResources: ["persistentvolumeclaims", "persistentvolumes"]
  labelSelector:
    matchLabels: {app: mysql}
  restorePVs: true
  existingResourcePolicy: none
EOF
t_restore_start="$(ts)"
phase=""
until [[ "$phase" =~ ^(Completed|Failed|PartiallyFailed|FailedValidation)$ ]]; do
  sleep 10
  new="$(kubectl -n "$P9_VELERO_NS" get restore "$restore" -o jsonpath='{.status.phase}')"
  [[ "$new" == "$phase" ]] || log "Restore $restore: ${new:-sin fase}"
  phase=$new
  (($(date -u +%s) - $(epoch "$t_restore_start") < 2700)) || die "Timeout esperando $restore."
done
[[ "$phase" == Completed ]] || {
  kubectl -n "$P9_VELERO_NS" get restore "$restore" -o jsonpath='{"errores="}{.status.errors}{" advertencias="}{.status.warnings}{"\n"}'
  die "La restauración $restore terminó en $phase."
}
kubectl -n "$RESTORE_NS" get pvc "$PVC" -o jsonpath='{"PVC restaurado "}{.metadata.name}{" fase="}{.status.phase}{" volumen="}{.spec.volumeName}{" restore="}{.metadata.labels.velero\.io/restore-name}{"\n"}'

# MySQL temporal sobre el volumen restaurado. --skip-grant-tables (implica
# --skip-networking en 8.0): se consulta por socket local sin necesitar ninguna
# contraseña ni copiar Secrets al namespace de verificación.
image="$(kubectl -n "$P9_APP_NAMESPACE" get statefulset sa-platform-mysql -o jsonpath='{.spec.template.spec.containers[0].image}')"
kubectl -n "$RESTORE_NS" apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: mysql-verify
spec:
  securityContext: {fsGroup: 999}
  containers:
    - name: mysql
      image: $image
      args: ["--skip-grant-tables", "--skip-networking"]
      env: [{name: MYSQL_ALLOW_EMPTY_PASSWORD, value: "yes"}]
      readinessProbe:
        exec: {command: ["mysqladmin", "--socket=/var/run/mysqld/mysqld.sock", "ping"]}
        periodSeconds: 5
      volumeMounts: [{name: data, mountPath: /var/lib/mysql}]
  volumes:
    - name: data
      persistentVolumeClaim: {claimName: $PVC}
EOF
kubectl -n "$RESTORE_NS" wait --for=condition=Ready pod/mysql-verify --timeout=10m
t_restore_end="$(ts)"

restored="$(kubectl -n "$RESTORE_NS" exec mysql-verify -- mysql -uroot -N -B "$P9_MARKER_DB" -e \
  "SELECT id, fase, DATE_FORMAT(escrito_utc, '%Y-%m-%dT%H:%i:%s.%fZ') FROM p9_dr_marker WHERE id LIKE '$run_id-%' ORDER BY escrito_utc")"
log "Contenido del volumen restaurado (id, fase, escrito_utc):"
printf '%s\n' "${restored:-<vacío>}" | sed 's/^/    /'
cron_last="$(kubectl -n "$RESTORE_NS" exec mysql-verify -- mysql -uroot -N -B "$P9_MARKER_DB" -e \
  "SELECT COUNT(*), MAX(execution_time) FROM cron_logs" 2>/dev/null || echo 'n/d')"
log "cron_logs restaurado (filas, último execution_time en hora local del cron): $cron_last"

grep -q "^$run_id-M1"$'\t'"pre-backup" <<<"$restored" ||
  die "VERIFICACIÓN FALLIDA: M1 (escrito antes del respaldo) NO está en el volumen restaurado."
if grep -q "^$run_id-M2" <<<"$restored"; then
  warn "M2 apareció en el volumen restaurado: el respaldo es posterior a M2 (revise marcas de tiempo)."
else
  log "M2 no está en el respaldo: pérdida esperada (escrito después de $b_start)."
fi

stage "6. Recuperación en producción"
while IFS=$'\t' read -r id fase at; do
  [[ -n "$id" ]] || continue
  mysql_q "INSERT INTO p9_dr_marker (id, fase, escrito_utc) VALUES ('$id', '$fase', STR_TO_DATE('${at%Z}', '%Y-%m-%dT%H:%i:%s.%f'))" >/dev/null
done <<<"$restored"
prod="$(mysql_q "SELECT id, fase FROM p9_dr_marker WHERE id LIKE '$run_id-%' ORDER BY escrito_utc")"
log "Producción tras la recuperación:"
printf '%s\n' "$prod" | sed 's/^/    /'
grep -q "^$run_id-M1" <<<"$prod" || die "M1 no quedó reinsertado en producción."

stage "7. Resultado"
last_recovered="$(awk -F'\t' 'END {print $3}' <<<"$restored")"
rpo=$(($(epoch "$t_disaster") - $(epoch "$last_recovered")))
log "RESTAURACION_OK run=$run_id backup=$backup restore=$restore"
log "M1_escrito=$m1_at BACKUP_inicio=$b_start BACKUP_fin=$b_end M2_escrito=$m2_at DESASTRE=$t_disaster"
log "RESTAURACION_inicio=$t_restore_start RESTAURACION_fin=$t_restore_end duracion_restauracion_s=$(($(epoch "$t_restore_end") - $(epoch "$t_restore_start")))"
log "RPO_MEDIDO_S=$rpo (DESASTRE - escrito_utc del último dato recuperado = $t_disaster - $last_recovered). La duración de la restauración NO es el RPO."
