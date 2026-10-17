# Backend remoto de Terraform: cómo se resuelve el "huevo y la gallina"

Criterio de rúbrica: **2.2 Estado remoto y disciplina de IaC** (y la parte de backend de **2.1 Bootstrap**).

**Estado de este documento:** el diseño está *implementado sin ejecutar contra Azure*. `terraform fmt`/`validate`, `shellcheck` y la auditoría del repositorio sí se ejecutaron localmente (ver "Validaciones"). La creación real del backend, `init` remoto y la prueba de locking siguen **pendientes** hasta que el operador ejecute los comandos de la sección final con credenciales reales.

## Problema

Terraform guarda su estado en una storage account de Azure con bloqueo. Esa cuenta no existe en una suscripción limpia ni después de un desastre total, y el Terraform que la usaría como backend no puede crearla, porque para ejecutarse ya necesita el backend.

## Decisión: el backend lo asegura el script de entrada, no Terraform

`P9/scripts/bootstrap.sh` asegura el backend con Azure CLI antes de `terraform init`, usando operaciones "comprobar → crear si falta" (implementadas en `P9/scripts/lib/tfstate-backend.sh`). Después ejecuta `terraform init -reconfigure -backend-config=...` contra ese backend.

| Criterio | (a) Etapa `00-backend/` con estado local que se "gradúa" | **(b) Script con Azure CLI (elegida)** |
| --- | --- | --- |
| Complejidad | Dos raíces de Terraform, además de `init -migrate-state` y un estado del backend guardado dentro del propio backend | Una sola raíz de Terraform y ~5 llamadas `az` |
| Idempotencia | La 2.ª corrida en otra máquina no tiene el estado local efímero y exige `import` o leer el estado ya graduado | Cada corrida observa Azure y solo crea lo que falta |
| Fallo parcial | Si falla entre `apply` y `migrate-state`, queda un `terraform.tfstate` local que nadie más ve | No hay estado intermedio: la siguiente corrida retoma desde lo que existe |
| Riesgo de destrucción | Un `destroy` en `00-backend` borra el estado de todo | El backend no está en ningún estado de Terraform: ningún `destroy` lo toca |
| Claridad para un tercero | Requiere entender la migración de estado | Un solo comando; el log dice qué existía y qué se creó |

Aquí, (a) no aporta la ventaja habitual de Terraform, que es detectar drift en recursos que cambian, porque el backend es casi inmutable. También agrega un estado local transitorio, justo lo que penaliza la rúbrica.

Otras alternativas descartadas:

- **Terraform Cloud/HCP como backend:** agrega una cuenta y un token externos.
- **Backend en el mismo RG que el clúster:** comparte dominio de fallo con lo que se destruye.

## Qué crea y en qué orden

| # | Recurso | Nombre por defecto | Cómo se logra idempotencia |
| --- | --- | --- | --- |
| 1 | Registro del proveedor `Microsoft.Storage` | — | Consulta `registrationState`; registra con `--wait` solo si no está `Registered` |
| 2 | Resource group del backend | `rg-p9-tfstate` | `az group exists` → crea solo si es `false`; si existe, no se modifica (ni tags) |
| 3 | Storage account | `stp9tf` + 12 hex de `sha256(subscription_id)` | `az storage account show` → `check-name` → `create`. Si `create` falla, se vuelve a observar y se continúa si ya existe (creación concurrente). Nunca se recrea |
| 4 | Versionado de blobs y soft delete (30 días) | — | `blob-service-properties update` es un PATCH que converge al mismo valor |
| 5 | Contenedor privado | `tfstate` | `container-rm exists` → `container-rm create`; nunca se borra |
| 6 | Candado `CanNotDelete` sobre el RG | `p9-tfstate-no-delete` | `lock show` → `lock create`. Sin permiso (Contributor), solo advierte |
| 7 | `terraform init -reconfigure` por etapa | keys `p9/01-cluster.tfstate` y `p9/02-platform.tfstate` | No migra nada. Un `terraform.tfstate` local es error explícito, no se ignora |
| 8 | `terraform plan -out` → `apply <plan>` | — | Con estado remoto, `apply` converge: solo crea o cambia lo que difiere |

Notas sobre la tabla:

