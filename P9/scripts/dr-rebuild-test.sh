#!/usr/bin/env bash
# Prueba de DR cronometrada completa (rúbricas 2.1, 2.3, 2.4, 2.6 y P8):
# destruye el clúster aks-sa-p9 y lo reconstruye con el punto de entrada
# único, midiendo RTO y RPO con marcas de tiempo reales.
#
# OPERACIÓN IRREVERSIBLE Y CON COSTO. Uso, desde la raíz del repositorio:
#   ./P9/scripts/dr-rebuild-test.sh --confirm aks-sa-p9
#
# Secuencia:
#   0. Prerrequisitos: clúster vivo, RESTORE_MODE=required, llave en custodia.
#   1. Marcador M1 en MySQL y espera del siguiente Backup PROGRAMADO posterior.
#   2. Marcador M2 (posterior al respaldo: pérdida esperada).
#   3. DESASTRE: scripts/destroy-cluster.sh (borra rg-p9-aks, AKS y discos).
#   4. RECONSTRUCCIÓN: scripts/bootstrap.sh all (sin intervención).
#   5. Verificación en el clúster nuevo: datos (M1 sí, M2 no), secretos
#      descifrados y consumidos, controles de P8 (GitOps, Rollout, Kyverno).
#   6. RTO y RPO calculados desde las marcas de tiempo.
#
# Definiciones (P9/docs/informe-dr.md):
#   RTO (declarado, 45 min) = RTO_FIN - RTO_INICIO del bootstrap: desde que el
#     operador lanza la reconstrucción hasta que los 4 endpoints responden 2xx.
#   Caída total = RTO_FIN - DESASTRE_INICIO (incluye la destrucción).
#   RPO (declarado, 15 min) = DESASTRE_INICIO - escrito_utc del último dato
#     recuperado (M1).
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/p9-config.sh
source "$SCRIPT_DIR/lib/p9-config.sh"
# shellcheck source=lib/dr-tests.sh
source "$SCRIPT_DIR/lib/dr-tests.sh"

BACKUP_WAIT_S="${BACKUP_WAIT_S:-1500}"

[[ "${1:-}" == --confirm && "${2:-}" == "$P9_CLUSTER_NAME" ]] ||
  die "Operación irreversible. Confirme con: $0 --confirm $P9_CLUSTER_NAME"

require_cmd az terraform kubectl jq curl git
use_p9_kubeconfig
evidence_log reconstruccion reconstruccion
trap 'die "Falló la línea $LINENO: $BASH_COMMAND"' ERR
log "Commit del repositorio de código: $(git -C "$REPO_ROOT" rev-parse --short HEAD)"

stage "0. Prerrequisitos (antes de destruir nada)"
mode="$(kubectl -n "$P9_VELERO_NS" get configmap p9-data-restore-config -o jsonpath='{.data.RESTORE_MODE}')"
[[ "$mode" == required ]] ||
  die "RESTORE_MODE=$mode en el repo GitOps. Debe ser 'required' antes de la prueba (runbook, paso R-0.4): con skip-if-empty un fallo de Velero pasaría como 'génesis'."
kubectl -n "$P9_VELERO_NS" wait --for=jsonpath='{.status.phase}'=Available backupstoragelocation/default --timeout=2m
az keyvault secret show --vault-name "$SEALED_KEYRING_VAULT" --name sealed-secrets-keyring --query 'attributes.updated' -o tsv >/dev/null ||
  die "No se puede leer la llave custodiada en $SEALED_KEYRING_VAULT: la reconstrucción no podría descifrar los SealedSecret."
log "Llave de Sealed Secrets en custodia: vault $SEALED_KEYRING_VAULT accesible (valor no leído aquí)."
kubectl -n "$P9_APP_NAMESPACE" wait --for=condition=Ready "pod/$P9_MYSQL_POD" --timeout=2m
run_id="p9dr-$(date -u +%Y%m%dT%H%M%SZ)"
log "Identificador de la corrida: $run_id"

stage "1. Dato M1 y respaldo programado posterior"
marker_init
m1_at="$(marker_write "$run_id-M1" pre-backup)"
log "M1 id=$run_id-M1 escrito_utc=$m1_at"
backup="$(wait_backup_completed "$m1_at" "$BACKUP_WAIT_S")"
read -r b_start b_end < <(backup_times "$backup")
log "RESPALDO=$backup inicio=$b_start fin=$b_end"

stage "2. Dato M2 posterior al respaldo"
m2_at="$(marker_write "$run_id-M2" post-backup)"
log "M2 id=$run_id-M2 escrito_utc=$m2_at"

stage "3. DESASTRE: destrucción del clúster"
t_disaster="$(ts)"
log "DESASTRE_INICIO=$t_disaster"
"$SCRIPT_DIR/destroy-cluster.sh" --confirm "$P9_CLUSTER_NAME"
t_destroyed="$(ts)"
log "DESASTRE_FIN=$t_destroyed (rg $P9_RESOURCE_GROUP eliminado; backend, Key Vault y almacenamiento de Velero intactos)"
unset KUBECONFIG

stage "4. RECONSTRUCCIÓN: punto de entrada único"
boot_log="$(mktemp)"
trap 'rm -f "$boot_log"' EXIT
"$SCRIPT_DIR/bootstrap.sh" all 2>&1 | tee "$boot_log"
rto_start="$(grep -oE 'RTO_INICIO=[^ ]+' "$boot_log" | tail -n1 | cut -d= -f2)"
rto_end="$(grep -oE 'RTO_FIN=[^ ]+' "$boot_log" | tail -n1 | cut -d= -f2)"
[[ -n "$rto_start" && -n "$rto_end" ]] || die "El log del bootstrap no contiene RTO_INICIO/RTO_FIN."
export KUBECONFIG="$P9_KUBECONFIG"

