# Práctica 9 — Continuidad operativa y recuperación ante desastres

Convierte el ecosistema de microservicios de la Práctica 8 (GitOps con ArgoCD, entrega progresiva con Argo Rollouts, admisión con Kyverno, secretos con Sealed Secrets) en un sistema **recuperable**: un solo comando reconstruye el clúster AKS completo desde cero, restaura los datos desde respaldos de Velero fuera del clúster y recupera la llave que descifra los secretos del repositorio.

> **Estado de la entrega (2026-10-16):** implementación completa y validada estáticamente (Terraform, shellcheck, Helm, esquemas con `kubeconform`, `actionlint` y pruebas unitarias de la lógica de DR); **pruebas en vivo pendientes** (reconstrucción cronometrada, restauración, drenaje, video). Los campos pendientes de la tabla dicen `pendiente` a propósito: no hay evidencia inventada. Estado criterio por criterio en [Matriz de cumplimiento](#matriz-de-cumplimiento).

## Tabla de enlaces obligatoria (sección 4.1)

| Ítem | Enlace o dato requerido |
| --- | --- |
| Repositorio GitOps | https://github.com/ELFBIBv/Practicas-SA-B-202203856-gitops (público, rama `main`) |
| Aplicación raíz en ArgoCD | `p9-root`, namespace `argocd` (AppProject `p9-bootstrap`; lee `apps/` del repo GitOps) |
| Punto de entrada del bootstrap | [`P9/scripts/bootstrap.sh`](scripts/bootstrap.sh) — `./P9/scripts/bootstrap.sh` o `make -C P9 bootstrap` |
| Backend remoto de Terraform | `azurerm` (Azure Blob Storage): RG `rg-p9-tfstate`, cuenta `stp9tf<12 hex del SHA-256 de la suscripción>`, contenedor `tfstate`, blobs `p9/00-persistent.tfstate`, `p9/01-cluster.tfstate`, `p9/02-platform.tfstate`. Bloqueo por blob lease ([`scripts/verify-tfstate-lock.sh`](scripts/verify-tfstate-lock.sh)). Detalle: [`docs/terraform-backend.md`](docs/terraform-backend.md) |
| Schedule de Velero | `sa-p9-schedule` (namespace `velero`), `*/15 * * * *`, TTL `1440h` (60 días), namespace `sa-p5`, CSI + data mover ([manifiesto](gitops/platform/velero-schedules/schedule.yaml)). Destino: BSL `default` → Azure Blob, cuenta `stp9veloc01f715c2e19`, contenedor `velero-backups`, RG `rg-p9-tfstate` (fuera del RG del clúster) |
| Reconstrucción cronometrada | **pendiente** — se generará en `P9/evidencia/reconstruccion/` con [`scripts/dr-rebuild-test.sh`](scripts/dr-rebuild-test.sh) |
| Restauración de datos | **pendiente** — se generará en `P9/evidencia/restauracion/` con [`scripts/dr-data-restore-test.sh`](scripts/dr-data-restore-test.sh) |
| Prueba de pérdida de nodo | **pendiente** — se generará en `P9/evidencia/nodo/` con [`scripts/dr-node-drain-test.sh`](scripts/dr-node-drain-test.sh) |
| RTO y RPO declarados | Declarados 2026-09-24: **RTO 45 min**, **RPO 15 min**. Medidos: **pendiente** ([informe](docs/informe-dr.md)) |
| Video demostrativo | **pendiente** (5-8 min; minutaje en [Video](#video-demostrativo)) |

> **Bloqueante de acceso:** el repositorio de código `ELFBIBv/Practicas-SA-B-202203856` es privado (la API pública devuelve 404). Los enlaces de esta tabla que apuntan a rutas del repositorio exigen autenticación y, según 4.1, se califican con cero. Debe hacerse público (o confirmarse que el evaluador tiene acceso) antes de entregar.

## Documentos de entrega

| Rúbrica | Documento |
| --- | --- |
| 1.1 Runbook de recuperación | [`docs/runbook-recuperacion.md`](docs/runbook-recuperacion.md) |
| 1.2 Informe de la prueba de DR | [`docs/informe-dr.md`](docs/informe-dr.md) |
| 1.3 Diagrama del bootstrap | [`docs/diagrama-bootstrap.md`](docs/diagrama-bootstrap.md) |
| 1.4 Preguntas teóricas | [`docs/preguntas-teoricas.md`](docs/preguntas-teoricas.md) |
| Prueba local previa (no es evidencia de AKS) | [laboratorio kind](evidencia/laboratorio-kind/README.md): drenaje, restauración y simulacro de pérdida total con los scripts reales; encontró y corrigió 3 defectos |
| Decisiones y diseños | [`docs/decisiones-pendientes.md`](docs/decisiones-pendientes.md), [`docs/diseno-dia-cero.md`](docs/diseno-dia-cero.md), [`docs/diseno-sync-waves.md`](docs/diseno-sync-waves.md), [`docs/diseno-secretos-dr.md`](docs/diseno-secretos-dr.md), [`docs/diseno-velero.md`](docs/diseno-velero.md) |

## Cómo se reconstruye (resumen)

Prerrequisitos que **sobreviven** al desastre: repositorio GitOps público, imágenes firmadas en GHCR, backend de Terraform (`rg-p9-tfstate`), almacenamiento de Velero y Key Vault `kv-sa-p9-202203856` con la llave de Sealed Secrets. Acciones humanas permitidas: `az login` y lanzar el comando.

```bash
az login
make -C P9 bootstrap          # = ./P9/scripts/bootstrap.sh all
```

1. **Backend** (Azure CLI, idempotente) → 2. **`00-persistent`** (storage de Velero, UAMI, Key Vault) → 3. **`01-cluster`** (AKS de 2 nodos, IP fija `pip-sa-p9-gateway`) → 4. nodos `Ready` → 5. **llave de Sealed Secrets** desde Key Vault → 6. **`02-platform`** (ArgoCD, Velero con Workload Identity, `p9-root`) → ArgoCD por olas: `-30` sealed-secrets · `-20` kyverno, argo-rollouts · `-10` platform-secrets, **data-restore** · `-5` políticas · `0` sa-platform · `5` Schedule · `10` humo → 7-12. verificaciones hasta el endpoint 2xx (`RTO_FIN`). Diagrama: [`docs/diagrama-bootstrap.md`](docs/diagrama-bootstrap.md).

Pruebas (todas escriben su log con marcas UTC en `P9/evidencia/`):

```bash
make -C P9 dr-restore-test                       # 2.3/2.6 — dato borrado y recuperado del respaldo programado
make -C P9 dr-node-test                          # 2.5 — drenaje con sondeo continuo del servicio
make -C P9 dr-rebuild-test CONFIRM=aks-sa-p9     # 2.1/2.4/2.6 — destrucción + reconstrucción cronometrada (IRREVERSIBLE)
```

Validación estática (también en CI: [`.github/workflows/p9-validate.yml`](../.github/workflows/p9-validate.yml), solo con cambios en `P9/**`):

```bash
make -C P9 fmt-check validate audit
```

## Matriz de cumplimiento

Estados: **verificado** (con evidencia real) · **implementado sin ejecutar** · **pendiente**.

| Criterio | Implementación | Verificación | Estado |
| --- | --- | --- | --- |
| 1.1 Runbook | `docs/runbook-recuperacion.md` | Revisión por un tercero | implementado |
| 1.2 Informe DR | `docs/informe-dr.md` (6 campos) | Requiere la prueba cronometrada | pendiente (objetivos declarados) |
| 1.3 Diagrama | `docs/diagrama-bootstrap.md` | Coincide con `bootstrap.sh`/`P9_WAVES` | implementado |
| 1.4 Preguntas | `docs/preguntas-teoricas.md` | Contrastar con el informe | implementado |
| 2.1 Bootstrap | `scripts/bootstrap.sh`, `terraform/`, `gitops/apps/` | `bootstrap.sh plan` sin errores (2026-09-24); corrida completa | implementado sin ejecutar tras los cambios del 2026-09-29 |
| 2.2 Estado remoto | `scripts/lib/tfstate-backend.sh`, `backend.tf` × 3, `.gitignore` | `make audit` OK (2026-09-29); `verify-tfstate-lock.sh` | verificado estático; lock pendiente de registrar |
| 2.3 Velero | `terraform/02-platform/modules/velero`, `gitops/platform/velero-schedules` | Backup `Completed` + restauración en AKS; ensayado en el [laboratorio kind](evidencia/laboratorio-kind/README.md) | pendiente en AKS |
| 2.4 Secretos | `scripts/{backup,restore}-sealed-secrets-key.sh`, Key Vault | Descifrado offline V-A4 OK 2026-09-25 ([log](evidencia/secretos/v-a4-2026-09-25.txt)); `ghcr-secret` re-sellado después → re-verificar; prueba en clúster reconstruido | parcial |
| 2.5 Nodo | `topologySpreadConstraints`, anti-afinidad, PDB, probes y `preStop` en los 5 servicios | `dr-node-drain-test.sh` en AKS; 100 % en ambos nodos en el [laboratorio kind](evidencia/laboratorio-kind/README.md) | pendiente en AKS |
| 2.6 Datos | `gitops/platform/data-restore`, `dr-data-restore-test.sh` | Marcador M1 recuperado en AKS; recuperado en el [laboratorio kind](evidencia/laboratorio-kind/README.md) (restauración y simulacro de pérdida total) | pendiente en AKS |
| P8 conservado | Applications `kyverno`, `kyverno-policies`, `argo-rollouts`, `sa-platform` | Paso 5c de `dr-rebuild-test.sh` | pendiente |

## Requisitos para optar a calificación (8.1)

| Requisito | Estado |
| --- | --- |
| Práctica 8 calificada | Fuera de este repositorio (confirmar) |
| Sistema desplegado y sincronizado al calificar | pendiente: `./P9/scripts/bootstrap.sh verify` el día de la calificación |
| Estado remoto, sin estado en el repo | cumple: `make -C P9 audit` → `Auditoría superada.` (2026-09-29) |
| Al menos un backup Velero `Completed` | pendiente: `kubectl -n velero get backups` |
| Tabla de enlaces completa y pública | **no cumple aún**: campos pendientes y repositorio de código privado |

## Excepciones documentadas

- **Namespace `sa-p5`** (heredado de P8): los SealedSecret usan `scope: strict`, atado a nombre y namespace; renombrarlo rompería la continuidad de secretos.
- **Velero lo instala Terraform** (`02-platform`), no una Application: su credencial federada necesita el emisor OIDC del clúster. Solo el `Schedule` es GitOps.
- **`kubectl` dentro de scripts automáticos** (reinyección de la llave, Job de restauración): los invoca el punto de entrada, no el operador.
- **La custodia de la llave** es una acción humana **previa** al desastre (`backup-sealed-secrets-key.sh`), no parte de la reconstrucción.

## Contenido heredado de P8 en esta carpeta

El código de los microservicios (`api-gateway/`, `auth/`, `catalog/`, `orders/`, `notifications/`, `cronjobs/`), `docker-compose.yml`, el script de carga `loadtest/api-gateway-load-test.js` y el chart son la copia de P9 (el chart lo publica `scripts/publish-gitops.sh`). La bitácora, capturas, script calificador y guion de video de P8 se eliminaron de esta carpeta: siguen en `P8/` y no son evidencia de P9.

## Video demostrativo

**pendiente.** Minutaje previsto (a confirmar con el video real, 5-8 min): bootstrap y olas de ArgoCD · RTO medido · restauración del marcador · secretos descifrados tras reconstruir · drenaje con el servicio respondiendo · Rollout, Kyverno y autosync de P8 · RTO/RPO declarados vs medidos.
