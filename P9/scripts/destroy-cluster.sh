#!/usr/bin/env bash
# Destruye SOLO el clúster (etapa 01-cluster: RG rg-p9-aks, AKS y su RG de
# nodos) para la prueba cronometrada de DR. No toca el backend de estado, el
# Key Vault de custodia ni el almacenamiento de Velero: ninguno está en el
# estado de 01-cluster.
#
# Uso, desde la raíz del repositorio (operación IRREVERSIBLE):
#   ./P9/scripts/destroy-cluster.sh --confirm aks-sa-p9
#
# No se destruye 02-platform: sus recursos viven dentro del clúster y
# desaparecen con él. Su estado queda desactualizado a propósito. En la
# siguiente reconstrucción, Terraform refresca contra el clúster nuevo, ve
# que las releases y el namespace no existen y los vuelve a crear. Es el
# mismo camino que un desastre real no planificado.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/p9-config.sh
source "$SCRIPT_DIR/lib/p9-config.sh"
# shellcheck source=lib/tfstate-backend.sh
source "$SCRIPT_DIR/lib/tfstate-backend.sh"

export TF_IN_AUTOMATION=1 TF_INPUT=0
trap 'die "Falló la línea $LINENO: $BASH_COMMAND"' ERR

[[ "${1:-}" == --confirm && "${2:-}" == "$P9_CLUSTER_NAME" ]] ||
  die "Operación irreversible. Confirme con: $0 --confirm $P9_CLUSTER_NAME"

require_cmd az terraform
PLAN_DIR="$(mktemp -d)"
trap 'rm -rf "$PLAN_DIR"' EXIT

tfstate_load_config
tfstate_backend_exists || die "No existe el backend de estado: no hay nada que destruir con Terraform."
tfstate_resolve_auth
tfstate_build_backend_args "$(tf_stack_key 01-cluster)"
dir="$(tf_stack_dir 01-cluster)"
tfstate_terraform_init "$dir" >/dev/null

terraform -chdir="$dir" plan -destroy -input=false -lock-timeout=120s -out="$PLAN_DIR/destroy.tfplan"
log "DESASTRE_INICIO=$(ts) (destruyendo $P9_RESOURCE_GROUP/$P9_CLUSTER_NAME)"
terraform -chdir="$dir" apply -input=false -lock-timeout=120s "$PLAN_DIR/destroy.tfplan"
log "DESASTRE_FIN=$(ts)"

if azs group exists -n "$P9_RESOURCE_GROUP" -o tsv | grep -q true; then
  die "El resource group $P9_RESOURCE_GROUP sigue existiendo tras el destroy."
fi
tfstate_backend_exists || die "El backend de estado desapareció: revise de inmediato."
log "Clúster destruido. El backend $TFSTATE_STORAGE_ACCOUNT/$TFSTATE_CONTAINER sigue disponible."
rm -f "$P9_KUBECONFIG"
