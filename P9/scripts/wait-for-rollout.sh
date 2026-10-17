#!/usr/bin/env bash
# Espera a que la generación actual de un Rollout de Argo Rollouts alcance
# una fase determinada (Healthy, Degraded, Paused...) mediante polling.
# Uso: wait-for-rollout.sh <rollout> <namespace> <fase-esperada> [timeout-segundos]
set -euo pipefail

rollout="${1:?Falta el nombre del Rollout}"
namespace="${2:?Falta el namespace}"
expected="${3:?Falta la fase esperada (Healthy|Degraded|Paused)}"
timeout="${4:-180}"

elapsed=0
while true; do
  state=$(kubectl get rollout "$rollout" -n "$namespace" \
    -o jsonpath='{.metadata.generation}{"|"}{.status.observedGeneration}{"|"}{.status.phase}' \
    2>/dev/null || echo "")
  IFS='|' read -r generation observed_generation phase <<< "$state"

  printf 'Generación: %s, observada: %s, fase: %s (esperando: %s, %ss transcurridos)\n' \
    "${generation:-?}" "${observed_generation:-?}" \
    "${phase:-<sin fase>}" "$expected" "$elapsed"

  if [[ "$generation" == "$observed_generation" && "$phase" == "$expected" ]]; then
    printf 'El Rollout alcanzó la fase esperada: %s\n' "$expected"
    exit 0
  fi

  if [[ "$generation" == "$observed_generation" && \
        "$phase" == "Degraded" && "$expected" != "Degraded" ]]; then
    printf 'El Rollout se degradó inesperadamente en vez de llegar a %s.\n' "$expected" >&2
    exit 1
  fi

  if [[ "$generation" == "$observed_generation" && \
        "$phase" == "Healthy" && "$expected" == "Degraded" ]]; then
    printf 'La generación actual terminó Healthy; no detectó el fallo esperado.\n' >&2
    exit 1
  fi

  if (( elapsed >= timeout )); then
    printf 'Timeout esperando la fase %s (generación: %s, observada: %s, fase: %s)\n' \
      "$expected" "${generation:-?}" "${observed_generation:-?}" "${phase:-<sin fase>}" >&2
    exit 1
  fi

  sleep 5
  elapsed=$((elapsed + 5))
done
