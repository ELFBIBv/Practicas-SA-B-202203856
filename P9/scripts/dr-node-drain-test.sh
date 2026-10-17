#!/usr/bin/env bash
# Prueba de pérdida de nodo (rúbrica 2.5): drena un nodo respetando los
# PodDisruptionBudget mientras un sondeo continuo consulta el servicio por su
# IP pública, y registra disponibilidad, reprogramación y recuperación.
#
# Uso, desde la raíz del repositorio:
#   ./P9/scripts/dr-node-drain-test.sh [nodo]
# Sin nodo, elige el que aloja más réplicas del gateway (el peor caso para el
# servicio expuesto).
#
# Drenaje: kubectl drain --ignore-daemonsets --delete-emptydir-data
#   --timeout=$DRAIN_TIMEOUT. SIN --force ni --disable-eviction: el desalojo
#   pasa por la Eviction API y respeta los PDB (anularlos invalida la prueba).
#   --ignore-daemonsets: node-agent de Velero, CSI y red son por nodo.
#   --delete-emptydir-data: los Pods de la app montan /tmp como emptyDir.
# Al terminar (o si algo falla) el nodo se vuelve a habilitar con uncordon.
#
# Variables: PROBE_PATHS ("/ready /api/catalog/health /api/orders/health"),
#            PROBE_INTERVAL_S (1), SETTLE_S (60), DRAIN_TIMEOUT (15m),
#            MIN_AVAILABILITY (99.0, porcentaje mínimo por ruta).
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/p9-config.sh
source "$SCRIPT_DIR/lib/p9-config.sh"
# shellcheck source=lib/dr-tests.sh
source "$SCRIPT_DIR/lib/dr-tests.sh"

PROBE_PATHS="${PROBE_PATHS:-/ready /api/catalog/health /api/orders/health}"
PROBE_INTERVAL_S="${PROBE_INTERVAL_S:-1}"
SETTLE_S="${SETTLE_S:-60}"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-15m}"
MIN_AVAILABILITY="${MIN_AVAILABILITY:-99.0}"
NS=$P9_APP_NAMESPACE

require_cmd kubectl curl jq awk
use_p9_kubeconfig
evidence_log nodo drenaje
trap 'die "Falló la línea $LINENO: $BASH_COMMAND"' ERR

placement() {
  kubectl -n "$NS" get pods --field-selector=status.phase=Running \
    -o custom-columns='POD:.metadata.name,NODO:.spec.nodeName,LISTO:.status.conditions[?(@.type=="Ready")].status' --sort-by=.spec.nodeName
}

stage "0. Prerrequisitos y ubicación de réplicas ANTES del drenaje"
ready_nodes="$(kubectl get nodes -o json | jq -r '[.items[] | select(.spec.unschedulable != true) | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length')"
((ready_nodes >= 2)) || die "Hay $ready_nodes nodo(s) Ready y programables; la prueba requiere >= 2."
kubectl get nodes -o wide
kubectl -n "$NS" get pdb
placement

# Cada workload con >= 2 réplicas debe tener Pods en >= 2 nodos: si no, el
# drenaje probaría la suerte del scheduler, no el diseño.
colocated="$(kubectl -n "$NS" get pods -o json | jq -r '
  [.items[] | select(.status.phase == "Running") | {app: .metadata.labels["app.kubernetes.io/name"], node: .spec.nodeName}]
  | map(select(.app != null)) | group_by(.app)[]
  | select(length >= 2 and ([.[].node] | unique | length) < 2) | .[0].app')"
[[ -z "$colocated" ]] || die "Réplicas concentradas en un solo nodo: $(tr '\n' ' ' <<<"$colocated"). Revise topologySpreadConstraints antes de drenar."
log "Distribución verificada: todo workload replicado ocupa >= 2 nodos."

node="${1:-}"
if [[ -z "$node" ]]; then
  node="$(kubectl -n "$NS" get pods -l app.kubernetes.io/name=api-gateway -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort | uniq -c | sort -rn | awk 'NR==1 {print $2}')"
fi
kubectl get node "$node" >/dev/null || die "No existe el nodo $node."
log "Nodo a drenar: $node. Pods de $NS en ese nodo:"
kubectl -n "$NS" get pods --field-selector="spec.nodeName=$node" -o custom-columns='POD:.metadata.name' --no-headers | sed 's/^/    /'

ip="$(gateway_ip)"
[[ -n "$ip" ]] || die "El Service $P9_GATEWAY no tiene IP pública."
probe_csv="$P9_DIR/evidencia/nodo/sondeo-$(date -u +%Y%m%dT%H%M%SZ).csv"

