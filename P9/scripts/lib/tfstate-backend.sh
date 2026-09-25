#!/usr/bin/env bash
# Backend remoto de Terraform en Azure Storage: resolución del "huevo y la
# gallina" (el backend tiene que existir antes de `terraform init`, pero no
# puede crearlo el mismo Terraform que guarda su estado en él).
#
# Decisión (ver P9/docs/terraform-backend.md): el backend NO es un recurso de
# Terraform. Lo asegura este script con Azure CLI, con operaciones
# "comprobar y luego crear" que son idempotentes. Vive en un resource group
# propio, separado del dominio de fallo del clúster, y ningún `terraform destroy`
# de P9 puede borrarlo porque no está en ningún estado de Terraform.
#
# Se carga con `source` desde bootstrap.sh y verify-tfstate-lock.sh; requiere
# lib/common.sh.

[[ -n "${_P9_TFSTATE_BACKEND_SH:-}" ]] && return 0
_P9_TFSTATE_BACKEND_SH=1

# az contra la suscripción resuelta, sin cambiar la suscripción por defecto
# del operador (`az account set` alteraría sus otras terminales).
azs() { az "$@" --subscription "$AZ_SUBSCRIPTION_ID" --only-show-errors; }

_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi
}

# Resuelve y valida la configuración. Todas las variables admiten override por
# entorno; los valores por defecto son deterministas, de modo que tras un
# desastre el operador no necesita recordar ningún nombre.
tfstate_load_config() {
  if [[ -z "${ARM_SUBSCRIPTION_ID:-}" ]]; then
    ARM_SUBSCRIPTION_ID="$(az account show --query id -o tsv --only-show-errors)" ||
      die "No hay sesión de Azure CLI. Ejecute 'az login' (y 'az account set --subscription <id>' si tiene varias)."
  fi
  [[ "$ARM_SUBSCRIPTION_ID" =~ ^[0-9a-fA-F-]{36}$ ]] ||
    die "ARM_SUBSCRIPTION_ID no es un GUID válido."
  AZ_SUBSCRIPTION_ID="$ARM_SUBSCRIPTION_ID"
  # El provider azurerm (y el backend) toman la suscripción de aquí.
  export ARM_SUBSCRIPTION_ID

  TFSTATE_RESOURCE_GROUP="${TFSTATE_RESOURCE_GROUP:-rg-p9-tfstate}"
  TFSTATE_LOCATION="${TFSTATE_LOCATION:-chilecentral}"
  TFSTATE_CONTAINER="${TFSTATE_CONTAINER:-tfstate}"
  TFSTATE_SKU="${TFSTATE_SKU:-Standard_LRS}"
  TFSTATE_AUTH="${TFSTATE_AUTH:-auto}"
  TFSTATE_RETENTION_DAYS="${TFSTATE_RETENTION_DAYS:-30}"
  # Nombre global único y estable: prefijo + hash de la suscripción. Mismo
  # valor en cada corrida y tras perder la máquina del operador; no revela el
  # ID de la suscripción.
  if [[ -z "${TFSTATE_STORAGE_ACCOUNT:-}" ]]; then
    TFSTATE_STORAGE_ACCOUNT="stp9tf$(printf '%s' "${AZ_SUBSCRIPTION_ID,,}" | _sha256 | cut -c1-12)"
  fi

  [[ "$TFSTATE_STORAGE_ACCOUNT" =~ ^[a-z0-9]{3,24}$ ]] ||
    die "TFSTATE_STORAGE_ACCOUNT='$TFSTATE_STORAGE_ACCOUNT' inválido: 3-24 caracteres [a-z0-9]."
  [[ "$TFSTATE_CONTAINER" =~ ^[a-z0-9]([a-z0-9-]{1,61})[a-z0-9]$ ]] ||
    die "TFSTATE_CONTAINER='$TFSTATE_CONTAINER' inválido."
  case "$TFSTATE_AUTH" in
    auto | azuread | key) ;;
    *) die "TFSTATE_AUTH debe ser auto, azuread o key (recibido: '$TFSTATE_AUTH')." ;;
  esac

  log "Backend de estado: suscripción=$(mask "$AZ_SUBSCRIPTION_ID") rg=$TFSTATE_RESOURCE_GROUP" \
    "cuenta=$TFSTATE_STORAGE_ACCOUNT contenedor=$TFSTATE_CONTAINER" \
    "región=$TFSTATE_LOCATION auth=$TFSTATE_AUTH"
}

