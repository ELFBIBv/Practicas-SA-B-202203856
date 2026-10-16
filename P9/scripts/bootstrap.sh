#!/usr/bin/env bash
# Punto de entrada único de la reconstrucción de P9 (día cero o post-desastre).
#
# Uso, desde la raíz del repositorio:
#   ./P9/scripts/bootstrap.sh            # reconstrucción completa (= all)
#   ./P9/scripts/bootstrap.sh backend    # asegura backend remoto + terraform init
#   ./P9/scripts/bootstrap.sh plan       # backend + plan de cada etapa (no aplica nada)
#   ./P9/scripts/bootstrap.sh verify     # solo las verificaciones finales (etapas 7-11)
#   make -C P9 bootstrap                 # equivalente a "all", con log crudo en evidencia/
#
# Prerrequisitos: terraform >= 1.9, az, kubectl, curl, git, jq, yq, openssl y
# una sesión `az login` con rol Owner (o Contributor + User Access
# Administrator) sobre la suscripción destino: Terraform crea asignaciones de
# rol (Key Vault, Velero, IP del clúster).
# Variables de entorno opcionales: ver `--help`.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/p9-config.sh
source "$SCRIPT_DIR/lib/p9-config.sh"
# shellcheck source=lib/tfstate-backend.sh
source "$SCRIPT_DIR/lib/tfstate-backend.sh"
# shellcheck source=lib/cluster-checks.sh
source "$SCRIPT_DIR/lib/cluster-checks.sh"

TF_MIN_VERSION="1.9.0"
# Cuánto espera Terraform si otro operador tiene tomado el lock del estado
# antes de fallar. Acotado a propósito: una segunda corrida debe esperar a la
# primera o fallar con un mensaje claro, nunca pisarla.
TF_LOCK_TIMEOUT="${TF_LOCK_TIMEOUT:-120s}"
export TF_IN_AUTOMATION=1 TF_INPUT=0

trap 'die "Falló la línea $LINENO: $BASH_COMMAND"' ERR

usage() {
  cat <<'USAGE'
Uso: ./P9/scripts/bootstrap.sh [all|backend|plan|verify]

  all      Reconstrucción completa (por defecto): backend, 00-persistent
           (Velero), 01-cluster, llave de Sealed Secrets, 02-platform (ArgoCD
           + app-of-apps + Velero) y verificaciones.
  backend  Asegura el backend remoto del estado y ejecuta terraform init en cada etapa.
  plan     backend + terraform plan de cada etapa. No modifica infraestructura.
           02-platform solo se planifica si el clúster ya existe.
  verify   Solo verificaciones (ArgoCD, Applications, controladores, workloads,
           endpoint) contra el clúster existente.

Variables de entorno (todas opcionales; los valores por defecto son deterministas):
  ARM_SUBSCRIPTION_ID      Suscripción destino. Por defecto: la activa en `az account show`.
  P9_LOCATION              Región del clúster (chilecentral).
  P9_RESOURCE_GROUP        RG del clúster, desechable (rg-p9-aks).
  P9_CLUSTER_NAME          Nombre del AKS (aks-sa-p9).
  P9_KUBECONFIG            kubeconfig propio de P9 (~/.kube/p9-<cluster>.config).
  SEALED_KEYRING_VAULT     Key Vault con la llave de Sealed Secrets (kv-sa-p9-202203856).
  TFSTATE_RESOURCE_GROUP   RG del backend (rg-p9-tfstate). Distinto del RG del clúster.
  TFSTATE_LOCATION         Región del backend (chilecentral).
  TFSTATE_STORAGE_ACCOUNT  Cuenta del backend (stp9tf + hash de la suscripción).
  TFSTATE_CONTAINER        Contenedor (tfstate). Keys: p9/<etapa>.tfstate.
  TFSTATE_SKU              SKU de la cuenta (Standard_LRS).
  TFSTATE_AUTH             auto | azuread | key (auto).
  TF_LOCK_TIMEOUT          Espera máxima por el lock del estado (120s).
  TF_VAR_bootstrap_object_id  Object ID de quien reconstruye (por defecto: la sesión az).
  TF_VAR_custodian_object_id  Object ID del custodio de la llave (por defecto: el que
                              ya tiene Secrets Officer en el vault; si no existe, la sesión az).
USAGE
}

preflight() {
  local cmd=$1
  require_cmd az terraform git
  [[ "$cmd" == all || "$cmd" == verify ]] && require_cmd kubectl curl jq yq openssl gunzip

  local tf_version
  tf_version="$(terraform version | head -n1 | sed -E 's/^Terraform v//')"
  version_ge "$tf_version" "$TF_MIN_VERSION" ||
    die "Terraform $tf_version < $TF_MIN_VERSION requerido."
  log "Terraform $tf_version, $(az version --query '"azure-cli"' -o tsv 2>/dev/null | sed 's/^/azure-cli /')."

  az account show -o none --only-show-errors 2>/dev/null ||
    die "No hay sesión de Azure CLI. Ejecute 'az login' antes del bootstrap."
}

