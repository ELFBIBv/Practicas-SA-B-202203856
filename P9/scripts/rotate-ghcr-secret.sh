#!/usr/bin/env bash
# Rota la credencial de GHCR que usan el pull de las imágenes privadas
# (imagePullSecrets en sa-p5) y la verificación de firmas de Kyverno
# (imageRegistryCredentials en kyverno): vuelve a sellar ghcr-secret para ambos
# namespaces con el certificado público versionado. Es offline, no necesita
# clúster. El token se lee de la terminal sin eco y nunca pasa por argv ni se
# escribe en disco; GHCR debe aceptarlo antes de sellarlo.
#
# Uso, desde la raíz del repositorio (PAT classic con solo read:packages):
#   ./P9/scripts/rotate-ghcr-secret.sh
# Después: revisar el diff, publicar con publish-gitops.sh y hacer merge en el
# repo GitOps; ArgoCD (app platform-secrets) aplica los nuevos SealedSecret.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_cmd curl jq kubectl kubeseal yq base64
cert="$P9_DIR/gitops/sealed-secrets/pub-cert.pem"
out_dir="$P9_DIR/gitops/platform-secrets"
probe_image="elfbibv/sa-auth-service"
[[ -f "$cert" ]] || die "No existe $cert."

read -rp "Usuario de GitHub [ELFBIBv]: " user || true
user="${user:-ELFBIBv}"
read -rsp "Token de GHCR (read:packages): " token || true
echo >&2
[[ -n "$token" ]] || die "Token vacío."

# curl -K -: la credencial va por stdin, no por argv.
code="$(curl -s -o /dev/null -w '%{http_code}' -K - <<EOF
user = "$user:$token"
url = "https://ghcr.io/token?scope=repository:$probe_image:pull&service=ghcr.io"
EOF
)"
[[ "$code" == 200 ]] || die "GHCR rechazó la credencial (HTTP $code): revise que el token tenga read:packages y no haya expirado."
log "GHCR acepta la credencial para $probe_image."

dockercfg="$(GHCR_USER="$user" GHCR_TOKEN="$token" GHCR_AUTH="$(printf '%s:%s' "$user" "$token" | base64 -w0)" \
  jq -cn '{auths: {"ghcr.io": {username: env.GHCR_USER, password: env.GHCR_TOKEN, auth: env.GHCR_AUTH}}}')"
unset token

for ns in sa-p5 kyverno; do
  out="$out_dir/$ns-ghcr-secret.sealed.yaml"
  tmp="$(mktemp "$out.XXXXXX")"
  DOCKERCFG="$dockercfg" NS="$ns" jq -cn '{apiVersion: "v1", kind: "Secret",
      metadata: {name: "ghcr-secret", namespace: env.NS},
      type: "kubernetes.io/dockerconfigjson",
      data: {".dockerconfigjson": (env.DOCKERCFG | @base64)}}' \
    | kubeseal --cert "$cert" --scope strict --format yaml \
    | yq 'del(.metadata.creationTimestamp, .spec.template.metadata.creationTimestamp)' >"$tmp"
  yq -e '.kind == "SealedSecret" and .spec.encryptedData[".dockerconfigjson"] != null' "$tmp" >/dev/null \
    || { rm -f "$tmp"; die "kubeseal no produjo un SealedSecret válido para $ns."; }
  mv "$tmp" "$out"
  log "Sellado: ${out#"$REPO_ROOT"/}"
done
unset dockercfg
log "Listo. Siguiente paso: git diff -- P9/gitops/platform-secrets/ y publicar en el repo GitOps."