_tfstate_sa_exists() {
  azs storage account show -n "$TFSTATE_STORAGE_ACCOUNT" -g "$TFSTATE_RESOURCE_GROUP" \
    --query id -o tsv >/dev/null 2>&1
}

_tfstate_container_exists() {
  [[ "$(azs storage container-rm exists --storage-account "$TFSTATE_STORAGE_ACCOUNT" \
    -g "$TFSTATE_RESOURCE_GROUP" -n "$TFSTATE_CONTAINER" --query exists -o tsv 2>/dev/null)" == true ]]
}

# Verdadero si el backend completo ya existe; lo usa verify-tfstate-lock.sh
# para no crear nada desde un script de verificación.
tfstate_backend_exists() {
  [[ "$(azs group exists -n "$TFSTATE_RESOURCE_GROUP" -o tsv)" == true ]] &&
    _tfstate_sa_exists && _tfstate_container_exists
}

# Microsoft.Storage: backend del estado y storage account de Velero
# (00-persistent). Microsoft.KeyVault: vault de custodia de la llave de
# Sealed Secrets (00-persistent, P9/docs/diseno-velero.md §2.2). Sin este
# registro, el primer `apply` de 00-persistent falla con 409
# MissingSubscriptionRegistration (visto en la corrida real del 2026-09-24).
# Idempotente: si ya está Registered no se toca; registrar un proveedor ya
# registrado tampoco falla, así que una segunda corrida es segura de todas formas.
_tfstate_ensure_provider() {
  local ns state
  for ns in Microsoft.Storage Microsoft.KeyVault; do
    state="$(azs provider show -n "$ns" --query registrationState -o tsv)"
    if [[ "$state" == Registered ]]; then
      log "Proveedor $ns: ya registrado."
    else
      log "Proveedor $ns en estado '$state'; registrando (espera hasta completar)..."
      azs provider register -n "$ns" --wait -o none
    fi
  done
}

_tfstate_ensure_group() {
  if [[ "$(azs group exists -n "$TFSTATE_RESOURCE_GROUP" -o tsv)" == true ]]; then
    log "Resource group $TFSTATE_RESOURCE_GROUP: ya existe (no se modifica)."
    return
  fi
  log "Creando resource group $TFSTATE_RESOURCE_GROUP en $TFSTATE_LOCATION..."
  # PUT idempotente en ARM: si otro operador lo creó en paralelo, no falla.
  retry 3 10 azs group create -n "$TFSTATE_RESOURCE_GROUP" -l "$TFSTATE_LOCATION" \
    --tags practica=p9 proposito=terraform-state administrado-por=bootstrap.sh -o none
}

_tfstate_ensure_account() {
  if _tfstate_sa_exists; then
    log "Storage account $TFSTATE_STORAGE_ACCOUNT: ya existe (no se recrea)."
    return
  fi

  local available
  available="$(azs storage account check-name -n "$TFSTATE_STORAGE_ACCOUNT" --query nameAvailable -o tsv)"
  if [[ "$available" != true ]]; then
    # Otra corrida concurrente pudo crearla entre el `show` y el `check-name`.
    _tfstate_sa_exists && {
      log "Storage account creada por una corrida concurrente; se reutiliza."
      return
    }
    local other_rg
    other_rg="$(azs storage account list --query "[?name=='$TFSTATE_STORAGE_ACCOUNT'].resourceGroup | [0]" -o tsv)"
    if [[ -n "$other_rg" ]]; then
      die "La cuenta $TFSTATE_STORAGE_ACCOUNT existe en el resource group '$other_rg', no en" \
        "'$TFSTATE_RESOURCE_GROUP'. Exporte TFSTATE_RESOURCE_GROUP=$other_rg y vuelva a ejecutar."
    fi
    die "El nombre $TFSTATE_STORAGE_ACCOUNT está tomado globalmente por otra suscripción." \
      "Exporte TFSTATE_STORAGE_ACCOUNT con otro nombre [a-z0-9]{3,24} y regístrelo en P9/README.md."
  fi

  # Con auth=azuread explícito se puede prohibir la llave compartida; en
  # auto/key hace falta porque el backend obtiene la llave vía ARM.
  local shared_key=true
  [[ "$TFSTATE_AUTH" == azuread ]] && shared_key=false

  log "Creando storage account $TFSTATE_STORAGE_ACCOUNT ($TFSTATE_SKU, TLS1.2, sin acceso público)..."
  if ! azs storage account create -n "$TFSTATE_STORAGE_ACCOUNT" -g "$TFSTATE_RESOURCE_GROUP" \
    -l "$TFSTATE_LOCATION" --sku "$TFSTATE_SKU" --kind StorageV2 \
    --min-tls-version TLS1_2 --https-only true --allow-blob-public-access false \
    --allow-shared-key-access "$shared_key" \
    --tags practica=p9 proposito=terraform-state administrado-por=bootstrap.sh -o none; then
    # Una creación concurrente puede devolver conflicto; lo que importa es el
    # estado observable final, no qué proceso la creó.
    sleep 15
    _tfstate_sa_exists || die "No se pudo crear la storage account $TFSTATE_STORAGE_ACCOUNT."
    warn "La creación devolvió error pero la cuenta existe (creación concurrente); se continúa."
  fi
}