stage "5a. Datos en el clúster reconstruido"
kubectl -n "$P9_VELERO_NS" logs job/p9-data-restore | grep -E 'RESPALDO_ELEGIDO|RESTORE_OK|PVC ' | sed 's/^/    /'
kubectl -n "$P9_VELERO_NS" logs job/p9-data-restore | grep -q RESTORE_OK ||
  die "El Job p9-data-restore no reporta RESTORE_OK: los volúmenes no provienen del respaldo."
kubectl -n "$P9_APP_NAMESPACE" wait --for=condition=Ready "pod/$P9_MYSQL_POD" --timeout=10m
rows="$(mysql_q "SELECT id, fase, DATE_FORMAT(escrito_utc, '%Y-%m-%dT%H:%i:%s.%fZ') FROM p9_dr_marker WHERE id LIKE '$run_id-%' ORDER BY escrito_utc")"
log "Marcadores de $run_id en el clúster nuevo (id, fase, escrito_utc):"
printf '%s\n' "${rows:-<ninguno>}" | sed 's/^/    /'
grep -q "^$run_id-M1" <<<"$rows" || die "VERIFICACIÓN FALLIDA: M1 no se recuperó."
if grep -q "^$run_id-M2" <<<"$rows"; then warn "M2 se recuperó (no esperado)."; else log "M2 no se recuperó: pérdida esperada, escrito después del respaldo."; fi
log "cron_logs (filas, último execution_time en hora local del cron): $(mysql_q 'SELECT COUNT(*), MAX(execution_time) FROM cron_logs' | tr '\t' ' ')"

stage "5b. Continuidad de secretos"
kubectl get sealedsecrets -A \
  -o custom-columns='NS:.metadata.namespace,NOMBRE:.metadata.name,SYNCED:.status.conditions[?(@.type=="Synced")].status'
bad="$(kubectl get sealedsecrets -A -o json | jq -r '.items[] | select(([.status.conditions[]? | select(.type == "Synced" and .status == "True")] | length) == 0) | "\(.metadata.namespace)/\(.metadata.name)"')"
[[ -z "$bad" ]] || die "SealedSecret sin descifrar: $bad"
for s in sa-platform-mysql sa-platform-mongodb sa-platform-auth-secrets sa-platform-nats-auth ghcr-secret; do
  log "Secret $P9_APP_NAMESPACE/$s: claves=$(kubectl -n "$P9_APP_NAMESPACE" get secret "$s" -o json | jq -c '.data | keys') dueño=$(kubectl -n "$P9_APP_NAMESPACE" get secret "$s" -o jsonpath='{.metadata.ownerReferences[0].kind}')"
done
kubectl -n "$P9_APP_NAMESPACE" get deployment sa-platform-auth -o jsonpath='{"Consumidor: sa-platform-auth disponible="}{.status.availableReplicas}{"/"}{.spec.replicas}{" (lee JWT_SECRET y DB_PASSWORD de Secrets sellados)\n"}'
fp="$(kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key=active -o jsonpath='{.items[0].data.tls\.crt}' | base64 -d | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2)"
log "Huella SHA-256 del certificado activo del controlador: ${fp:0:23}… (debe coincidir con P9/gitops/sealed-secrets/pub-cert.pem)"
[[ "$fp" == "$(openssl x509 -in "$P9_DIR/gitops/sealed-secrets/pub-cert.pem" -noout -fingerprint -sha256 | cut -d= -f2)" ]] ||
  die "El controlador no usa la llave custodiada (huella distinta al pub-cert.pem versionado)."

stage "5c. Controles heredados de P8"
kubectl -n "$P9_ARGOCD_NAMESPACE" get applications \
  -o custom-columns='APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,AUTO:.spec.syncPolicy.automated.selfHeal'
kubectl -n "$P9_APP_NAMESPACE" get rollout "$P9_GATEWAY" -o jsonpath='{"Rollout "}{.metadata.name}{" fase="}{.status.phase}{" imagen="}{.spec.template.spec.containers[0].image}{"\n"}'
kubectl get clusterpolicy -o custom-columns='POLITICA:.metadata.name,ACCION:.spec.validationFailureAction,READY:.status.conditions[?(@.type=="Ready")].status'
if deny="$(kubectl -n "$P9_APP_NAMESPACE" run p9-policy-check --image=nginx:latest --restart=Never --dry-run=server -o name 2>&1)"; then
  die "Kyverno ADMITIÓ nginx:latest en $P9_APP_NAMESPACE: las políticas no están en cumplimiento."
fi
log "Kyverno rechazó nginx:latest (dry-run de servidor): $(grep -oE '(restrict-image-registries|require-non-root-user|verify-image-signatures)' <<<"$deny" | sort -u | tr '\n' ' ')"

stage "6. Resultado"
rpo=$(($(epoch "$t_disaster") - $(epoch "$m1_at")))
rto=$(($(epoch "$rto_end") - $(epoch "$rto_start")))
outage=$(($(epoch "$rto_end") - $(epoch "$t_disaster")))
log "M1_escrito=$m1_at BACKUP=$backup inicio=$b_start fin=$b_end M2_escrito=$m2_at"
log "DESASTRE_INICIO=$t_disaster DESASTRE_FIN=$t_destroyed RTO_INICIO=$rto_start RTO_FIN=$rto_end"
log "RTO_MEDIDO_S=$rto ($((rto / 60)) min $((rto % 60)) s; declarado 45 min) CAIDA_TOTAL_S=$outage"
log "RPO_MEDIDO_S=$rpo ($((rpo / 60)) min $((rpo % 60)) s; declarado 15 min) = DESASTRE_INICIO - escrito_utc(M1)"
log "RECONSTRUCCION_OK run=$run_id"
