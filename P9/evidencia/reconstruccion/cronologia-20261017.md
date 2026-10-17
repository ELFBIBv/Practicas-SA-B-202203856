# Reconstrucción tras pérdida total del clúster — cronología

Escenario: el clúster `aks-sa-p9` se destruyó el 2026-09-25 (`destroy-cluster.sh`, solo la etapa `01-cluster`) y se reconstruyó el 2026-10-17 con un único comando, `make -C P9 bootstrap`, desde una máquina sin clúster. Capa persistente intacta: backend `rg-p9-tfstate`, Key Vault `kv-sa-p9-202203856`, storage de Velero, repo GitOps y GHCR. Contexto de Kubernetes: `aks-sa-p9`. Zona horaria: **UTC** en todas las marcas.

| Marca (UTC) | Evento | Fuente |
| --- | --- | --- |
| 2026-09-25 07:15:41 → 07:18:07 | Último respaldo programado `Completed`: `sa-p9-schedule-20260925071541` | `kubectl -n velero get backup sa-p9-schedule-20260925071541` |
| 2026-09-25 07:29:12 | **DESASTRE_INICIO**: empieza el borrado del AKS | [registro de actividad de Azure](azure-activity-log-2026-09-25.tsv) |
| 2026-09-25 07:35:22 | DESASTRE_FIN: borrado el RG `rg-p9-aks` (el RG de nodos, con los discos de los PVC, a las 07:32:34) | ídem |
| 2026-10-17 02:07:42 | **RTO_INICIO**: `make -C P9 bootstrap` | [log del bootstrap](bootstrap-20261017T020742Z.log), nombre y línea 1 |
| 02:08:55 → 02:16:44 | Etapa `01-cluster`: AKS, IP fija e identidad (`5 added`) | ídem |
| 02:16:49 | 2 nodos `Ready` | ídem |
| 02:16:51 → 02:17:01 | Llave de Sealed Secrets restaurada desde Key Vault **antes** del controlador (huella `7DD46ABC19BE6499`) | ídem, `[restore-sskey]` |
| 02:17:01 → 02:21:40 | Etapa `02-platform`: ArgoCD, app-of-apps, Velero (`12 added`) | ídem |
| 02:21:46 | ArgoCD disponible; empiezan las olas | ídem |
| 02:21:59 · 02:25:09 | Ola -30 (Sealed Secrets) · ola -20 (Kyverno, Argo Rollouts) cerradas | ídem |
| 02:25:25 → 02:26:22 | Ola -10: Job `p9-data-restore` → Restore `p9-dr-20261017022525` `Completed` desde el respaldo del 25-09 07:15:41; PVC de MySQL y MongoDB `Bound` | `kubectl -n velero get restore p9-dr-20261017022525`; [verificación](verify-20261017T054056Z.log), etapa 9 |
| 02:26:41 | Ola -5 (políticas de Kyverno en Enforce) cerrada | log del bootstrap |
| 02:27 → 03:35 | **Ola 0 bloqueada**: Kyverno (`verify-image-signatures`) rechaza los Pods de los 5 servicios: GHCR responde `DENIED` a la credencial de `ghcr-secret` (token sellado el 2026-09-24, expirado o revocado). Las bases de datos sí arrancan. | eventos `FailedCreate` de los ReplicaSet |
| 02:46:45 | El bootstrap aborta por el límite de la ola 0 (1200 s), con diagnóstico | log del bootstrap, final |
| 03:01:57 | Primer token nuevo publicado (PR #20 del GitOps): autentica pero sin permiso de lectura de paquetes | PR #20 del repo GitOps |
| 03:35:31 → 03:35:45 | Token válido publicado (PR #21) → ArgoCD aplica los SealedSecret → `ghcr-secret` actualizado en `sa-p5` y `kyverno` | PR #21; `status.conditions[0].lastUpdateTime` de los SealedSecret |
| 03:38:39 | Reintento forzado de los ReplicaSet (anotación): estaban en espera exponencial tras ~70 min de rechazos | consola del operador |
| 03:42:09 | **Servicios listos**: los 4 Deployments `successfully rolled out`, gateway 5/5 `Running` | consola del operador (`kubectl rollout status`); **no quedó archivado** |
| 04:04:59 | Primera respuesta 2xx **registrada en archivo** (`/ready`, `/api/catalog/health`, `/api/orders/health`) | [sondeo](../nodo/sondeo-20261017T040459Z.csv), línea 2 |
| 05:41:56 | Verificación completa: 12 etapas, raíz `Synced/Healthy`, 4 endpoints OK | [verificación](verify-20261017T054056Z.log) |

## Cálculo

- **RTO observado** = 03:42:09 − 02:07:42 = **94 min 27 s**. Cota superior con registro en archivo: 04:04:59 − 02:07:42 = 117 min 17 s.
- Tramo automático sin intervención (lanzamiento → datos restaurados y plataforma lista salvo los servicios): 02:26:41 − 02:07:42 = **18 min 59 s**.
- Bloqueo por la credencial de GHCR: 02:26:41 → 03:35:45 = **69 min 4 s** (diagnóstico, un primer token sin permiso y la rotación).
- **Pérdida máxima** (no hubo marcador previo al 25-09): DESASTRE_INICIO − inicio del respaldo restaurado = 07:29:12 − 07:15:41 = **13 min 31 s**. El RPO con marcador se midió en la [prueba de restauración](../restauracion/restauracion-20261017T035428Z.log): 498 s.
- La caída total (25-09 → 17-10) no es representativa: el clúster se dejó apagado a propósito para no consumir crédito.

## Intervenciones manuales (brechas del bootstrap)

1. Rotar la credencial de GHCR: token nuevo (`read:packages`) creado por el autor, sellado con [`rotate-ghcr-secret.sh`](../../scripts/rotate-ghcr-secret.sh) y publicado en el repo GitOps.
2. Anotar los ReplicaSet para que reintentaran sin esperar su backoff.

Los arreglos de código que aparecieron después (raíz `OutOfSync` por `directory.recurse`, Kyverno con 1 réplica, capacidad N-1) no afectaron a este RTO: los servicios ya respondían.

Logs adicionales: [segunda corrida del 2026-10-17 05:34](bootstrap-20261017T053436Z.log) (agrega el node pool `spare`; Terraform idempotente en las otras etapas).
