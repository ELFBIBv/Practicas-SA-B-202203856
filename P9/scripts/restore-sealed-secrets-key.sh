#!/usr/bin/env bash
# Lo invoca el punto de entrada (bootstrap.sh) entre "API de AKS disponible" e
# "instalar ArgoCD" (etapa 4, antes de 02-platform). Idempotente.
# Requiere rol "Key Vault Secrets User". No imprime material privado.
#
# Variables requeridas: SEALED_KEYRING_VAULT, AKS_RESOURCE_GROUP, AKS_NAME.
# Diseño: P9/docs/diseno-secretos-dr.md §3.3.
set -euo pipefail
export LC_ALL=C

: "${SEALED_KEYRING_VAULT:?}" "${AKS_RESOURCE_GROUP:?}" "${AKS_NAME:?}"
KV_SECRET=${SEALED_KEYRING_SECRET:-sealed-secrets-keyring}
LABEL=sealedsecrets.bitnami.com/sealed-secrets-key
P9_DIR=$(cd "$(dirname "$0")/.." && pwd)

log() { printf '%s [restore-sskey] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
fp() { openssl x509 -noout -fingerprint -sha256 | cut -d= -f2 | tr -d : | cut -c1-16; }

for b in az kubectl yq openssl gunzip base64; do
  command -v "$b" >/dev/null || die "falta $b"
done

umask 077
work=$(mktemp -d -p /dev/shm sskey.XXXXXX)
trap 'rm -rf -- "$work"' EXIT

# kubeconfig propio en RAM: jamás usa el contexto activo del operador
export KUBECONFIG="$work/kubeconfig"
az aks get-credentials -g "$AKS_RESOURCE_GROUP" -n "$AKS_NAME" --file "$KUBECONFIG" --only-show-errors
# [PUNTO DE INTEGRACIÓN CON TERRAFORM]: si AKS usa Entra ID sin cuentas locales, añadir:
#   kubelogin convert-kubeconfig -l azurecli --kubeconfig "$KUBECONFIG"
kubectl get --raw /readyz >/dev/null || die "la API de $AKS_NAME no responde"
log "inicio: vault=$SEALED_KEYRING_VAULT cluster=$AKS_NAME"

az keyvault secret show --vault-name "$SEALED_KEYRING_VAULT" --name "$KV_SECRET" --query value -o tsv \
  | base64 -d | gunzip > "$work/keyring.yaml" || die "no se pudo leer/decodificar $KV_SECRET"
[ "$(yq '.kind' "$work/keyring.yaml")" = List ] || die "keyring con formato inesperado"
n=$(yq '[.items[] | select(.metadata.namespace == "kube-system"
          and .metadata.labels["sealedsecrets.bitnami.com/sealed-secrets-key"] == "active"
          and .data["tls.key"] != null)] | length' "$work/keyring.yaml")
[ "$n" -ge 1 ] || die "el keyring no contiene llaves activas válidas"

# fallo temprano: el respaldo debe contener la llave del certificado versionado en Git
[ -f "$P9_DIR/gitops/sealed-secrets/pub-cert.pem" ] || die "falta $P9_DIR/gitops/sealed-secrets/pub-cert.pem (custodia inicial no ejecutada: P9/scripts/backup-sealed-secrets-key.sh)"
want=$(fp < "$P9_DIR/gitops/sealed-secrets/pub-cert.pem")
have=$(yq '.items[].data["tls.crt"]' "$work/keyring.yaml" | while read -r c; do printf '%s' "$c" | base64 -d | fp; done)
grep -qx "$want" <<<"$have" || die "el respaldo no contiene la llave de pub-cert.pem ($want)"
log "keyring válido: $n llave(s); huella esperada $want presente"

# server-side: sin anotación last-applied (no duplica la llave); sin etiquetas de tracking de ArgoCD
kubectl apply --server-side --field-manager=p9-dr-bootstrap -f "$work/keyring.yaml" >&2

expected=$(yq '.items[].metadata.name' "$work/keyring.yaml" | sort)
actual=$(kubectl -n kube-system get secret -l "$LABEL=active" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort)
extra=$(comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$actual"))
[ -z "$extra" ] || die "llaves activas NO respaldadas en el clúster: $extra (contingencia C2 del runbook)"

if kubectl -n kube-system get deploy sealed-secrets-controller >/dev/null 2>&1; then # solo en re-ejecuciones
  started=$(kubectl -n kube-system get pod -l app.kubernetes.io/name=sealed-secrets -o jsonpath='{.items[0].status.startTime}')
  newest=$(kubectl -n kube-system get secret -l "$LABEL=active" -o jsonpath='{range .items[*]}{.metadata.creationTimestamp}{"\n"}{end}' | sort | tail -1)
  if [[ "$started" < "$newest" ]]; then
    log "el controlador arrancó antes que la llave: reinicio para recargar el registro"
    kubectl -n kube-system rollout restart deploy/sealed-secrets-controller
    kubectl -n kube-system rollout status deploy/sealed-secrets-controller --timeout=180s
  fi
fi
log "fin: llaves activas en kube-system = $(tr '\n' ' ' <<<"$actual")"
