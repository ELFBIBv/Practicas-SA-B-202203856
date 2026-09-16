#!/usr/bin/env bash
# Espera a que un Rollout de Argo Rollouts alcance una fase determinada
# (Healthy, Degraded, Paused...), consultando spec.status.phase por polling.
# Uso: wait-for-rollout.sh <rollout> <namespace> <fase-esperada> [timeout-segundos]
set -euo pipefail

rollout="${1:?Falta el nombre del Rollout}"
namespace="${2:?Falta el namespace}"
expected="${3:?Falta la fase esperada (Healthy|Degraded|Paused)}"
timeout="${4:-180}"

elapsed=0
while true; do
  phase=$(kubectl get rollout "$rollout" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  printf 'Fase actual: %s (esperando: %s, %ss transcurridos)\n' "${phase:-<sin fase>}" "$expected" "$elapsed"

  if [[ "$phase" == "$expected" ]]; then
    printf 'El Rollout alcanzó la fase esperada: %s\n' "$expected"
    exit 0
  fi

  if [[ "$phase" == "Degraded" && "$expected" != "Degraded" ]]; then
    printf 'El Rollout se degradó inesperadamente en vez de llegar a %s.\n' "$expected" >&2
    exit 1
  fi

  if (( elapsed >= timeout )); then
    printf 'Timeout esperando la fase %s (fase actual: %s)\n' "$expected" "$phase" >&2
    exit 1
  fi

  sleep 5
  elapsed=$((elapsed + 5))
done
