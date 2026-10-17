#!/usr/bin/env bash
# Esperas y verificaciones posteriores al apply. Cada una espera una condición
# observable del clúster con timeout: nunca un sleep a ciegas. Requiere
# lib/common.sh y lib/p9-config.sh, y KUBECONFIG apuntando al clúster de P9.

[[ -n "${_P9_CLUSTER_CHECKS_SH:-}" ]] && return 0
_P9_CLUSTER_CHECKS_SH=1

# Obtiene credenciales del clúster en un kubeconfig propio (no toca el del
# operador) y lo exporta para el resto del proceso.
cluster_credentials() {
  mkdir -p "$(dirname "$P9_KUBECONFIG")"
  (umask 077 && azs aks get-credentials -g "$P9_RESOURCE_GROUP" -n "$P9_CLUSTER_NAME" \
    --file "$P9_KUBECONFIG" --overwrite-existing -o none)
  export KUBECONFIG="$P9_KUBECONFIG"
  log "kubeconfig de P9: $P9_KUBECONFIG (contexto $(kubectl config current-context))."
}

wait_nodes_ready() {
  log "Esperando nodos Ready..."
  kubectl wait --for=condition=Ready nodes --all --timeout=10m
  local n
  n="$(kubectl get nodes --no-headers | wc -l | tr -d ' ')"
  ((n >= 2)) || die "Solo hay $n nodo(s); la prueba de pérdida de nodo requiere >= 2."
  kubectl get nodes -o wide >&2
}

wait_argocd() {
  local ns=$P9_ARGOCD_NAMESPACE
  log "Esperando ArgoCD en $ns..."
  kubectl -n "$ns" wait --for=condition=Available deployment --all --timeout=10m
  kubectl -n "$ns" rollout status statefulset/argocd-application-controller --timeout=10m
  kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=2m
  # Falla temprano si el argocd-cm cargado no trae el Lua nuevo (mira
  # operationState/sync, no solo status.health): con el Lua viejo las olas de
  # la raíz son decorativas (P9/docs/diseno-sync-waves.md §0.1, §3.1).
  kubectl -n "$ns" get cm argocd-cm \
    -o jsonpath='{.data.resource\.customizations\.health\.argoproj\.io_Application}' \
    | grep -q operationState \
    || die "argocd-cm no trae el Lua de health de Application esperado (operationState). Revise module.argocd (terraform/modules/argocd/health/application.lua)."
}

# Diagnóstico que se imprime si una Application no converge. Solo usa nombres
# y estados, nunca el contenido de Secrets.
_argocd_diagnostics() {
  warn "Estado de las Applications:"
  kubectl -n "$P9_ARGOCD_NAMESPACE" get applications \
    -o custom-columns='APP:.metadata.name,WAVE:.metadata.annotations.argocd\.argoproj\.io/sync-wave,SYNC:.status.sync.status,HEALTH:.status.health.status,MENSAJE:.status.conditions[*].message' >&2 || true
  # [PUNTO DE INTEGRACIÓN CON SECRETOS] causa típica de una wave detenida.
  warn "SealedSecrets (condición Synced):"
  kubectl get sealedsecrets -A \
    -o custom-columns='NS:.metadata.namespace,NOMBRE:.metadata.name,SYNCED:.status.conditions[?(@.type=="Synced")].status,MENSAJE:.status.conditions[?(@.type=="Synced")].message' >&2 || true
}

# wait_application <nombre> <timeout_s>: sondea sync/health/operación cada
# 10 s y registra cada transición, hasta Synced/Healthy sin operación en curso
# o timeout. La operación cuenta: un hook de Sync (p. ej. el Job
# p9-data-restore) no entra en el health de la app, que se ve Healthy mientras
# el hook sigue corriendo; la raíz (health/application.lua) tampoco avanza.
wait_application() {
  local name=$1 timeout=$2 last="" cur deadline
  deadline=$((SECONDS + timeout))
  while :; do
    cur="$(kubectl -n "$P9_ARGOCD_NAMESPACE" get application "$name" \
      -o jsonpath='{.status.sync.status}/{.status.health.status}/{.status.operationState.phase}' 2>/dev/null || true)"
    if [[ "$cur" != "$last" ]]; then
      log "Application $name: ${cur:-sin estado todavía}"
      last=$cur
    fi
    [[ "$cur" == Synced/Healthy/ || "$cur" == Synced/Healthy/Succeeded ]] && return 0
    if ((SECONDS >= deadline)); then
      _argocd_diagnostics
      die "La Application $name no llegó a Synced/Healthy en ${timeout}s (último: ${cur:-sin estado})."
    fi
    sleep 10
  done
}

