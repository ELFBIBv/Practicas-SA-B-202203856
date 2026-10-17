# Laboratorio local en kind — 2026-10-16

> **No es evidencia de la prueba de DR en AKS.** Es una prueba previa, en la máquina del autor, para encontrar defectos antes de gastar crédito de Azure. Los criterios 2.1–2.6 se demuestran con las corridas en AKS (`P9/evidencia/reconstruccion/`, `restauracion/`, `nodo/`). Todas las marcas de tiempo están en UTC.

## Qué se reprodujo y qué se sustituyó

| En AKS | En el laboratorio | Igual que en AKS |
| --- | --- | --- |
| AKS, 2 nodos | kind 1.37: 1 control-plane + 2 workers | Scripts reales de `P9/scripts` |
| Azure Disk CSI (`managed-csi`, `WaitForFirstConsumer`) | CSI hostpath distribuido con snapshots; StorageClass llamada `managed-csi`, también `WaitForFirstConsumer` | Render real del chart (perfil `values-azure.yaml`) |
| Blob Storage fuera del clúster | SeaweedFS (S3) en un contenedor fuera de los clústeres | Velero 1.18.2 (chart 12.2.0), CSI + data mover, `Schedule` real con cron `*/2` y luego `*/5` en lugar de `*/15` |
| Key Vault | `az` simulado: directorio local | `backup-` y `restore-sealed-secrets-key.sh` reales, con una llave **de laboratorio** (no la real) |
| Imágenes de GHCR (privadas) | `nginx-unprivileged` en los 5 servicios sin estado | Reparto entre nodos, anti-afinidad, PDB, probes (ruta `/`), Rollout canario |
| ArgoCD ordenando olas | Aplicación manual en el mismo orden | `gitops/platform/data-restore/data-restore.yaml` idéntico al del repo (`RESTORE_MODE: required`) |

## Resultados

| Prueba | Archivo | Resultado |
| --- | --- | --- |
| Drenaje sin `preStop` | `nodo/1-sin-prestop-*` | 1 conexión rechazada en 100 sondeos (`000` en 1.7 ms) durante el desalojo: el Pod moría antes de salir de los endpoints. **Defecto corregido** con `lifecycle.preStop.sleep` de 5 s. |
| Drenaje con `preStop`, `p9-a-worker` (3 réplicas del gateway) | `nodo/2-*` | 100 % (470 sondeos, umbral 100 %); recuperado en 12 s. |
| Guarda de réplicas concentradas | `nodo/3-*` | Tras el `uncordon` los Pods quedan en un solo nodo y el script se niega a drenar. El runbook (R-4) explica cómo reequilibrar. |
| Drenaje con `preStop`, `p9-a-worker2` | `nodo/4-*` | 100 % (414 sondeos, umbral 100 %); recuperado en 17 s. |
| Restauración, intento 1 | `restauracion/1-*` | Backup programado `Completed`, pero el script abortó: `backup_times` no imprimía salto de línea y `read` devolvía 1 bajo `set -e`. **Defecto corregido** (y prueba unitaria de regresión). |
| Restauración, intento 2 | `restauracion/2-*` | `PartiallyFailed` tras 30 min: el data mover esperaba a que un Pod consumiera el PVC restaurado (`WaitForFirstConsumer`). En AKS habría bloqueado el Job `p9-data-restore` (ola -10) antes de que exista su consumidor (ola 0). **Defecto corregido** con `restorePVC.ignoreDelayBinding` en el node-agent (Terraform, `modules/velero`). |
| Restauración, intento 3 | `restauracion/3-*` | `RESTAURACION_OK`: M1 recuperado, M2 perdido como se esperaba, RPO = 93 s, restauración en 174 s. |
| Simulacro de pérdida total | `simulacro/*` | M1 → backup programado → M2 → **clúster A eliminado** → clúster B nuevo → llave restaurada desde la custodia antes del controlador (el controlador registró la llave existente, sin generar otra) → los mismos SealedSecret del clúster A, `Synced=True` → Job `p9-data-restore` real: eligió el último backup anterior al nacimiento del clúster y dejó los PVC `Bound` antes de las bases → MySQL con M1, sin M2. RPO = 17:57:09 − 17:51:32.628 = 5 min 37 s (cadencia de laboratorio `*/5`). |

`simulacro/1-*` termina en un error de un script auxiliar del laboratorio (instalación de la base del clúster B bajo carga alta de la máquina, no de `P9/`). Se reintentó y la reconstrucción siguió en el mismo orden. `simulacro/2-*` a `4-*` son las salidas reales de esa continuación. Por esa intervención, el tiempo total de reconstrucción del laboratorio **no** se reporta como RTO.

## Limitaciones

- No se probaron en el laboratorio: Terraform contra Azure, ArgoCD y sus olas, Kyverno con verificación de firmas, Workload Identity, la IP fija del gateway ni el backend remoto. Se validan en AKS.
- El CSI hostpath copia el volumen completo en cada snapshot; Azure Disk hace snapshots incrementales. Los tiempos de backup y restauración no son extrapolables.
- La carga de la máquina del autor (otros proyectos en Docker) reinició el API server de kind durante una de las corridas; esa corrida se abortó y no se incluye.
