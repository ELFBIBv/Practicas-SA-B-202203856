#!/usr/bin/env bash
# ok() siempre devuelve 0: "cond && ok || ko" equivale a if/else aquí.
# shellcheck disable=SC2015
# Pruebas unitarias de la lógica de las pruebas de DR (lib/dr-tests.sh y los
# cálculos de dr-node-drain-test.sh / dr-rebuild-test.sh) sin clúster ni
# Azure: kubectl y mysql se sustituyen por funciones que devuelven respuestas
# realistas. Corre en CI (.github/workflows/p9-validate.yml).
#
# Uso, desde la raíz del repositorio: ./P9/scripts/tests/dr-tests-lib.test.sh
set -Eeuo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$TESTS_DIR/../lib/common.sh"
# shellcheck source=lib/p9-config.sh
source "$TESTS_DIR/../lib/p9-config.sh"
# shellcheck source=lib/dr-tests.sh
source "$TESTS_DIR/../lib/dr-tests.sh"

fail=0
ok() { printf 'OK    %s\n' "$*"; }
ko() {
  printf 'FALLA %s\n' "$*"
  fail=1
}
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- marker_write: la hora del servidor MySQL (microsegundos) se recorta a ms.
# shellcheck disable=SC2329 # la invoca marker_write
mysql_q() { case "$1" in SELECT*) printf '2026-10-16T07:33:38.123000Z\n' ;; esac; }
r="$(marker_write t1 pre-backup)"
[[ "$r" == 2026-10-16T07:33:38.123Z ]] && ok "marker_write devuelve ISO 8601 con ms ($r)" || ko "marker_write -> $r"

# --- epoch acepta milisegundos.
[[ "$(epoch 2026-10-16T07:33:38.123Z)" == "$(date -u -d 2026-10-16T07:33:38Z +%s)" ]] &&
  ok "epoch acepta milisegundos" || ko "epoch con milisegundos"

# --- wait_backup_completed con kubectl simulado.
SCENARIO=completed
# shellcheck disable=SC2329 # la invocan las funciones bajo prueba
kubectl() {
  case "$*" in
    *"get schedule"*) echo '*/15 * * * *' ;;
    *"get backups"*)
      case $SCENARIO in
        completed)
          cat <<'JSON'
{"items":[
 {"metadata":{"name":"anterior"},"status":{"phase":"Completed","startTimestamp":"2026-10-16T07:30:00Z"}},
 {"metadata":{"name":"mismo-segundo"},"status":{"phase":"Completed","startTimestamp":"2026-10-16T07:33:38Z"}},
 {"metadata":{"name":"siguiente"},"status":{"phase":"Completed","startTimestamp":"2026-10-16T07:45:00Z"}},
 {"metadata":{"name":"posterior"},"status":{"phase":"Completed","startTimestamp":"2026-10-16T08:00:00Z"}}]}
JSON
          ;;
        partial) echo '{"items":[{"metadata":{"name":"roto"},"status":{"phase":"PartiallyFailed","startTimestamp":"2026-10-16T07:45:00Z"}}]}' ;;
        none) echo '{"items":[]}' ;;
      esac
      ;;
    *) : ;;
  esac
}
# shellcheck disable=SC2329 # evita esperas reales dentro de las funciones
sleep() { :; }

r="$(wait_backup_completed 2026-10-16T07:33:38.123Z 60 2>/dev/null)"
[[ "$r" == siguiente ]] && ok "wait_backup_completed elige el primer backup posterior al marcador ($r)" ||
  ko "wait_backup_completed -> '$r' (esperado: siguiente)"
SCENARIO=partial
if (wait_backup_completed 2026-10-16T07:33:38Z 60 >/dev/null 2>&1); then ko "un backup PartiallyFailed no hizo fallar la prueba"; else ok "un backup PartiallyFailed hace fallar la prueba"; fi
SCENARIO=none
if (wait_backup_completed 2026-10-16T07:33:38Z 0 >/dev/null 2>&1); then ko "sin backups no falló por timeout"; else ok "sin backups falla por timeout"; fi