# Versionado + soft delete: permiten recuperar un estado corrupto o borrado.
# Es un PATCH que converge al mismo valor en cada corrida.
_tfstate_ensure_data_protection() {
  log "Asegurando versionado de blobs y soft delete (${TFSTATE_RETENTION_DAYS} días)..."
  retry 3 10 azs storage account blob-service-properties update \
    --account-name "$TFSTATE_STORAGE_ACCOUNT" -g "$TFSTATE_RESOURCE_GROUP" \
    --enable-versioning true \
    --enable-delete-retention true --delete-retention-days "$TFSTATE_RETENTION_DAYS" \
    --enable-container-delete-retention true --container-delete-retention-days "$TFSTATE_RETENTION_DAYS" \
    -o none
}

# Plano de control (ARM, `container-rm`): funciona con el rol Contributor, sin
# necesitar permisos de datos sobre blobs.
_tfstate_ensure_container() {
  if _tfstate_container_exists; then
    log "Contenedor $TFSTATE_CONTAINER: ya existe (no se modifica)."
    return
  fi
  log "Creando contenedor privado $TFSTATE_CONTAINER..."
  if ! azs storage container-rm create --storage-account "$TFSTATE_STORAGE_ACCOUNT" \
    -g "$TFSTATE_RESOURCE_GROUP" -n "$TFSTATE_CONTAINER" --public-access off -o none; then
    sleep 5
    _tfstate_container_exists || die "No se pudo crear el contenedor $TFSTATE_CONTAINER."
    warn "Contenedor creado por una corrida concurrente; se reutiliza."
  fi
}

# Candado de borrado sobre el RG del backend. Requiere
# Microsoft.Authorization/locks/write (Owner o User Access Administrator); con
# Contributor solo no está permitido, por eso no es fatal: se deja advertencia
# visible y queda documentado como riesgo en P9/docs/terraform-backend.md.
_tfstate_ensure_delete_lock() {
  local name=p9-tfstate-no-delete
  if azs lock show --name "$name" -g "$TFSTATE_RESOURCE_GROUP" -o none >/dev/null 2>&1; then
    log "Candado CanNotDelete $name: ya existe."
  elif azs lock create --name "$name" --lock-type CanNotDelete -g "$TFSTATE_RESOURCE_GROUP" \
    --notes "Estado de Terraform de P9: sobrevive al desastre del clúster." -o none 2>/dev/null; then
    log "Candado CanNotDelete $name: creado."
  else
    warn "No se pudo crear el candado CanNotDelete (requiere Owner/User Access Administrator)." \
      "El backend funciona igual, pero queda expuesto a un borrado accidental del RG."
  fi
}

tfstate_ensure_backend() {
  _tfstate_ensure_provider
  _tfstate_ensure_group
  _tfstate_ensure_account
  _tfstate_ensure_data_protection
  _tfstate_ensure_container
  _tfstate_ensure_delete_lock
  log "Backend remoto listo."
}

# Prueba de acceso de datos con Entra ID (rol "Storage Blob Data Contributor"
# o superior). Contributor solo NO incluye permisos de datos sobre blobs.
_tfstate_probe_azuread() {
  az storage container show --name "$TFSTATE_CONTAINER" --account-name "$TFSTATE_STORAGE_ACCOUNT" \
    --auth-mode login --only-show-errors -o none >/dev/null 2>&1
}

