Implementé el diseño dentro de `P9/`. Lo probé solo en local: **el backend no se ha creado en Azure y la prueba de bloqueo no se ha ejecutado**. Además, `./P9/scripts/bootstrap.sh all` **todavía no puede reconstruir nada**, porque el Terraform actual sigue siendo el de P8 (ver "Contradicciones").

## Recomendación: opción (b), un script con Azure CLI

El backend lo crea `bootstrap.sh` con Azure CLI antes de `terraform init`, y no queda en ningún estado de Terraform. La opción (a) añade un estado local temporal justo en el momento más delicado. Si el proceso falla entre `apply` y `-migrate-state`, queda un `terraform.tfstate` que solo existe en esa máquina, que es lo que la rúbrica castiga. Además, un `destroy` en `00-backend` borraría el estado de todo. Con (b), cada corrida mira qué existe en Azure y solo crea lo que falta. Si algo falla a medias, la siguiente corrida retoma desde ahí.

El backend va en su propio resource group (`rg-p9-tfstate`), separado del clúster. El nombre de la cuenta sale de un hash de la suscripción (`stp9tf` + 12 hex), así que tras un desastre basta el mismo `az login` para volver a calcularlo.

No uso `|| true`, porque ocultaría errores reales como falta de permisos o una región bloqueada. Tampoco uso `terraform import`, porque el backend no está en ningún estado.

## Archivos

| Ruta | Qué hace |
|---|---|
| [scripts/bootstrap.sh](../scripts/bootstrap.sh) | Punto de entrada: `all` (por defecto), `backend` o `plan` |
| [scripts/lib/tfstate-backend.sh](../scripts/lib/tfstate-backend.sh) | Crea o reutiliza el backend, elige la autenticación y ejecuta `init` |
| [scripts/lib/common.sh](../scripts/lib/common.sh) | Logs en ISO 8601 UTC, reintentos, comprobación de versiones |
| [scripts/verify-tfstate-lock.sh](../scripts/verify-tfstate-lock.sh) | Prueba que el estado queda bloqueado mientras Terraform lo usa |
| [scripts/audit-repo.sh](../scripts/audit-repo.sh) | Revisa lo rastreado y lo preparado en git antes de cada commit |
| [terraform/backend.tf](../terraform/01-cluster/backend.tf) | `backend "azurerm" {}` sin valores fijos |
| [Makefile](../Makefile) | `bootstrap`, `backend`, `plan`, `verify-lock`, `audit`, `fmt-check`, `validate` |
| [docs/terraform-backend.md](terraform-backend.md) | Comparación de opciones, idempotencia paso a paso, locking, riesgos y validaciones |

Además cambié [terraform/README.md](../terraform/README.md), cuya nota decía "backend local".

**Orden que sigue `bootstrap.sh`** (desde la raíz: `./P9/scripts/bootstrap.sh` o `make -C P9 bootstrap`):
1. Comprueba herramientas, Terraform ≥ 1.5 y la sesión de `az`.
2. Registra `Microsoft.Storage` si hace falta.
3. Crea el resource group si no existe.
4. Crea la storage account si no existe.
5. Activa versionado y borrado recuperable de 30 días.
6. Crea el contenedor privado si no existe.
7. Intenta poner un candado contra borrado sobre el resource group.
8. Elige la autenticación, ejecuta `init -reconfigure` y luego `plan -out` y `apply` de ese mismo plan.

**Credenciales:** el script primero intenta autenticarse con Entra ID (`use_azuread_auth=true`), sin ninguna llave. Si la identidad no tiene el rol de datos, el backend pide la llave de la cuenta a Azure en cada ejecución y solo la guarda en memoria. Nunca va por `-backend-config`, porque Terraform la escribiría en claro en `.terraform/terraform.tfstate`.

**Bloqueo y dos operadores a la vez:**
- El backend `azurerm` bloquea el estado solo; no hay nada que activar.
- Un segundo operador espera hasta `TF_LOCK_TIMEOUT` (120 s) y después falla con un mensaje claro.
- Como se aplica el plan guardado, si el otro operador cambió el estado entre `plan` y `apply`, Terraform lo rechaza como obsoleto en vez de sobrescribir su cambio.
- En la creación del backend, si dos corridas chocan, el script vuelve a comprobar qué existe y sigue.

**`.gitignore`:** a `P9/.gitignore` le agregué entradas sin quitar ninguna. Cubren estado, planes, tfvars reales, overrides, `.terraformrc`, crash logs, kubeconfigs, `*.pem`/`*.key`, `sealed-secrets-key*` y los logs crudos en `evidencia/bootstrap/raw/`. `P9/terraform/.gitignore` **ya existía**; lo amplié. `.terraform.lock.hcl` sigue versionado, porque solo contiene versiones y hashes de los providers.

## Validaciones

| Comando | Estado |
|---|---|
| `terraform fmt -check -recursive` | ✅ pasó (Terraform 1.9.8 descargado al scratchpad) |
| `make -C P9 validate` | ✅ `Success!` (lo corrí sobre una copia, para no crear `.terraform/` en el repo) |
| `shellcheck -x` en todos los scripts | ✅ sin avisos |
| `make -C P9 audit` | ✅ pasa; con un tfstate falso preparado en un repo de prueba falla con código 1 |
| `git check-ignore` | ✅ estado, planes, tfvars y kubeconfig ignorados; `.terraform.lock.hcl` y `backend.tf` rastreados |
| `./P9/scripts/bootstrap.sh backend` (y repetirlo para confirmar que no crea nada nuevo) | ⏳ pendiente, requiere Azure |
| `./P9/scripts/bootstrap.sh plan` | ⏳ pendiente; hoy fallaría por el kubeconfig. No publiques el log sin revisarlo |
| `make -C P9 verify-lock` | ⏳ pendiente: bloquea el estado desde fuera, comprueba que `plan` se niega a correr y que no quedan bloqueos colgados |

## Contradicciones y cosas a revisar

1. **El módulo raíz no hace un día cero.** `P9/terraform/` es el de P8: usa el provider `kubernetes` sobre un kubeconfig que ya existe y no crea AKS ni ArgoCD. Por eso `bootstrap.sh all` falla a propósito con `PENDIENTE` antes de tocar nada, y lo mismo hacen las comprobaciones posteriores al apply. Falta el módulo de clúster + ArgoCD + app-of-apps; mientras no exista, el criterio 2.1 no está cumplido.
2. **"Solo Contributor" choca con lo mejor en seguridad.** Contributor no da acceso de datos a blobs ni permite crear el candado contra borrado. Por eso, por defecto, se usa la llave de la cuenta y el candado solo genera un aviso. Si tu cuenta de Azure for Students te hace Owner, asígnate *Storage Blob Data Contributor* sobre la cuenta y exporta `TFSTATE_AUTH=azuread`.
3. **Punto único de fallo:** el backend queda por defecto en `chilecentral` con `Standard_LRS`, la misma región que el clúster. Sobrevive a perder el clúster, pero no a una caída de toda la región. Lo documenté como riesgo; se puede cambiar con `TFSTATE_LOCATION` y `TFSTATE_SKU`.
4. **Evidencia de P8 dentro de P9:** `P9/terraform/plan.log`, `apply.log` y `kubectl-get-evidencia.log` son de P8. No los borré, pero no deben presentarse como evidencia de P9.
5. **Fuera de mi alcance:** `P2/auth-service/.env` está rastreado en git. No lo toqué.

No hice commits ni cambios en Azure. El siguiente paso con recursos reales, si lo autorizas, es `./P9/scripts/bootstrap.sh backend` seguido de `make -C P9 verify-lock`.