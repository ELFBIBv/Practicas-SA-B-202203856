#!/usr/bin/env bash
# Copia a un clon local del repositorio GitOps lo que ArgoCD debe leer:
#   P9/gitops/apps/             -> apps/               (hijas de la raíz p9-root)
#   P9/gitops/platform/         -> platform/            (data-restore, verify, velero-schedules)
#   P9/gitops/platform-secrets/ -> platform-secrets/    (app platform-secrets)
#   P9/kyverno/policies/        -> policies/kyverno/    (app kyverno-policies)
#   P9/charts/sa-platform/      -> charts/sa-platform/  (app sa-platform)
# No hace commit ni push: deja el diff listo para revisar y abrir un PR.
#
# Uso, desde la raíz del repositorio:
#   git clone https://github.com/ELFBIBv/Practicas-SA-B-202203856-gitops.git /tmp/gitops
#   ./P9/scripts/publish-gitops.sh /tmp/gitops
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

target="${1:?Uso: $0 <ruta-al-clon-del-repo-gitops>}"
require_cmd git rsync yq
[[ -d "$target/.git" ]] || die "$target no es un clon de git."
url="$(git -C "$target" remote get-url origin)"
[[ "$url" == *Practicas-SA-B-202203856-gitops* ]] || die "$target apunta a $url, no al repo GitOps."

# V-S3 (P9/docs/diseno-sync-waves.md §6.1): ninguna Application hija puede
# administrarse a sí misma, ser p9-root, tener finalizers, salirse del
# proyecto p9-platform o faltarle la anotación de ola. Se corre ANTES del
# rsync para no publicar un ciclo de administración.
fail=0
for f in "$P9_DIR"/gitops/apps/*.yaml; do
  yq -e '.kind == "Application" and .metadata.name != "p9-root" and .spec.project == "p9-platform"
    and .metadata.finalizers == null and .metadata.annotations["argocd.argoproj.io/sync-wave"] != null' \
    "$f" >/dev/null || { warn "V-S3 FALLA: $f"; fail=1; }
done
((fail == 0)) || die "V-S3 no pasó: revise las Applications marcadas arriba antes de publicar."
log "V-S3 OK: todas las Applications de $P9_DIR/gitops/apps cumplen el contrato anti-ciclo."

# --mkpath: en un clon fresco del repo GitOps ninguno de estos directorios
# destino existe todavía (rsync no crea padres por su cuenta y falla con
# "mkdir ... failed: No such file or directory"). Requiere rsync >= 3.2.3.
rsync -a --mkpath --delete "$P9_DIR/gitops/apps/" "$target/apps/"
rsync -a --mkpath --delete "$P9_DIR/gitops/platform/" "$target/platform/"
rsync -a --mkpath --delete "$P9_DIR/gitops/platform-secrets/" "$target/platform-secrets/"
rsync -a --mkpath --delete "$P9_DIR/kyverno/policies/" "$target/policies/kyverno/"
rsync -a --mkpath --delete --exclude 'charts/*.tgz' --exclude 'charts/nats/' --exclude 'charts/redis/' "$P9_DIR/charts/sa-platform/" "$target/charts/sa-platform/"

if [[ -f "$target/argocd/application.yaml" ]]; then
  warn "Existe argocd/application.yaml (Application sa-platform de P8). Ahora la administra la raíz" \
    "desde apps/sa-platform.yaml; bórrela en el mismo PR para que no haya dos dueños:" \
    "git -C $target rm argocd/application.yaml"
fi
git -C "$target" status --short
log "Revise el diff, haga commit en una rama y abra un PR contra main del repo GitOps."
