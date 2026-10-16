#!/usr/bin/env bash
# Utilidades de las pruebas de DR (restauración, pérdida de nodo y
# reconstrucción). Se carga con `source` después de lib/common.sh y
# lib/p9-config.sh.
#
# Marcador de datos: tabla sa_p5.p9_dr_marker en MySQL. La marca de tiempo la
# pone el servidor (UTC_TIMESTAMP(3)), no la laptop del operador, para que el
# RPO se calcule con el reloj de la base que se respalda.
# Las credenciales nunca pasan por la línea de comandos ni por el log: el
# cliente mysql lee MYSQL_ROOT_PASSWORD del entorno del propio contenedor.

[[ -n "${_P9_DR_TESTS_SH:-}" ]] && return 0
_P9_DR_TESTS_SH=1

P9_MYSQL_POD="${P9_MYSQL_POD:-sa-platform-mysql-0}"
P9_MARKER_DB="${P9_MARKER_DB:-sa_p5}"
P9_SCHEDULE="${P9_SCHEDULE:-sa-p9-schedule}"
P9_VELERO_NS="${P9_VELERO_NS:-velero}"

# evidence_log <subdir> <prefijo>: duplica stdout/stderr del script a
# P9/evidencia/<subdir>/<prefijo>-<UTC>.log. El archivo se versiona como
# evidencia, así que se redactan los GUID (suscripción, tenant, client-id de
# identidades) antes de escribirlo; la terminal los sigue mostrando completos.
evidence_log() {
  local dir="$P9_DIR/evidencia/$1" file
  mkdir -p "$dir"
  file="$dir/$2-$(date -u +%Y%m%dT%H%M%SZ).log"
  exec > >(tee >(sed -u -E 's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/<guid-redactado>/g' >>"$file")) 2>&1
  log "Evidencia: ${file#"$REPO_ROOT"/} (zona horaria: UTC; contexto: $(kubectl config current-context 2>/dev/null || echo n/d))."
}

# use_p9_kubeconfig: usa el kubeconfig propio de P9 si existe; si no, el
# KUBECONFIG del entorno. Falla si no hay API alcanzable.
use_p9_kubeconfig() {
  if [[ -z "${KUBECONFIG:-}" && -f "$P9_KUBECONFIG" ]]; then
    export KUBECONFIG="$P9_KUBECONFIG"
  fi
  kubectl version --request-timeout=15s >/dev/null 2>&1 ||
    die "No hay acceso al clúster (KUBECONFIG=${KUBECONFIG:-~/.kube/config}). Ejecute antes: ./P9/scripts/bootstrap.sh verify"
}

# mysql_q <sql>: ejecuta SQL en la base de marcadores del Pod de MySQL de
# producción y devuelve filas separadas por tabulador, sin encabezados.
mysql_q() {
  # shellcheck disable=SC2016 # se expande dentro del contenedor, a propósito.
  kubectl -n "$P9_APP_NAMESPACE" exec "$P9_MYSQL_POD" -c mysql -- \
    sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot -N -B "$1" -e "$2"' _ "$P9_MARKER_DB" "$1"
}

marker_init() {
  mysql_q "CREATE TABLE IF NOT EXISTS p9_dr_marker (
    id VARCHAR(64) PRIMARY KEY,
    fase VARCHAR(32) NOT NULL,
    escrito_utc DATETIME(3) NOT NULL)"
}

# marker_write <id> <fase>: inserta y devuelve la marca de tiempo del servidor (ISO 8601 UTC).
marker_write() {
  mysql_q "INSERT INTO p9_dr_marker (id, fase, escrito_utc) VALUES ('$1', '$2', UTC_TIMESTAMP(3))" >/dev/null
  mysql_q "SELECT DATE_FORMAT(escrito_utc, '%Y-%m-%dT%H:%i:%s.%fZ') FROM p9_dr_marker WHERE id='$1'" | sed -E 's/([0-9]{3})[0-9]{3}Z$/\1Z/'
}

# epoch <iso8601>: segundos desde epoch (acepta milisegundos).
epoch() { date -u -d "$1" +%s; }

# wait_backup_completed <desde_iso> <timeout_s>: espera el primer Backup del
# Schedule cuyo startTimestamp sea posterior a <desde_iso> y devuelve su
# nombre cuando está Completed. Falla ante cualquier fase terminal distinta.
wait_backup_completed() {
  local since=$1 timeout=$2 deadline name phase last=""
  deadline=$((SECONDS + timeout))
  log "Esperando un Backup Completed de $P9_SCHEDULE iniciado después de $since (hasta ${timeout}s; cron del Schedule: $(kubectl -n "$P9_VELERO_NS" get schedule "$P9_SCHEDULE" -o jsonpath='{.spec.schedule}'))."
  while :; do
    read -r name phase < <(kubectl -n "$P9_VELERO_NS" get backups -l "velero.io/schedule-name=$P9_SCHEDULE" -o json |
      jq -r --arg since "$since" '[.items[] | select(.status.startTimestamp != null and .status.startTimestamp > ($since | sub("\\.[0-9]+Z$"; "Z")))]
        | sort_by(.status.startTimestamp) | first // empty | "\(.metadata.name) \(.status.phase // "New")"') || true
    if [[ "${name:-}/${phase:-}" != "$last" ]]; then
      log "Backup: ${name:-todavía ninguno} ${phase:-}"
      last="${name:-}/${phase:-}"
    fi
    case "${phase:-}" in
      Completed) printf '%s\n' "$name"; return 0 ;;
      Failed | PartiallyFailed | FailedValidation)
        kubectl -n "$P9_VELERO_NS" get backup "$name" -o jsonpath='{"errores="}{.status.errors}{" advertencias="}{.status.warnings}{" razon="}{.status.failureReason}{"\n"}' >&2 || true
        die "El Backup $name terminó en $phase." ;;
    esac
    ((SECONDS < deadline)) || die "Ningún Backup de $P9_SCHEDULE llegó a Completed en ${timeout}s."
    sleep 15
  done
}

# backup_times <nombre>: "<inicio> <fin>" del Backup, con salto de línea final:
# jsonpath no lo agrega y `read` devuelve 1 al llegar a EOF sin él, lo que con
# `set -e` abortaba la prueba justo después de un backup Completed
# (encontrado en la prueba local en kind del 2026-10-16).
backup_times() {
  kubectl -n "$P9_VELERO_NS" get backup "$1" -o jsonpath='{.status.startTimestamp} {.status.completionTimestamp}{"\n"}'
}

# gateway_ip: IP pública del LoadBalancer del gateway.
gateway_ip() {
  kubectl -n "$P9_APP_NAMESPACE" get service "$P9_GATEWAY" -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
}