# --- backup_times debe poder leerse con `read` bajo `set -e`. Este kubectl
# simulado imita a jsonpath real: interpreta {"\n"} y no agrega salto de línea
# propio. Sin el {"\n"} en backup_times, `read` devuelve 1 y aborta el script.
# shellcheck disable=SC2329 # la invoca backup_times
kubectl() {
  local tpl="${*##*jsonpath=}"
  [[ "$tpl" == *'{"\n"}' ]] && printf '2026-10-16T17:00:34Z 2026-10-16T17:01:50Z\n' || printf '2026-10-16T17:00:34Z 2026-10-16T17:01:50Z'
}
# Se mide el código de read directamente: dentro de la condición de un `if`
# bash ignora `set -e`, incluso en subshells, y ocultaría el fallo.
read_rc=0
read -r b_start b_end < <(backup_times b1) || read_rc=$?
if ((read_rc == 0)) && [[ "$b_start/$b_end" == 2026-10-16T17:00:34Z/2026-10-16T17:01:50Z ]]; then
  ok "backup_times se lee con read bajo set -e (salto de línea final)"
else
  ko "backup_times sin salto de línea final: read devuelve 1 y aborta las pruebas de DR"
fi

# --- redact: GUID en claro y el id base64 de data.azurerm_client_config
# (formato real de la salida de terraform plan; valores ficticios).
cid="$(printf 'clientConfigs/clientId=11111111-2222-3333-4444-555555555555;objectId=66666666-7777-8888-9999-000000000000' | base64 -w0)"
red="$(printf '%s\n' "data.azurerm_client_config.current: Read complete after 0s [id=$cid]" \
  "azurerm_storage_account.velero: Refreshing state... [id=/subscriptions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/resourceGroups/rg-p9-tfstate]" | redact)"
if grep -q "$cid" <<<"$red" || grep -qE '[0-9a-f]{8}-[0-9a-f]{4}-' <<<"$red"; then
  ko "redact dejó pasar un identificador: $red"
elif grep -q 'id=<base64-redactado>' <<<"$red" && grep -q 'rg-p9-tfstate' <<<"$red"; then
  ok "redact tapa GUID y el id base64 de Terraform sin borrar el resto de la línea"
else
  ko "redact cambió de más: $red"
fi

# --- Reporte del sondeo de dr-node-drain-test.sh (mismo awk que el script).
script="$TESTS_DIR/../dr-node-drain-test.sh"
awk_prog="$(sed -n "/^report=\"\$(awk -F, /,/}' \"\$probe_csv\")\"/p" "$script" |
  sed "1s/^report=\"\$(awk -F, -v t0=\"\$t_drain_start\" -v min=\"\$MIN_AVAILABILITY\" '//; \$s/' \"\$probe_csv\")\"\$//")"
[[ -n "$awk_prog" ]] || ko "no se pudo extraer el awk del reporte de $script"
cat >"$work/sondeo.csv" <<'CSV'
timestamp_utc,ruta,http_code,segundos
2026-10-16T08:00:00.000Z,/ready,200,0.01
2026-10-16T08:00:00.100Z,/api/catalog/health,200,0.02
2026-10-16T08:01:00.000Z,/ready,200,0.01
2026-10-16T08:01:00.100Z,/api/catalog/health,000,5
2026-10-16T08:01:01.000Z,/ready,200,0.01
2026-10-16T08:01:01.100Z,/api/catalog/health,503,0.1
CSV
report="$(awk -F, -v t0=2026-10-16T08:00:30Z -v min=99.0 "$awk_prog" "$work/sondeo.csv")"
grep -q '^RUTA /ready total=3 ok=3 fallos=0 disponibilidad=100.00%' <<<"$report" &&
  grep -q '^RUTA /api/catalog/health total=3 ok=1 fallos=2 .*fallos_desde_drenaje=2/2' <<<"$report" &&
  grep -q '^VEREDICTO FALLA' <<<"$report" &&
  ok "reporte del sondeo: disponibilidad por ruta y VEREDICTO FALLA bajo el umbral" || {
  ko "reporte del sondeo inesperado:"
  printf '%s\n' "$report"
}