# Decide cómo se autentica Terraform contra el blob:
#   azuread: token de Entra ID (az login / OIDC). Sin llaves en ningún lado.
#   key:     el backend pide la llave de la cuenta a ARM (listKeys) en cada
#            ejecución, usando la sesión de az. La llave vive solo en memoria:
#            no se exporta, no se pasa por -backend-config (quedaría escrita
#            en .terraform/terraform.tfstate) y no se escribe en disco.
tfstate_resolve_auth() {
  case "$TFSTATE_AUTH" in
    azuread)
      _tfstate_probe_azuread ||
        die "TFSTATE_AUTH=azuread, pero la identidad actual no tiene acceso de datos al contenedor." \
          "Asigne 'Storage Blob Data Contributor' sobre la cuenta $TFSTATE_STORAGE_ACCOUNT (la propagación puede tardar minutos)."
      ;;
    auto)
      if _tfstate_probe_azuread; then
        TFSTATE_AUTH=azuread
      else
        TFSTATE_AUTH=key
        warn "La identidad no tiene rol de datos sobre blobs; se usa autenticación por llave obtenida vía ARM" \
          "(solo en memoria). Para eliminar llaves compartidas asigne 'Storage Blob Data Contributor' y use TFSTATE_AUTH=azuread."
      fi
      ;;
  esac
  if [[ "$TFSTATE_AUTH" == key ]]; then
    local allowed
    allowed="$(azs storage account show -n "$TFSTATE_STORAGE_ACCOUNT" -g "$TFSTATE_RESOURCE_GROUP" \
      --query allowSharedKeyAccess -o tsv)"
    [[ "$allowed" != false ]] ||
      die "La cuenta prohíbe la llave compartida y la identidad no tiene rol de datos: no hay forma de leer el estado."
  fi
  log "Autenticación del backend: $TFSTATE_AUTH."
}

# tfstate_build_backend_args <key>: una key (blob) por etapa de Terraform,
# p. ej. p9/01-cluster.tfstate. Deja la key activa en TFSTATE_KEY.
tfstate_build_backend_args() {
  TFSTATE_KEY="${1:?falta la key del estado}"
  local use_azuread=false
  [[ "$TFSTATE_AUTH" == azuread ]] && use_azuread=true
  TF_BACKEND_ARGS=(
    "-backend-config=subscription_id=$AZ_SUBSCRIPTION_ID"
    "-backend-config=resource_group_name=$TFSTATE_RESOURCE_GROUP"
    "-backend-config=storage_account_name=$TFSTATE_STORAGE_ACCOUNT"
    "-backend-config=container_name=$TFSTATE_CONTAINER"
    "-backend-config=key=$TFSTATE_KEY"
    "-backend-config=use_azuread_auth=$use_azuread"
  )
}

# `init -reconfigure` apunta siempre al backend remoto sin intentar migrar
# nada. Un estado local existente se trata como error: ignorarlo en silencio
# haría que Terraform intentara crear recursos que ya existen.
tfstate_terraform_init() {
  local dir=$1
  if [[ -s "$dir/terraform.tfstate" ]]; then
    die "Existe un estado LOCAL en $dir/terraform.tfstate. Migración única y explícita:" \
      "terraform -chdir=$dir init -migrate-state ${TF_BACKEND_ARGS[*]}" \
      "&& rm $dir/terraform.tfstate $dir/terraform.tfstate.backup"
  fi
  log "terraform init contra azurerm://$TFSTATE_STORAGE_ACCOUNT/$TFSTATE_CONTAINER/$TFSTATE_KEY..."
  retry 3 15 terraform -chdir="$dir" init -input=false -reconfigure "${TF_BACKEND_ARGS[@]}"
}

# Acceso a blobs para las verificaciones de bloqueo. En modo key, la llave se
# pasa a `az` solo como variable de entorno del proceso hijo (no aparece en
# `ps`, a diferencia de --account-key) y nunca se imprime.
_tfstate_access_key=""
tfstate_az_blob() {
  if [[ "$TFSTATE_AUTH" == azuread ]]; then
    az storage blob "$@" --account-name "$TFSTATE_STORAGE_ACCOUNT" --auth-mode login --only-show-errors
  else
    if [[ -z "$_tfstate_access_key" ]]; then
      _tfstate_access_key="$(azs storage account keys list -n "$TFSTATE_STORAGE_ACCOUNT" \
        -g "$TFSTATE_RESOURCE_GROUP" --query '[0].value' -o tsv)"
    fi
    AZURE_STORAGE_KEY="$_tfstate_access_key" \
      az storage blob "$@" --account-name "$TFSTATE_STORAGE_ACCOUNT" --auth-mode key --only-show-errors
  fi
}