- **Paso 3, cuando el nombre está ocupado en otra suscripción:** el script falla con instrucciones para fijar `TFSTATE_STORAGE_ACCOUNT`.
- **Paso 6:** sin el permiso, el candado no se crea. Queda como riesgo documentado.

**Por qué no `|| true`:** ocultaría errores reales, como falta de permisos o una política de Azure que prohíbe la región. El script observa el estado antes y después de cada operación y solo tolera el caso concreto de "ya existe".

**Por qué no `terraform import` ni data sources condicionales:** el backend no pertenece a ningún estado de Terraform, así que no hay nada que importar. La convergencia de los recursos del clúster la da el propio estado remoto.

**Nombres deterministas:** tras perder la máquina del operador, el mismo `az login` sobre la misma suscripción vuelve a calcular el mismo nombre de cuenta. No hay que recordar ni copiar nada.

## Autenticación sin secretos en el repositorio

`TFSTATE_AUTH=auto` (por defecto) prueba primero Entra ID sobre el plano de datos.

- **`azuread`** (preferido): se usa si la identidad tiene *Storage Blob Data Contributor* sobre la cuenta. Terraform recibe `use_azuread_auth=true` y usa el token de `az login`. No existe ninguna llave.
- **`key`** (fallback): se usa si la identidad solo tiene *Contributor*, que no incluye permisos de datos sobre blobs. El backend usa la sesión de `az` para pedir la llave a ARM (`listKeys`) en cada ejecución. La llave vive solo en memoria:
  - No se pasa por `-backend-config`, porque Terraform la guardaría en claro en `.terraform/terraform.tfstate`.
  - No se exporta.
  - No se escribe en disco.

**Conflicto con el supuesto "solo Contributor":** con ese rol no es posible asignarse el rol de datos ni crear el candado de borrado. Ambos requieren `Microsoft.Authorization/*/write` (Owner o User Access Administrator). Por eso el modo `key` es el camino por defecto. Para eliminar la llave compartida, alguien con Owner debe asignar una sola vez el rol *Storage Blob Data Contributor* sobre la cuenta. Después se exporta `TFSTATE_AUTH=azuread`; en una cuenta nueva, eso además la crea con `--allow-shared-key-access false`.

**CI (futuro):** un workflow de GitHub Actions usaría OIDC (`azure/login` con credencial federada y `ARM_USE_OIDC=true`) con el mismo rol de datos. No se guarda ningún secreto de cliente.

## Bloqueo (locking)

El backend `azurerm` bloquea el estado **automáticamente**; no hay nada que habilitar. En cada operación que escribe o lee con lock (`plan`, `apply`, `import`, `state rm`…):

1. Toma un *lease* sobre el blob de la etapa (`p9/01-cluster.tfstate` o `p9/02-platform.tfstate`).
2. Escribe en su metadata el ID del lock y quién lo tiene.
3. Lo libera al terminar.

Si otro proceso tiene el lease, Terraform falla con `Error acquiring the state lock` y muestra el ID y el dueño del lock.

**Dos operadores a la vez:**

- **Fase de backend:** todas las operaciones son PUT idempotentes de ARM o se vuelven a observar tras un conflicto, así que ambas corridas terminan con el mismo backend.
- **Fase Terraform:** el lease serializa. La segunda corrida espera hasta `TF_LOCK_TIMEOUT` (120 s) y luego falla con un mensaje claro. Además, `apply` aplica el plan guardado. Si el estado cambió entre `plan` y `apply`, Terraform rechaza el plan como obsoleto (*Saved plan is stale*) en lugar de pisar el cambio del otro operador.

**Lock huérfano** (proceso muerto a mitad de un apply):

1. Confirme que no queda ningún proceso de Terraform corriendo.
2. Ejecute `terraform -chdir=P9/terraform/<etapa> force-unlock <ID>`, donde `<etapa>` es `01-cluster` o `02-platform` e `<ID>` es el que imprime el error.

**Estado corrupto o borrado:** el versionado permite restaurar una versión anterior del blob. Listarlas:

```bash
az storage blob list --account-name "$TFSTATE_STORAGE_ACCOUNT" -c tfstate --include v --prefix p9/ --auth-mode login
```

## Prevención de estado y credenciales en git

