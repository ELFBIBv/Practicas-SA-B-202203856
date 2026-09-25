#!/usr/bin/env bash
# Auditoría previa a cada commit: no debe haber estado de Terraform, planes,
# variables reales ni credenciales en el índice de git (lo rastreado + lo
# preparado con `git add`). Sale con código 1 si encuentra algo.
#
# Uso, desde la raíz del repositorio:
#   ./P9/scripts/audit-repo.sh                # alcance: P9/ y .github/
#   ./P9/scripts/audit-repo.sh P9/terraform   # alcance explícito
#
# Como hook local (no versionado; opcional):
#   printf '#!/bin/sh\nexec ./P9/scripts/audit-repo.sh\n' > .git/hooks/pre-commit
#   chmod +x .git/hooks/pre-commit
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_cmd git
cd "$REPO_ROOT"
if (($# > 0)); then scope=("$@"); else scope=(P9 .github); fi

# Nombres de archivo prohibidos. `.terraform.lock.hcl` NO está aquí: se
# versiona a propósito (solo contiene versiones y hashes de providers).
forbidden_names='(^|/)(\.terraform/|[^/]*\.tfstate$|[^/]*\.tfstate\.[^/]*$|[^/]*\.tfplan$|tfplan$|[^/]*\.tfvars$|[^/]*\.tfvars\.json$|\.terraformrc$|terraform\.rc$|crash(\.[^/]*)?\.log$|\.terraform\.tfstate\.lock\.info$|[^/]*\.kubeconfig$|kubeconfig(\.ya?ml)?$|[^/]*\.pem$|[^/]*\.key$|[^/]*\.pfx$|\.env$|sealed-secrets-key[^/]*$)'

# Contenido prohibido en archivos rastreados o preparados.
forbidden_content='-----BEGIN [A-Z ]*PRIVATE KEY-----|client-key-data:|AccountKey=[A-Za-z0-9+/]{20,}|"lineage": *"[0-9a-f-]{36}"|(ARM_ACCESS_KEY|ARM_CLIENT_SECRET|AZURE_STORAGE_KEY)=[^ $"{]+|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{20,}'

failed=0

log "Alcance: ${scope[*]}"
# git no deja de rastrear un archivo por agregarlo después a .gitignore, así
# que este chequeo mira lo indexado sin importar el estado de ignore. Pero
# eso rechazaría también las excepciones deliberadas del propio .gitignore
# (P9/gitops/sealed-secrets/pub-cert.pem es pública a propósito: diseño de
# secretos §3.1 y §5 V-A6). `git check-ignore --no-index -q` consulta las
# reglas de .gitignore por patrón, negaciones incluidas, IGNORANDO si el
# archivo ya está en el índice. El `--no-index` es imprescindible: sin él,
# `check-ignore` reporta "no ignorado" para cualquier ruta ya rastreada —
# pub-cert.pem Y un .key forzado con `git add -f` por igual—, lo que
# apagaría este chequeo por completo (se probó y falló así antes de agregar
# la bandera). Con `--no-index`: si NO lo considera ignorado (nunca hizo
# match, o hizo match con una regla `!`), se excluye de la lista; si hizo
# match con una regla normal (sin negar) y aun así está rastreado, es
# justamente el caso que se quiere atrapar (alguien forzó `git add -f`), así
# que sigue marcándose. Mismo criterio que ya usa el chequeo "SIN IGNORAR"
# de abajo (git ls-files --others --exclude-standard), una sola fuente de
# verdad en vez de duplicar la lista de excepciones aquí.
names=""
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  git check-ignore --no-index -q "$f" || continue
  names+="$f"$'\n'
done < <(git ls-files --cached -- "${scope[@]}" | grep -E "$forbidden_names" || true)
names="${names%$'\n'}"
if [[ -n "$names" ]]; then
  printf '%s\n' "$names" | sed 's/^/  RASTREADO: /' >&2
  warn "Archivos prohibidos en el índice de git. Quítelos con: git rm --cached <archivo>"
  failed=1
else
  log "OK: ningún archivo de estado, plan, tfvars, kubeconfig o llave rastreado."
fi

# Se excluye este mismo script (contiene los patrones como texto).
content="$(git grep --cached -I -n -E -e "$forbidden_content" -- "${scope[@]}" \
  ':(exclude)P9/scripts/audit-repo.sh' || true)"
if [[ -n "$content" ]]; then
  # Solo ruta:línea; nunca imprimir el valor encontrado.
  printf '%s\n' "$content" | cut -d: -f1,2 | sed 's/^/  CONTENIDO SENSIBLE: /' >&2
  warn "Posibles secretos o estado de Terraform dentro de archivos rastreados."
  failed=1
else
  log "OK: sin llaves privadas, access keys, tokens ni contenido de tfstate en archivos rastreados."
fi

# No bloquea, pero avisa de lo que entraría con un `git add -A` descuidado.
untracked="$(git ls-files --others --exclude-standard -- "${scope[@]}" | grep -E "$forbidden_names" || true)"
if [[ -n "$untracked" ]]; then
  printf '%s\n' "$untracked" | sed 's/^/  SIN IGNORAR: /' >&2
  warn "Archivos sensibles sin rastrear y NO cubiertos por .gitignore; agréguelos al .gitignore."
fi

if ((failed)); then die "Auditoría fallida."; fi
log "Auditoría superada."
