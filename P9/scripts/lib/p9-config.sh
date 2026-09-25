#!/usr/bin/env bash
# Configuración compartida por bootstrap.sh, destroy-cluster.sh y
# verify-tfstate-lock.sh. Es la única fuente de los nombres del clúster: se
# exportan como TF_VAR_* para que 01-cluster y 02-platform hablen siempre del
# mismo clúster. Todas las variables P9_* admiten override por entorno.

[[ -n "${_P9_CONFIG_SH:-}" ]] && return 0
_P9_CONFIG_SH=1

P9_LOCATION="${P9_LOCATION:-chilecentral}"
P9_RESOURCE_GROUP="${P9_RESOURCE_GROUP:-rg-p9-aks}"
P9_CLUSTER_NAME="${P9_CLUSTER_NAME:-aks-sa-p9}"
P9_ARGOCD_NAMESPACE="${P9_ARGOCD_NAMESPACE:-argocd}"
P9_APP_NAMESPACE="${P9_APP_NAMESPACE:-sa-p5}"
P9_ROOT_APP="${P9_ROOT_APP:-p9-root}"
P9_GATEWAY="${P9_GATEWAY:-sa-platform-api-gateway}"

# ola:app1,app2 — la lista completa de Applications hijas esperadas sale de
# aquí (wait_waves las recorre ola por ola). Debe coincidir con
# argocd.argoproj.io/sync-wave en P9/gitops/apps/ (verificado por V-S3, ver
# scripts/publish-gitops.sh).
# "velero" (el operador) NO es una Application: lo instala Terraform en
# 02-platform (module.velero), porque necesita Workload Identity funcionando
# antes de que el Pod arranque. Solo su Schedule es GitOps (velero-schedules,
# ola 5). Ver P9/docs/diseno-velero.md §1.
# Fuente: P9/docs/diseno-sync-waves.md §5, §7.1 (ola -20 ajustada por el
# diseño de Velero).
P9_WAVES="${P9_WAVES:--30:sealed-secrets -20:kyverno,argo-rollouts -10:platform-secrets,data-restore -5:kyverno-policies 0:sa-platform 5:velero-schedules 10:platform-verify}"
# Presupuesto de espera por ola en segundos: es el límite para FALLAR, no una
# estimación del RTO. P9/docs/diseno-sync-waves.md §5.
P9_WAVE_TIMEOUTS="${P9_WAVE_TIMEOUTS:--30:600 -20:900 -10:2700 -5:600 0:1200 5:300 10:600}"
# kubeconfig propio de P9: no modifica ~/.kube/config ni el contexto activo
# del operador. Queda fuera del repositorio.
P9_KUBECONFIG="${P9_KUBECONFIG:-$HOME/.kube/p9-${P9_CLUSTER_NAME}.config}"
# Vault de custodia de la llave de Sealed Secrets (diseño de secretos).
SEALED_KEYRING_VAULT="${SEALED_KEYRING_VAULT:-kv-sa-p9-202203856}"

export TF_VAR_location="$P9_LOCATION"
export TF_VAR_resource_group_name="$P9_RESOURCE_GROUP"
export TF_VAR_cluster_name="$P9_CLUSTER_NAME"
export TF_VAR_argocd_namespace="$P9_ARGOCD_NAMESPACE"
export TF_VAR_app_namespace="$P9_APP_NAMESPACE"
export TF_VAR_root_app_name="$P9_ROOT_APP"

# Cada etapa de Terraform tiene su propio directorio y su propio estado remoto.
tf_stack_dir() { printf '%s/terraform/%s' "$P9_DIR" "$1"; }
tf_stack_key() { printf 'p9/%s.tfstate' "$1"; }
