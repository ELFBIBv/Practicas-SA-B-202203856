# Práctica 9 — Continuidad operativa y recuperación ante desastres

Convierte el ecosistema de microservicios de la Práctica 8 (GitOps con ArgoCD, entrega progresiva con Argo Rollouts, admisión con Kyverno, secretos con Sealed Secrets) en un sistema **recuperable**: un solo comando reconstruye el clúster AKS completo desde cero, restaura los datos desde respaldos de Velero fuera del clúster y recupera la llave que descifra los secretos del repositorio.

> **Estado de la entrega (2026-10-17):** pruebas ejecutadas en AKS: reconstrucción tras pérdida total, restauración de datos verificada y pérdida de nodo. Resultados, incluidos los incumplimientos, en el [informe de DR](docs/informe-dr.md). `verificar_p9.sh` contra el clúster real: **58/60, sin requisitos eliminatorios incumplidos** ([reporte](evidencia/verificacion/verificar_p9-20261017T053600Z.txt)). Estado por criterio en [Matriz de cumplimiento](#matriz-de-cumplimiento).

## Tabla de enlaces obligatoria (sección 4.1)

| Ítem | Enlace o dato requerido |
| --- | --- |
| Repositorio GitOps | https://github.com/ELFBIBv/Practicas-SA-B-202203856-gitops (público, rama `main`) |
| Aplicación raíz en ArgoCD | `p9-root`, namespace `argocd` (AppProject `p9-bootstrap`; lee `apps/` del repo GitOps) |
| Punto de entrada del bootstrap | [`P9/scripts/bootstrap.sh`](scripts/bootstrap.sh) — `./P9/scripts/bootstrap.sh` o `make -C P9 bootstrap` |
| Backend remoto de Terraform | `azurerm` (Azure Blob Storage): RG `rg-p9-tfstate`, cuenta `stp9tf<12 hex del SHA-256 de la suscripción>`, contenedor `tfstate`, blobs `p9/00-persistent.tfstate`, `p9/01-cluster.tfstate`, `p9/02-platform.tfstate`. Bloqueo por blob lease ([`scripts/verify-tfstate-lock.sh`](scripts/verify-tfstate-lock.sh)). Detalle: [`docs/terraform-backend.md`](docs/terraform-backend.md) |
| Schedule de Velero | `sa-p9-schedule` (namespace `velero`), `*/15 * * * *`, TTL `1440h` (60 días), namespace `sa-p5`, CSI + data mover ([manifiesto](gitops/platform/velero-schedules/schedule.yaml)). Destino: BSL `default` → Azure Blob, cuenta `stp9veloc01f715c2e19`, contenedor `velero-backups`, RG `rg-p9-tfstate` (fuera del RG del clúster) |
| Reconstrucción cronometrada | 2026-10-17, `make -C P9 bootstrap` tras la pérdida total del 2026-09-25: [cronología con fuentes](evidencia/reconstruccion/cronologia-20261017.md) · [log](evidencia/reconstruccion/bootstrap-20261017T020742Z.log) · [verificación final, 12 etapas y 4 endpoints OK](evidencia/reconstruccion/verify-20261017T054056Z.log) |
| Restauración de datos | 2026-10-17, `make -C P9 dr-restore-test`: M1 recuperado, M2 perdido, restauración en 82 s, RPO 498 s ([log](evidencia/restauracion/restauracion-20261017T035428Z.log)). En la reconstrucción, las 13 filas de `cron_logs` del 2026-09-25 recuperadas ([informe §4](docs/informe-dr.md#4-pérdida-medida)) |
| Prueba de pérdida de nodo | 2026-10-17, `make -C P9 dr-node-test`, 3 corridas, **100 % de disponibilidad en las tres** (1 740, 1 355 y 1 230 sondeos). La 1 y la 2 destaparon dos puntos únicos de fallo, ya corregidos: Kyverno con 1 réplica y falta de capacidad N-1. En la 3, drenaje en 35 s y todo reprogramado salvo 2 de 5 réplicas del gateway ([log](evidencia/nodo/drenaje-20261017T054203Z.log), [sondeo](evidencia/nodo/sondeo-20261017T054210Z.csv); detalle en el [informe §5](docs/informe-dr.md#5-puntos-únicos-de-fallo-detectados)) |
| RTO y RPO declarados | Declarados 2026-09-24: **RTO 45 min**, **RPO 15 min**. Medidos: **RTO 94 min 27 s** (incumple: 69 min bloqueado por una credencial de GHCR vencida; tramo automático hasta datos restaurados, 19 min) · **RPO 498 s** en la restauración y **909 s** en la pérdida total (incumple por 9 s). Detalle en el [informe](docs/informe-dr.md) |
| Video demostrativo | No se grabó: la calificación es presencial, en la máquina del autor y con el clúster encendido |

> **Acceso:** el repositorio de código `ELFBIBv/Practicas-SA-B-202203856` es privado. La calificación es presencial y `verificar_p9.sh` lo clona con las credenciales del autor; el repositorio GitOps es público.

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
| 1.1 Runbook | `docs/runbook-recuperacion.md` | Contingencias de la prueba en AKS agregadas a R-7 (credencial de GHCR, Kyverno, capacidad) | implementado |
| 1.2 Informe DR | `docs/informe-dr.md` (6 campos) | Valores medidos en AKS, 2026-10-17 | verificado (RTO y RPO de E1 incumplen; documentado) |
| 1.3 Diagrama | `docs/diagrama-bootstrap.md` | Coincide con `bootstrap.sh`/`P9_WAVES` y con el [log de la reconstrucción](evidencia/reconstruccion/bootstrap-20261017T020742Z.log) | implementado |
| 1.4 Preguntas | `docs/preguntas-teoricas.md` | Contrastar con el informe | implementado |
| 2.1 Bootstrap | `scripts/bootstrap.sh`, `terraform/`, `gitops/apps/` | Reconstrucción desde cero con un comando ([cronología](evidencia/reconstruccion/cronologia-20261017.md)); verificación final de 12 etapas OK ([log](evidencia/reconstruccion/verify-20261017T054056Z.log)) | verificado; con 2 intervenciones manuales por la credencial de GHCR (informe, PUF 1) |
| 2.2 Estado remoto | `scripts/lib/tfstate-backend.sh`, `backend.tf` × 3, `.gitignore` | `make audit`; `init`/`plan`/`apply` contra `azurerm` en cada corrida; bloqueo por lease ([log](evidencia/estado/verify-lock-20261017T054744Z.log)) | verificado |
| 2.3 Velero | `terraform/02-platform/modules/velero`, `gitops/platform/velero-schedules` | 10 backups `Completed`, BSL `Available`, 2 restauraciones `Completed` en AKS | verificado |
| 2.4 Secretos | `scripts/{backup,restore}-sealed-secrets-key.sh`, Key Vault | En la reconstrucción, la llave (huella `7DD46ABC19BE6499`) se restauró antes del controlador y los 6 SealedSecret quedaron `Synced=True` y los consumen MySQL, MongoDB, NATS y auth ([log](evidencia/reconstruccion/bootstrap-20261017T020742Z.log)) | verificado |
| 2.5 Nodo | `topologySpreadConstraints`, anti-afinidad, PDB, probes y `preStop` en los 5 servicios | `dr-node-drain-test.sh` en AKS: 3 drenajes con 100 % de disponibilidad ([`evidencia/nodo/`](evidencia/nodo/)) | verificado; el gateway queda 3/5 durante el drenaje (informe, PUF 3) |
| 2.6 Datos | `gitops/platform/data-restore`, `dr-data-restore-test.sh` | M1 recuperado y M2 perdido ([log](evidencia/restauracion/restauracion-20261017T035428Z.log)); filas del 2026-09-25 recuperadas tras la pérdida total | verificado |
| P8 conservado | Applications `kyverno`, `kyverno-policies`, `argo-rollouts`, `sa-platform` | Etapas 8 y 10 de la [verificación](evidencia/reconstruccion/verify-20261017T054056Z.log): autosync habilitado, Rollout `Healthy`, políticas en Enforce (y rechazando de verdad: PUF 1) | verificado |

## Requisitos para optar a calificación (8.1)

| Requisito | Estado |
| --- | --- |
| Práctica 8 calificada | Fuera de este repositorio (confirmar) |
| Sistema desplegado y sincronizado al calificar | Desplegado y `Synced/Healthy` el 2026-10-17; el día de la calificación: `./P9/scripts/bootstrap.sh verify` |
| Estado remoto, sin estado en el repo | cumple: `make -C P9 audit` y `verificar_p9.sh` (2.2 = 8/8) |
| Al menos un backup Velero `Completed` | cumple: 10 `Completed` (2.3 = 14/14 en el [reporte](evidencia/verificacion/verificar_p9-20261017T053600Z.txt)) |
| Tabla de enlaces completa | cumple; el repositorio de código es privado y la calificación es presencial |

## Excepciones documentadas

- **Namespace `sa-p5`** (heredado de P8): los SealedSecret usan `scope: strict`, atado a nombre y namespace; renombrarlo rompería la continuidad de secretos.
- **Velero lo instala Terraform** (`02-platform`), no una Application: su credencial federada necesita el emisor OIDC del clúster. Solo el `Schedule` es GitOps.
- **`kubectl` dentro de scripts automáticos** (reinyección de la llave, Job de restauración): los invoca el punto de entrada, no el operador.
- **La custodia de la llave** es una acción humana **previa** al desastre (`backup-sealed-secrets-key.sh`), no parte de la reconstrucción.

## Contenido heredado de P8 en esta carpeta

El código de los microservicios (`api-gateway/`, `auth/`, `catalog/`, `orders/`, `notifications/`, `cronjobs/`), `docker-compose.yml`, el script de carga `loadtest/api-gateway-load-test.js` y el chart son la copia de P9 (el chart lo publica `scripts/publish-gitops.sh`). La bitácora, capturas, script calificador y guion de video de P8 se eliminaron de esta carpeta: siguen en `P8/` y no son evidencia de P9.

## Video demostrativo

No se grabó: la calificación es presencial, con el clúster encendido. Orden de la demostración: `verificar_p9.sh` · `bootstrap.sh verify` (olas, secretos, Rollout, Kyverno, endpoint) · evidencia de reconstrucción, restauración y drenaje · RTO/RPO declarados frente a medidos.
