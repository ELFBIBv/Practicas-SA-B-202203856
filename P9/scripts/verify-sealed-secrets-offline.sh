#!/usr/bin/env bash
# Verifica sin conexión a ningún clúster que el keyring custodiado en Key Vault
# descifra exactamente lo que ArgoCD va a aplicar: los SealedSecret del chart
# sa-platform y los de P9/gitops/platform-secrets/*.sealed.yaml. Es V-A4 del
# diseño de secretos: demuestra la custodia sin necesidad de un clúster vivo.
#
# Uso: SEALED_KEYRING_VAULT=<vault> ./P9/scripts/verify-sealed-secrets-offline.sh
# Salida: una línea "OK <ns>/<nombre> keys=<claves>" por cada SealedSecret que
# descifra correctamente. Exit 0 solo si TODOS descifran; exit 1 si alguno falla
# (se imprime "FALLA <ns>/<nombre>" para ese caso).
#
# Diseño: P9/docs/diseno-secretos-dr.md §3.2 (V-A4) y §5.
set -euo pipefail
export LC_ALL=C

: "${SEALED_KEYRING_VAULT:?defina SEALED_KEYRING_VAULT (Key Vault de custodia)}"
KV_SECRET=${SEALED_KEYRING_SECRET:-sealed-secrets-keyring}
P9_DIR=$(cd "$(dirname "$0")/.." && pwd)
CHART_DIR="$P9_DIR/charts/sa-platform"
VALUES_FILE="$CHART_DIR/values-azure.yaml"
PLATFORM_SECRETS_DIR="$P9_DIR/gitops/platform-secrets"
NAMESPACE=${SEALED_SECRETS_NAMESPACE:-sa-p5}

log() { printf '%s [verify-sskey-offline] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

for b in az helm kubeseal yq openssl gunzip base64; do
  command -v "$b" >/dev/null || die "falta $b"
done
[ -d "$CHART_DIR" ] || die "no existe $CHART_DIR"
[ -f "$VALUES_FILE" ] || die "no existe $VALUES_FILE"

umask 077
work=$(mktemp -d -p /dev/shm sskey-verify.XXXXXX)
trap 'rm -rf -- "$work"' EXIT

log "inicio: vault=$SEALED_KEYRING_VAULT chart=$CHART_DIR values=$VALUES_FILE"

helm dependency build "$CHART_DIR" >/dev/null

{
  helm template sa-platform "$CHART_DIR" -n "$NAMESPACE" -f "$VALUES_FILE" \
    --show-only templates/sealed-secrets.yaml
  shopt -s nullglob
  sealed_files=("$PLATFORM_SECRETS_DIR"/*.sealed.yaml)
  shopt -u nullglob
  if [ "${#sealed_files[@]}" -eq 0 ]; then
    log "sin manifiestos en $PLATFORM_SECRETS_DIR (*.sealed.yaml): pendiente de sellar y publicar (decisión abierta 2.2)"
  fi
  for f in "${sealed_files[@]}"; do
    printf -- '---\n'
    cat "$f"
  done
} > "$work/sealed.yaml"

az keyvault secret show --vault-name "$SEALED_KEYRING_VAULT" --name "$KV_SECRET" --query value -o tsv \
  | base64 -d | gunzip > "$work/keyring.yaml" || die "no se pudo leer/decodificar $KV_SECRET"
[ "$(yq '.kind' "$work/keyring.yaml")" = List ] || die "keyring con formato inesperado"

n_keys=$(yq '.items | length' "$work/keyring.yaml")
[ "$n_keys" -ge 1 ] || die "el keyring no contiene llaves"
keys=""
for i in $(seq 0 $((n_keys - 1))); do
  yq ".items[$i].data[\"tls.key\"]" "$work/keyring.yaml" | base64 -d > "$work/k$i.pem"
  keys="${keys:+$keys,}$work/k$i.pem"
done

n_secrets=$(yq ea -N '[select(.kind=="SealedSecret")] | length' "$work/sealed.yaml")
[ "$n_secrets" -ge 1 ] || die "sin SealedSecret que verificar en $work/sealed.yaml"

rc=0
# yq (sin "ea"/eval-all) evalúa la expresión una vez POR DOCUMENTO del stream
# separado por "---", que es justo lo que hace falta aquí. Con "ea" (eval-all)
# el `+` de concatenación se evalúa contra TODO el stream fusionado: si
# select() deja varios documentos, ".namespace" y ".name" dejan de estar
# apareados por documento y "+" los cruza (cada namespace con cada nombre),
# generando un producto cartesiano de ids que no existen y multiplicando cada
# ciphertext real varias veces en la salida. `sort -u` es una segunda defensa
# explícita por si el propio sealed.yaml llegara a tener un documento
# duplicado (dos archivos *.sealed.yaml para el mismo ns/nombre).
for id in $(yq -N 'select(.kind=="SealedSecret") | .metadata.namespace + "/" + .metadata.name' "$work/sealed.yaml" | sort -u); do
  ns=${id%/*}
  nm=${id#*/}
  if out=$(NS=$ns NM=$nm yq ea -N 'select(.kind=="SealedSecret" and .metadata.namespace==strenv(NS) and .metadata.name==strenv(NM))' "$work/sealed.yaml" \
    | kubeseal --recovery-unseal --recovery-private-key "$keys" 2>"$work/err.log" \
    | yq '.data | keys | join(",")'); then
    echo "OK    $id keys=$out"
  else
    echo "FALLA $id"
    rc=1
  fi
done

log "fin: $n_secrets SealedSecret verificados con $n_keys llave(s) del keyring, rc=$rc"
exit $rc