PLAN_DIR=""
cleanup() { if [[ -n "$PLAN_DIR" ]]; then rm -rf "$PLAN_DIR"; fi; }
trap cleanup EXIT

stage_backend() {
  stage "1. Backend remoto del estado de Terraform"
  tfstate_load_config
  tfstate_ensure_backend
  tfstate_resolve_auth
  resolve_identity_vars
}

# 00-persistent necesita los object ID de Entra ID del custodio de la llave y
# de quien ejecuta la reconstrucción (roles del Key Vault). No son secretos,
# pero sin ellos el plan falla con TF_INPUT=0: se derivan de la sesión `az`
# para que un operador en una máquina limpia no tenga que escribir un tfvars.
# El custodio se conserva del Key Vault existente: si otro operador
# reconstruye, Terraform no le quita el rol Secrets Officer al custodio real.
resolve_identity_vars() {
  local me="" kv_id="" custodian=""
  if [[ "$(azs account show --query user.type -o tsv)" == servicePrincipal ]]; then
    me="$(az ad sp show --id "$(azs account show --query user.name -o tsv)" --query id -o tsv --only-show-errors)"
  else
    me="$(az ad signed-in-user show --query id -o tsv --only-show-errors)"
  fi
  [[ -n "$me" ]] || die "No se pudo resolver el object ID de la sesión de Azure CLI (az ad signed-in-user show)."
  export TF_VAR_bootstrap_object_id="${TF_VAR_bootstrap_object_id:-$me}"
  if [[ -z "${TF_VAR_custodian_object_id:-}" ]]; then
    kv_id="$(azs keyvault show -n "$SEALED_KEYRING_VAULT" --query id -o tsv 2>/dev/null || true)"
    if [[ -n "$kv_id" ]]; then
      custodian="$(azs role assignment list --scope "$kv_id" --role "Key Vault Secrets Officer" \
        --query '[0].principalId' -o tsv 2>/dev/null || true)"
    fi
    export TF_VAR_custodian_object_id="${custodian:-$me}"
  fi
  log "Identidades del Key Vault: operador=$(mask "$TF_VAR_bootstrap_object_id") custodio=$(mask "$TF_VAR_custodian_object_id")" \
    "$([[ -n "$custodian" ]] && echo '(custodio conservado del vault existente)' || echo '')"
}


tf_init() {
  local stack=$1 dir n
  dir="$(tf_stack_dir "$stack")"
  tfstate_build_backend_args "$(tf_stack_key "$stack")"
  tfstate_terraform_init "$dir"
  n="$(terraform -chdir="$dir" state list | wc -l | tr -d ' ')"
  log "[$stack] estado remoto accesible: $n recursos en $TFSTATE_KEY."
}

tf_plan() {
  local stack=$1 rc=0
  # El plan binario puede contener valores sensibles: se guarda fuera del
  # repositorio y se borra al salir.
  [[ -n "$PLAN_DIR" ]] || PLAN_DIR="$(mktemp -d)"
  terraform -chdir="$(tf_stack_dir "$stack")" plan -input=false -lock-timeout="$TF_LOCK_TIMEOUT" \
    -detailed-exitcode -out="$PLAN_DIR/$stack.tfplan" || rc=$?
  case $rc in
    0) log "[$stack] plan sin cambios: la infraestructura ya converge con el código." ;;
    2) log "[$stack] plan con cambios (se aplicará exactamente este plan)." ;;
    *) die "[$stack] terraform plan falló (código $rc)." ;;
  esac
}

tf_apply() {
  local stack=$1
  # Aplicar el plan guardado: si otro operador cambió el estado entre plan y
  # apply, Terraform rechaza el plan como obsoleto en vez de pisar el cambio.
  terraform -chdir="$(tf_stack_dir "$stack")" apply -input=false \
    -lock-timeout="$TF_LOCK_TIMEOUT" "$PLAN_DIR/$stack.tfplan"
}

cluster_exists() {
  azs aks show -g "$P9_RESOURCE_GROUP" -n "$P9_CLUSTER_NAME" -o none >/dev/null 2>&1
}

# [PUNTO DE INTEGRACIÓN CON SECRETOS]
# La llave de Sealed Secrets se reinyecta con la API de AKS ya disponible y
# ANTES de instalar ArgoCD (02-platform). Así el controlador arranca con la
# llave custodiada y nunca genera una propia. Script y contrato:
# P9/docs/diseño-secretos-dr.md §3.3.
stage_sealed_key() {
  stage "5. Continuidad de secretos: llave de Sealed Secrets"
  local script="$SCRIPT_DIR/restore-sealed-secrets-key.sh"
  if [[ -x "$script" ]]; then
    SEALED_KEYRING_VAULT="$SEALED_KEYRING_VAULT" AKS_RESOURCE_GROUP="$P9_RESOURCE_GROUP" \
      AKS_NAME="$P9_CLUSTER_NAME" "$script"
  elif [[ "${P9_ALLOW_NEW_SEALED_KEY:-}" == 1 ]]; then
    warn "P9_ALLOW_NEW_SEALED_KEY=1: NO se restaura la llave. El controlador generará una nueva," \
      "los SealedSecret actuales no se descifrarán y esta corrida NO sirve como evidencia de DR (rúbrica 2.4)."
  else
    die "PENDIENTE: falta $script (diseño de secretos). Sin él, el controlador generaría una llave" \
      "nueva y los SealedSecret no se descifrarían. Para probar solo la infraestructura exporte" \
      "P9_ALLOW_NEW_SEALED_KEY=1 (corrida no válida como evidencia)."
  fi
}

