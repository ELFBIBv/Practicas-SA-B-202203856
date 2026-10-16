#!/usr/bin/env bash
# Utilidades compartidas por los scripts de P9. Se carga con `source`, no se
# ejecuta directamente. El script que la carga debe haber hecho antes
# `set -Eeuo pipefail`.
#
# Todos los logs van a stderr con marca de tiempo ISO 8601 en UTC, para que
# las evidencias de distintas corridas usen la misma zona horaria y stdout
# quede libre para devolver valores entre funciones.

[[ -n "${_P9_COMMON_SH:-}" ]] && return 0
_P9_COMMON_SH=1

P9_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO_ROOT="$(cd "$P9_DIR/.." && pwd)"
export P9_DIR REPO_ROOT

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s [INFO]  %s\n' "$(ts)" "$*" >&2; }
warn() { printf '%s [WARN]  %s\n' "$(ts)" "$*" >&2; }
die() {
  printf '%s [ERROR] %s\n' "$(ts)" "$*" >&2
  exit 1
}
stage() { printf '\n%s [STAGE] ===== %s =====\n' "$(ts)" "$*" >&2; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "Falta el comando requerido '$c' en el PATH."
  done
}

# version_ge <actual> <mínima>: verdadero si actual >= mínima (orden semver).
version_ge() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | sed -n 1p)" == "$2" ]]
}

# retry <intentos> <espera_s> <comando...>: reintenta errores transitorios
# (throttling de ARM, propagación eventual). No se usa para ocultar errores
# permanentes: al agotar los intentos devuelve el código de fallo.
retry() {
  local attempts=$1 delay=$2 n=1
  shift 2
  until "$@"; do
    ((n >= attempts)) && return 1
    warn "Falló (intento $n/$attempts): $*. Reintento en ${delay}s."
    sleep "$delay"
    n=$((n + 1))
  done
}

# Muestra solo el prefijo de un identificador (p. ej. la suscripción) en logs
# que pueden terminar como evidencia pública.
mask() { printf '%s…' "${1:0:8}"; }