- **`.gitignore`:** `P9/terraform/.gitignore` y `P9/.gitignore` cubren estado, planes, tfvars reales, overrides, `.terraformrc`, crash logs, kubeconfigs, llaves (`*.pem`, `*.key`, `sealed-secrets-key*`) y los logs crudos del bootstrap (`evidencia/bootstrap/raw/`).
- **`.terraform.lock.hcl`:** **se versiona**. Solo contiene versiones y hashes de providers, sin datos del entorno. Para que valide en Linux, macOS y Windows, regenérelo con:

  ```bash
  for s in 01-cluster 02-platform; do terraform -chdir=P9/terraform/$s providers lock -platform=linux_amd64 -platform=darwin_arm64 -platform=darwin_amd64 -platform=windows_amd64; done
  ```

- **`make -C P9 audit`** (`P9/scripts/audit-repo.sh`): revisa el **índice** de git, es decir, lo rastreado y lo preparado para commit. Falla ante:
  - nombres prohibidos;
  - contenido de tfstate (`"lineage"`), llaves privadas, `client-key-data`, `AccountKey=` o tokens de GitHub.

  Imprime solo `ruta:línea`, nunca el valor encontrado.

## Riesgos y puntos únicos de fallo conocidos

- **Región del backend:** por defecto está en la misma región que el clúster (`chilecentral`) con `Standard_LRS`. Sobrevive a la pérdida del clúster, pero no a una caída regional de Azure Storage. Mitigación: exportar `TFSTATE_LOCATION` a otra región y/o un `TFSTATE_SKU` con replicación geográfica, si la suscripción lo permite. Hay que registrar la elección en `P9/README.md`.
- **Sin candado de borrado** si el operador solo tiene Contributor (ver advertencia del script).
- **Acceso de red:** el endpoint público de la cuenta queda abierto a la red, protegido por Entra ID o llave. Restringirlo por IP rompería la reconstrucción desde una máquina nueva.
- **Día cero de Terraform:** resuelto en dos etapas con estados separados (`01-cluster`, `02-platform`). Ver [`terraform-dia-cero.md`](terraform-dia-cero.md).

## Validaciones (comandos exactos, desde la raíz del repo)

| # | Comando | Resultado esperado | Estado |
| --- | --- | --- | --- |
| 1 | `terraform -chdir=P9/terraform fmt -check -recursive` | Sin salida, código 0 | Verificado localmente (Terraform 1.16.4) |
| 2 | `make -C P9 validate` | `Success! The configuration is valid.` | Verificado localmente sobre una copia (`init -backend=false`) |
| 3 | `make -C P9 audit` | `Auditoría superada.`, código 0 | Verificado; el caso negativo (tfstate preparado) falla con código 1 |
| 4 | `./P9/scripts/bootstrap.sh backend` | Log de cada recurso ("ya existe" o "creando") y `Estado remoto accesible: N recursos` | Pendiente (requiere Azure) |
| 5 | Repetir el paso 4 | Todas las líneas dicen "ya existe" y no hay ningún `create` | Pendiente |
| 6 | `terraform -chdir=P9/terraform init -input=false -reconfigure` + `-backend-config` (lo hace el paso 4) | `Successfully configured the backend "azurerm"!` en cada etapa | Pendiente |
| 7 | `./P9/scripts/bootstrap.sh plan` | Plan sin error. **No publique el log sin revisarlo**: puede contener IDs y valores del entorno | Pendiente (requiere Azure; `02-platform` solo se planifica si el clúster existe) |
| 8 | `make -C P9 verify-lock` | `PASA` en la prueba 1 y en el cierre, sobre `p9/01-cluster.tfstate`. La prueba 2 puede salir `NO CONCLUYENTE` si el plan es muy corto | Pendiente (requiere que exista el blob del estado) |
| 9 | `az storage blob show --account-name <cuenta> -c tfstate -n p9/01-cluster.tfstate --auth-mode login --query properties.lease` durante un `apply` | `state: leased`; al terminar, `available` | Pendiente |
| 10 | `git ls-files P9 \| grep -E '\.tfstate\|\.tfplan$\|tfvars$'` | Sin salida | Verificado |

En los pasos 9 y 10:

- **`<cuenta>` (paso 9):** es el valor que imprime el paso 4 en la línea `Backend de estado: … cuenta=`.
- **Barras `\|` (paso 10):** están escapadas solo para la tabla. En la terminal se escriben como `|`.