stage_verify() {
  stage "7. ArgoCD disponible y Lua de health cargado"
  wait_argocd
  stage "8. Olas del app-of-apps y raíz $P9_ROOT_APP Synced/Healthy"
  wait_waves
  stage "9. [VELERO] Resultado de la restauración de datos"
  local restore_log
  restore_log="$(kubectl -n velero logs job/p9-data-restore 2>/dev/null || true)"
  if grep -qE 'RESTORE_OK|IDEMPOTENTE|GENESIS' <<<"$restore_log"; then
    grep -E 'RESTORE_OK|IDEMPOTENTE|GENESIS' <<<"$restore_log" | while IFS= read -r line; do log "data-restore: $line"; done
  else
    die "El log de job/p9-data-restore no contiene RESTORE_OK, IDEMPOTENTE ni GENESIS (P9/docs/diseno-sync-waves.md §5, paso 9)."
  fi
  stage "10. Controladores (Sealed Secrets, Argo Rollouts, Kyverno, Velero) y políticas en Enforce"
  wait_controllers
  stage "11. Workloads de $P9_APP_NAMESPACE"
  wait_workloads
  stage "12. Endpoint funcional"
  local ip
  ip="$(wait_endpoint)"
  log "Gateway respondiendo en http://$ip"
}

main() {
  local cmd="${1:-all}"
  case "$cmd" in
    -h | --help)
      usage
      return 0
      ;;
    all | backend | plan | verify) ;;
    *)
      usage >&2
      die "Subcomando desconocido: $cmd"
      ;;
  esac

  # RTO: desde que el operador lanza el comando hasta que el endpoint
  # responde. Ver definición en P9/docs/terraform-dia-cero.md.
  local started started_iso
  started="$(date -u +%s)"
  started_iso="$(ts)"
  log "Bootstrap P9 '$cmd' iniciado (commit $(git -C "$REPO_ROOT" rev-parse --short HEAD)). RTO_INICIO=$started_iso"
  preflight "$cmd"

  if [[ "$cmd" == verify ]]; then
    tfstate_load_config
    cluster_credentials
    stage_verify
    log "Verificación terminada en $(($(date -u +%s) - started))s."
    return 0
  fi

  stage_backend

  # [PUNTO DE INTEGRACIÓN CON VELERO] Capa persistente de Velero (storage
  # account + UAMI): SOBREVIVE al clúster, por eso corre ANTES de 01-cluster,
  # igual que el backend de Terraform. A diferencia del backend, esta etapa SÍ
  # es Terraform (usa el backend remoto que la etapa 1 ya aseguró): no hay
  # problema de huevo-y-gallina. La federated identity credential NO va aquí
  # (necesita el emisor OIDC del clúster, que todavía no existe): vive en
  # 02-platform/modules/velero, después del apply de 01-cluster.
  # Ver P9/docs/diseno-velero.md §1, §2.
  stage "2. Etapa 00-persistent (Velero: storage account + UAMI)"
  tf_init 00-persistent
  [[ "$cmd" == backend ]] || tf_plan 00-persistent

  stage "3. Etapa 01-cluster (resource group + AKS)"
  tf_init 01-cluster
  [[ "$cmd" == backend ]] || tf_plan 01-cluster

  if [[ "$cmd" == all ]]; then
    tf_apply 00-persistent
    tf_apply 01-cluster
    stage "4. Credenciales del clúster y nodos Ready"
    cluster_credentials
    wait_nodes_ready
    stage_sealed_key
  fi

  stage "6. Etapa 02-platform (tenant + ArgoCD + app-of-apps + Velero)"
  tf_init 02-platform
  if [[ "$cmd" == plan ]]; then
    if cluster_exists; then
      tf_plan 02-platform
    else
      log "[02-platform] no se planifica: el clúster aún no existe (lo crea el apply de 01-cluster)."
    fi
  elif [[ "$cmd" == all ]]; then
    tf_plan 02-platform
    tf_apply 02-platform
    stage_verify
    local finished_iso
    finished_iso="$(ts)"
    log "RTO_INICIO=$started_iso RTO_FIN=$finished_iso RTO_SEGUNDOS=$(($(date -u +%s) - started))"
  fi
  log "Bootstrap '$cmd' terminado en $(($(date -u +%s) - started))s."
}

main "$@"