# --- Detección de réplicas concentradas en un nodo (mismo jq que el script).
jq_prog="$(sed -n "/^colocated=/,/| .\[0\].app')\"/p" "$script" | sed "1s/.*jq -r '//; \$s/')\"\$//")"
pods='{"items":[
 {"metadata":{"labels":{"app.kubernetes.io/name":"auth"}},"spec":{"nodeName":"n1"},"status":{"phase":"Running"}},
 {"metadata":{"labels":{"app.kubernetes.io/name":"auth"}},"spec":{"nodeName":"n1"},"status":{"phase":"Running"}},
 {"metadata":{"labels":{"app.kubernetes.io/name":"catalog"}},"spec":{"nodeName":"n1"},"status":{"phase":"Running"}},
 {"metadata":{"labels":{"app.kubernetes.io/name":"catalog"}},"spec":{"nodeName":"n2"},"status":{"phase":"Running"}},
 {"metadata":{"labels":{"app":"mysql"}},"spec":{"nodeName":"n1"},"status":{"phase":"Running"}},
 {"metadata":{"labels":{"app.kubernetes.io/name":"cron1"}},"spec":{"nodeName":"n1"},"status":{"phase":"Succeeded"}}]}'
r="$(jq -r "$jq_prog" <<<"$pods")"
[[ "$r" == auth ]] && ok "detecta solo el workload replicado concentrado en un nodo (auth)" || ko "réplicas concentradas -> '$r'"

# --- SealedSecrets sin descifrar (mismo jq que dr-rebuild-test.sh).
rebuild="$TESTS_DIR/../dr-rebuild-test.sh"
jq_ss="$(grep -oP "^bad=\"\\\$\(kubectl get sealedsecrets -A -o json \| jq -r '\K.*(?='\)\"$)" "$rebuild")"
ss='{"items":[
 {"metadata":{"namespace":"sa-p5","name":"ok"},"status":{"conditions":[{"type":"Synced","status":"True"}]}},
 {"metadata":{"namespace":"sa-p5","name":"roto"},"status":{"conditions":[{"type":"Synced","status":"False"}]}},
 {"metadata":{"namespace":"kyverno","name":"sin-estado"}}]}'
r="$(jq -r "$jq_ss" <<<"$ss" | tr '\n' ' ')"
[[ "$r" == "sa-p5/roto kyverno/sin-estado " ]] && ok "detecta SealedSecrets sin descifrar o sin estado" || ko "SealedSecrets sin descifrar -> '$r'"

# --- Extracción de RTO_INICIO/RTO_FIN del log del bootstrap (última aparición).
printf '%s\n' "x Bootstrap P9 'all' iniciado (commit abc). RTO_INICIO=2026-10-16T08:10:00Z" \
  "x RTO_INICIO=2026-10-16T08:10:00Z RTO_FIN=2026-10-16T08:52:13Z RTO_SEGUNDOS=2533" >"$work/boot.log"
s="$(grep -oE 'RTO_INICIO=[^ ]+' "$work/boot.log" | tail -n1 | cut -d= -f2)"
e="$(grep -oE 'RTO_FIN=[^ ]+' "$work/boot.log" | tail -n1 | cut -d= -f2)"
[[ "$s/$e" == 2026-10-16T08:10:00Z/2026-10-16T08:52:13Z ]] && ok "extracción de RTO_INICIO/RTO_FIN" || ko "RTO extraído: $s/$e"

((fail == 0)) && echo "Todas las pruebas pasaron." || echo "Hay pruebas fallidas."
exit "$fail"