uncordoned=0
restore_node() {
  if ((uncordoned == 0)); then
    uncordoned=1
    log "Cierre: kubectl uncordon $node"
    kubectl uncordon "$node" || warn "uncordon falló: ejecútelo a mano: kubectl uncordon $node"
  fi
}
probe_pid=""
stop_probe() { [[ -z "$probe_pid" ]] || kill "$probe_pid" 2>/dev/null || true; }
trap 'stop_probe; restore_node' EXIT

stage "1. Sondeo continuo de http://$ip ($PROBE_PATHS, cada ${PROBE_INTERVAL_S}s)"
echo "timestamp_utc,ruta,http_code,segundos" >"$probe_csv"
(
  while :; do
    for path in $PROBE_PATHS; do
      out="$(curl -s -o /dev/null --max-time 5 -w '%{http_code},%{time_total}' "http://$ip$path" || true)"
      printf '%s,%s,%s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$path" "${out:-000,5}" >>"$probe_csv"
    done
    sleep "$PROBE_INTERVAL_S"
  done
) &
probe_pid=$!
log "Sondeo en segundo plano (pid $probe_pid) -> ${probe_csv#"$REPO_ROOT"/}. Línea base de ${SETTLE_S}s..."
sleep "$SETTLE_S"

stage "2. Drenaje de $node (respeta PDB)"
t_drain_start="$(ts)"
log "DRENAJE_INICIO=$t_drain_start"
kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --timeout="$DRAIN_TIMEOUT"
t_drain_end="$(ts)"
log "DRENAJE_FIN=$t_drain_end (todos los Pods desalojables fueron desalojados)"

stage "3. Reprogramación y recuperación"
kubectl -n "$NS" wait --for=condition=Available deployment --all --timeout=10m
for sts in $(kubectl -n "$NS" get statefulset -o name); do
  kubectl -n "$NS" rollout status "$sts" --timeout=10m
done
"$SCRIPT_DIR/wait-for-rollout.sh" "$P9_GATEWAY" "$NS" Healthy 600
t_recovered="$(ts)"
log "RECUPERADO=$t_recovered: Deployments Available, StatefulSets listos y Rollout Healthy sin $node."
placement
left="$(kubectl -n "$NS" get pods --field-selector="spec.nodeName=$node" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
log "Pods de $NS que quedan en $node: $left"
log "Observación del sondeo durante ${SETTLE_S}s más con $node acordonado..."
sleep "$SETTLE_S"
stop_probe
probe_pid=""

stage "4. Cierre: uncordon"
restore_node
kubectl get nodes

stage "5. Resultado del sondeo"
t_start_e=$(epoch "$t_drain_start")
report="$(awk -F, -v t0="$t_drain_start" -v min="$MIN_AVAILABILITY" 'NR > 1 {
    total[$2]++; if ($3 ~ /^2/) ok[$2]++; else { ko[$2]++; if (!(($2) in first_ko)) first_ko[$2] = $1; last_ko[$2] = $1 }
    if ($1 >= t0) { during[$2]++; if ($3 !~ /^2/) during_ko[$2]++ }
  }
  END {
    fail = 0
    for (p in total) {
      pct = 100 * ok[p] / total[p]
      printf "RUTA %s total=%d ok=%d fallos=%d disponibilidad=%.2f%% fallos_desde_drenaje=%d/%d primer_fallo=%s ultimo_fallo=%s\n", p, total[p], ok[p], ko[p] + 0, pct, during_ko[p] + 0, during[p] + 0, (p in first_ko ? first_ko[p] : "-"), (p in last_ko ? last_ko[p] : "-")
      if (pct < min) fail = 1
    }
    printf "VEREDICTO %s (umbral %.2f%% por ruta)\n", (fail ? "FALLA" : "OK"), min
  }' "$probe_csv")"
printf '%s\n' "$report"
log "Marcas: DRENAJE_INICIO=$t_drain_start DRENAJE_FIN=$t_drain_end RECUPERADO=$t_recovered duracion_drenaje_s=$(($(epoch "$t_drain_end") - t_start_e)) recuperacion_s=$(($(epoch "$t_recovered") - t_start_e))"
log "Sondeo crudo: ${probe_csv#"$REPO_ROOT"/}"
grep -q '^VEREDICTO OK' <<<"$report" || die "La disponibilidad cayó por debajo de ${MIN_AVAILABILITY}% en alguna ruta durante el drenaje."
log "NODO_OK: el servicio respondió durante el drenaje de $node."