# Espera las Applications hijas ola por ola, en el orden de P9_WAVES, y
# comprueba que la ola declarada en el repo GitOps coincida con la esperada.
# No basta con esperar solo a la raíz: por H5 (P9/docs/diseno-sync-waves.md),
# una hija que aún no existe no cuenta en el health de la raíz, así que la
# raíz podría verse Healthy antes de que existan todas las hijas. Esperar
# ola por ola además da el desglose de tiempos para el informe de RTO.
wait_waves() {
  local entry wave apps app budget t0 got
  for entry in $P9_WAVES; do
    wave=${entry%%:*}
    apps=${entry#*:}
    budget=$(tr ' ' '\n' <<<"$P9_WAVE_TIMEOUTS" | awk -F: -v w="$wave" '$1 == w {print $2}')
    [[ -n "$budget" ]] || die "Sin presupuesto de espera para la ola $wave (revise P9_WAVE_TIMEOUTS)."
    t0=$SECONDS
    for app in ${apps//,/ }; do
      wait_application "$app" "$budget"
      got="$(kubectl -n "$P9_ARGOCD_NAMESPACE" get application "$app" \
        -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/sync-wave}')"
      [[ "$got" == "$wave" ]] || die "La Application $app está en la ola '$got' del repo GitOps, no en $wave (P9_WAVES desincronizado)."
    done
    log "OLA $wave cerrada en $((SECONDS - t0))s: $apps"
  done
  wait_application "$P9_ROOT_APP" 300
  local auto
  auto="$(kubectl -n "$P9_ARGOCD_NAMESPACE" get application sa-platform \
    -o jsonpath='{.spec.syncPolicy.automated.selfHeal}')"
  [[ "$auto" == true ]] || die "sa-platform no tiene sincronización automática (selfHeal) habilitada."
}

wait_controllers() {
  log "Verificando controladores..."
  kubectl -n kube-system rollout status deployment/sealed-secrets-controller --timeout=5m
  kubectl -n argo-rollouts wait --for=condition=Available deployment --all --timeout=5m
  kubectl -n kyverno wait --for=condition=Available deployment --all --timeout=5m

  # [VELERO] servidor, node-agent, BSL sincronizada (H12) y Schedule Enabled.
  # Ver P9/docs/diseno-sync-waves.md §2.2, §5 (paso 10).
  kubectl -n velero wait --for=condition=Available deployment/velero --timeout=5m
  kubectl -n velero rollout status daemonset/node-agent --timeout=5m
  kubectl -n velero wait --for=jsonpath='{.status.phase}'=Available backupstoragelocation/default --timeout=5m
  kubectl -n velero wait --for=jsonpath='{.status.phase}'=Enabled schedule/sa-p9-schedule --timeout=2m

  local policies not_enforced
  policies="$(kubectl get clusterpolicy -o jsonpath='{range .items[*]}{.metadata.name}={.spec.validationFailureAction}{"\n"}{end}')"
  log "ClusterPolicies: $(tr '\n' ' ' <<<"$policies")"
  [[ "$(grep -c . <<<"$policies")" -ge 3 ]] || die "Se esperaban 3 ClusterPolicies de P8."
  not_enforced="$(grep -v -E '=Enforce$' <<<"$policies" || true)"
  [[ -z "$not_enforced" ]] || die "Políticas fuera de Enforce: $not_enforced"
  kubectl wait --for=condition=Ready clusterpolicy --all --timeout=3m
}

wait_workloads() {
  local ns=$P9_APP_NAMESPACE sts
  log "Esperando workloads en $ns..."
  kubectl -n "$ns" wait --for=condition=Available deployment --all --timeout=10m
  for sts in $(kubectl -n "$ns" get statefulset -o name); do
    kubectl -n "$ns" rollout status "$sts" --timeout=10m
  done
  "$P9_DIR/scripts/wait-for-rollout.sh" "$P9_GATEWAY" "$ns" Healthy 600
}

# Imprime la IP pública del gateway cuando responde en los endpoints de salud.
wait_endpoint() {
  local ns=$P9_APP_NAMESPACE ip="" deadline path
  deadline=$((SECONDS + 600))
  log "Esperando IP pública del Service $P9_GATEWAY..."
  until [[ -n "$ip" ]]; do
    ip="$(kubectl -n "$ns" get service "$P9_GATEWAY" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
    [[ -n "$ip" ]] && break
    ((SECONDS < deadline)) || die "El Service $P9_GATEWAY no obtuvo IP pública en 600s."
    sleep 10
  done
  for path in /ready /api/auth/health /api/catalog/health /api/orders/health; do
    # Sin --retry-delay: curl duplica la espera en cada intento (1s, 2s, 4s...).
    # --retry-max-time acota el total sin necesitar un contador de intentos fijo.
    curl --fail --silent --show-error --max-time 10 \
      --retry 12 --retry-max-time 600 --retry-all-errors \
      -o /dev/null "http://$ip$path" ||
      die "El endpoint http://$ip$path no respondió 2xx."
    log "OK http://$ip$path"
  done
  printf '%s\n' "$ip"
}
