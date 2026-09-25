#!/usr/bin/env bash
# Pone el keyring de Sealed Secrets en custodia en Key Vault. Se ejecuta ANTES del desastre.
# Requiere rol "Key Vault Secrets Officer". Nunca imprime ni persiste material privado.
#
# Uso:
#   SEALED_KEYRING_VAULT=<vault> ./P9/scripts/backup-sealed-secrets-key.sh from-cluster <contexto-kubectl>
#   SEALED_KEYRING_VAULT=<vault> ./P9/scripts/backup-sealed-secrets-key.sh generate
#
# Diseño: P9/docs/diseno-secretos-dr.md §3.2.
set -euo pipefail
export LC_ALL=C

: "${SEALED_KEYRING_VAULT:?defina SEALED_KEYRING_VAULT (Key Vault de custodia)}"
KV_SECRET=${SEALED_KEYRING_SECRET:-sealed-secrets-keyring}
P9_DIR=$(cd "$(dirname "$0")/.." && pwd)

log() { printf '%s [backup-sskey] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
fp() { openssl x509 -noout -fingerprint -sha256 | cut -d= -f2 | tr -d : | cut -c1-16; }

for b in az kubectl kubeseal yq openssl gzip base64; do
  command -v "$b" >/dev/null || die "falta $b"
done

umask 077
work=$(mktemp -d -p /dev/shm sskey.XXXXXX)
trap 'rm -rf -- "$work"' EXIT # RAM, borrado al salir

case "${1:-}" in
  from-cluster)
    ctx=${2:?contexto kubectl del clúster cuya llave se respalda}
    # comando base pedido; se sanea: fuera uid/resourceVersion/managedFields/etiquetas de tracking
    kubectl --context "$ctx" -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml \
      | yq '{"apiVersion": "v1", "kind": "List", "items": [.items[] | {
          "apiVersion": "v1", "kind": "Secret", "type": .type,
          "metadata": {"name": .metadata.name, "namespace": "kube-system",
            "labels": {"sealedsecrets.bitnami.com/sealed-secrets-key": .metadata.labels["sealedsecrets.bitnami.com/sealed-secrets-key"]}},
          "data": {"tls.crt": .data["tls.crt"], "tls.key": .data["tls.key"]}}]}' > "$work/keyring.yaml"
    # certificado con el que sella HOY el controlador (el más reciente)
    kubeseal --context "$ctx" --controller-name sealed-secrets-controller --controller-namespace kube-system \
      --fetch-cert > "$work/pub-cert.pem"
    origin=$ctx
    ;;
  generate)
    [ -z "$(az keyvault secret list --vault-name "$SEALED_KEYRING_VAULT" --query "[?name=='$KV_SECRET'].name" -o tsv)" ] \
      || die "$KV_SECRET ya existe: 'generate' solo se usa en la génesis"
    openssl req -x509 -newkey rsa:4096 -sha256 -nodes -days 3650 -subj "/CN=sealed-secret/O=sealed-secret" \
      -keyout "$work/tls.key" -out "$work/pub-cert.pem" 2>/dev/null
    kubectl create secret tls "sealed-secrets-key-p9-$(date -u +%Y%m%d)" -n kube-system \
      --cert="$work/pub-cert.pem" --key="$work/tls.key" --dry-run=client -o yaml \
      | yq '.metadata = {"name": .metadata.name, "namespace": "kube-system",
                       "labels": {"sealedsecrets.bitnami.com/sealed-secrets-key": "active"}}
          | {"apiVersion": "v1", "kind": "List", "items": [.]}' > "$work/keyring.yaml"
    origin=generated
    ;;
  *) die "uso: $0 from-cluster <contexto> | generate" ;;
esac

n=$(yq '[.items[] | select(.data["tls.key"] != null and .data["tls.crt"] != null)] | length' "$work/keyring.yaml")
total=$(yq '.items | length' "$work/keyring.yaml")
if ! { [ "$n" -ge 1 ] && [ "$n" = "$total" ]; }; then die "keyring vacío o incompleto"; fi
fps=$(yq '.items[].data["tls.crt"]' "$work/keyring.yaml" | while read -r c; do printf '%s' "$c" | base64 -d | fp; done | paste -sd, -)
grep -q "$(fp < "$work/pub-cert.pem")" <<<"$fps" || die "el certificado de sellado no está en el keyring"

gzip -9 -c "$work/keyring.yaml" | base64 -w0 > "$work/keyring.b64"
[ "$(stat -c %s "$work/keyring.b64")" -le 24000 ] || die "keyring > 24 KB (límite de Key Vault: 25 KB)"
az keyvault secret set --vault-name "$SEALED_KEYRING_VAULT" --name "$KV_SECRET" \
  --file "$work/keyring.b64" --encoding utf-8 \
  --tags purpose=sealed-secrets-keyring format=yaml-list+gzip+base64 key-count="$n" \
  cert-sha256="$fps" origin="$origin" backed-up-at="$(date -u +%FT%TZ)" \
  -o none # imprescindible: 'secret set' devuelve el valor completo si no se suprime la salida
cp "$work/pub-cert.pem" "$P9_DIR/gitops/sealed-secrets/pub-cert.pem" # PÚBLICO, versionable
log "custodia OK: $n llave(s), cert-sha256=$fps"
