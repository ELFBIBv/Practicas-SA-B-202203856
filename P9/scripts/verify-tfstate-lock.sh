#!/usr/bin/env bash
# Verifica que el backend remoto de Terraform bloquea el estado (blob lease de
# Azure Storage). No crea infraestructura ni modifica el estado.
#
# Uso, desde la raíz del repositorio:
#   ./P9/scripts/verify-tfstate-lock.sh     (o: make -C P9 verify-lock)
#
# Prueba 1 (determinista): se toma un lease externo sobre el blob real del
#   estado y se comprueba que `terraform plan -lock-timeout=0s` se niega a
#   continuar con "Error acquiring the state lock".
# Prueba 2 (dos procesos Terraform): mientras un `plan` tiene el lease, un
#   segundo `plan` debe fallar por lock. Si el primero termina antes de poder
#   observar el lease, la prueba se informa como NO CONCLUYENTE, no como éxito.
# Cierre: el lease queda liberado (sin locks huérfanos).
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/p9-config.sh
source "$SCRIPT_DIR/lib/p9-config.sh"
# shellcheck source=lib/tfstate-backend.sh
source "$SCRIPT_DIR/lib/tfstate-backend.sh"

# Se prueba sobre la etapa 01-cluster: su plan solo necesita Azure, así que la
# prueba funciona aunque el clúster todavía no exista. El mecanismo de lock
# (blob lease) es idéntico para la key de 02-platform.
STACK=01-cluster
TF_DIR="$(tf_stack_dir "$STACK")"
export TF_IN_AUTOMATION=1 TF_INPUT=0

trap 'die "Falló la línea $LINENO: $BASH_COMMAND"' ERR

WORK_DIR="$(mktemp -d)"
LEASE_ID=""
BG_PID=""
cleanup() {
  if [[ -n "$LEASE_ID" ]]; then
    tfstate_az_blob lease release -b "$TFSTATE_KEY" -c "$TFSTATE_CONTAINER" --lease-id "$LEASE_ID" \
      -o none >/dev/null 2>&1 || warn "No se pudo liberar el lease $LEASE_ID; expira solo en <=60s."
  fi
  if [[ -n "$BG_PID" ]]; then kill "$BG_PID" 2>/dev/null || true; fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

lease_state() {
  tfstate_az_blob show -n "$TFSTATE_KEY" -c "$TFSTATE_CONTAINER" --query properties.lease.state -o tsv
}

# Devuelve 0 si la salida de Terraform muestra un rechazo por lock.
is_lock_error() { grep -q 'Error acquiring the state lock' "$1"; }

require_cmd az terraform
tfstate_load_config
tfstate_backend_exists ||
  die "El backend no existe todavía. Ejecute primero: ./P9/scripts/bootstrap.sh backend"
tfstate_resolve_auth
tfstate_build_backend_args "$(tf_stack_key "$STACK")"
tfstate_terraform_init "$TF_DIR" >/dev/null

[[ "$(tfstate_az_blob exists -n "$TFSTATE_KEY" -c "$TFSTATE_CONTAINER" --query exists -o tsv)" == true ]] ||
  die "El blob $TFSTATE_KEY aún no existe (se crea en el primer plan/apply). Ejecute el bootstrap antes."

state="$(lease_state)"
[[ "$state" == available ]] ||
  die "El blob ya está en estado de lease '$state': hay otra operación en curso o un lock huérfano." \
    "Revise con: terraform -chdir=$TF_DIR plan -lock-timeout=0s (muestra ID y quién lo tiene)."

# --- Prueba 1 --------------------------------------------------------------
stage "Prueba 1: lease externo sobre el estado real"
LEASE_ID="$(tfstate_az_blob lease acquire -b "$TFSTATE_KEY" -c "$TFSTATE_CONTAINER" --lease-duration 60 -o tsv)"
log "Lease tomado sobre $TFSTATE_KEY; estado del blob: $(lease_state)."
if terraform -chdir="$TF_DIR" plan -input=false -lock-timeout=0s -refresh=false \
  >"$WORK_DIR/p1.out" 2>&1; then
  die "FALLA: terraform plan continuó con el estado bloqueado. El locking NO se aplica."
fi
is_lock_error "$WORK_DIR/p1.out" ||
  die "terraform plan falló por otro motivo (no por lock); revise la salida en una terminal privada."
log "PASA: Terraform rechazó la operación: $(grep -m1 -o 'state blob is already locked' "$WORK_DIR/p1.out" || echo 'Error acquiring the state lock')."
tfstate_az_blob lease release -b "$TFSTATE_KEY" -c "$TFSTATE_CONTAINER" --lease-id "$LEASE_ID" -o none
LEASE_ID=""

# --- Prueba 2 --------------------------------------------------------------
stage "Prueba 2: dos terraform plan concurrentes"
terraform -chdir="$TF_DIR" plan -input=false -lock-timeout=0s >"$WORK_DIR/p2a.out" 2>&1 &
BG_PID=$!
observed=false
for _ in $(seq 1 120); do
  if [[ "$(lease_state)" == leased ]]; then
    observed=true
    break
  fi
  kill -0 "$BG_PID" 2>/dev/null || break
  sleep 0.5
done
if [[ "$observed" == true ]]; then
  log "Lease de Terraform observado durante el primer plan."
  if terraform -chdir="$TF_DIR" plan -input=false -lock-timeout=0s -refresh=false \
    >"$WORK_DIR/p2b.out" 2>&1; then
    warn "NO CONCLUYENTE: el segundo plan terminó sin error (el primero liberó el lock antes)."
  elif is_lock_error "$WORK_DIR/p2b.out"; then
    log "PASA: el segundo plan fue rechazado por lock mientras el primero corría."
  else
    warn "NO CONCLUYENTE: el segundo plan falló por un motivo distinto al lock."
  fi
else
  warn "NO CONCLUYENTE: el primer plan terminó antes de observar su lease (plan demasiado corto)."
fi
rc=0
wait "$BG_PID" || rc=$?
BG_PID=""
log "Primer plan terminó con código $rc (su salida no se imprime: puede contener datos del entorno)."

# --- Cierre ----------------------------------------------------------------
stage "Cierre"
state="$(lease_state)"
[[ "$state" == available ]] || die "FALLA: el blob quedó con lease '$state' tras las pruebas."
log "PASA: sin locks huérfanos (lease.state=available). Verificación de locking terminada."
