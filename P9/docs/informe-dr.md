# Informe de la prueba de DR — Práctica 9

> **Estado: ejecutado en AKS el 2026-10-17.** Objetivos declarados el 2026-09-24, antes de cualquier prueba ([`decisiones-pendientes.md`](decisiones-pendientes.md) §2.5); no se ajustaron después de medir. Zona horaria: **UTC** en todas las marcas. Contexto de Kubernetes: `aks-sa-p9`.

## 1. Objetivos declarados

| Objetivo | Valor | Justificación |
| --- | --- | --- |
| **RTO** | **45 min** | Creación de AKS (20-25 min en `chilecentral`) + ArgoCD y controladores (≈10 min) + restauración de PVC y arranque de bases y servicios (≈10 min) + margen. |
| **RPO** | **15 min** | Cadencia del `Schedule` `sa-p9-schedule` (`*/15 * * * *`). |

**RTO** = lanzamiento de `bootstrap.sh` → servicios respondiendo. **RPO** = inicio del desastre − momento de escritura del último dato recuperado. La duración del `Restore` **no** es el RPO.

## 2. Escenario ejecutado

| | Escenario | Comando | Evidencia |
| --- | --- | --- | --- |
| **E1** | **Pérdida total del clúster.** `destroy-cluster.sh` borró AKS, nodos y discos de los PVC el 2026-09-25 a las 07:29:12; la capa persistente (backend, Key Vault, storage de Velero, GitOps, GHCR) quedó intacta. Reconstrucción el 2026-10-17 desde una máquina sin clúster. | `make -C P9 bootstrap` | [cronología](../evidencia/reconstruccion/cronologia-20261017.md), [log](../evidencia/reconstruccion/bootstrap-20261017T020742Z.log), [registro de actividad](../evidencia/reconstruccion/azure-activity-log-2026-09-25.tsv) |
| **E2** | **Pérdida lógica de datos** en el clúster reconstruido: marcador M1 → respaldo programado → M2 → borrado → restauración en un namespace aislado. | `make -C P9 dr-restore-test` | [log](../evidencia/restauracion/restauracion-20261017T035428Z.log) |
| **E3** | **Pérdida de un nodo**: `kubectl drain` (sin `--force`, respetando PDB) con sondeo HTTP cada 1 s. Tres corridas. | `make -C P9 dr-node-test` | [`evidencia/nodo/`](../evidencia/nodo/) |

La variante automatizada que destruye y reconstruye en la misma corrida (`dr-rebuild-test.sh`) no se ejecutó: E1 cubre la misma reconstrucción, con el desastre registrado por Azure.

## 3. Tiempos medidos

**E1** (detalle y fuentes en la [cronología](../evidencia/reconstruccion/cronologia-20261017.md)):

| Hito | UTC | Desde el lanzamiento |
| --- | --- | --- |
| Lanzamiento (`RTO_INICIO`) | 02:07:42 | 0 |
| AKS creado y 2 nodos `Ready` | 02:16:49 | 9 min 7 s |
| Llave de Sealed Secrets restaurada desde Key Vault | 02:17:01 | 9 min 19 s |
| ArgoCD disponible | 02:21:46 | 14 min 4 s |
| Datos restaurados (`Restore` `Completed`, 57 s) | 02:26:22 | 18 min 40 s |
| Plataforma lista salvo los servicios (ola -5) | 02:26:41 | 18 min 59 s |
| Servicios listos (`RTO_FIN`, observado en consola) | 03:42:09 | **94 min 27 s** |
| Primera respuesta 2xx registrada en archivo | 04:04:59 | 117 min 17 s (cota superior) |

Entre 02:26:41 y 03:35:45 (69 min) la ola 0 estuvo bloqueada por la credencial de GHCR (§5, PUF 1).

**E2**: restauración 04:02:59 → 04:04:21 = **82 s**. **E3**: ver §5.

## 4. Pérdida medida

| | Último dato recuperado | Desastre | **RPO medido** | Datos perdidos |
| --- | --- | --- | --- | --- |
| **E1** | `cron_logs` 2026-09-25 07:14:03 (respaldo `sa-p9-schedule-20260925071541`, inicio 07:15:41) | 07:29:12 | **909 s (15 min 9 s)** | 7 ejecuciones de `cron1` (07:16 a 07:28, cada 2 min) |
| **E2** | M1 `p9dr-20261017T035431Z-M1`, escrito 03:54:34.570 (respaldo `sa-p9-schedule-20261017040057`, 04:00:57–04:02:42) | 04:02:52 | **498 s (8 min 18 s)** | M2, escrito 04:02:51.237 (después del respaldo), como se esperaba |

En E1 se verificó el contenido: tras reconstruir, `cron_logs` contiene las 13 filas del 2026-09-25 (06:51:46 a 07:14:03 UTC; la aplicación escribe en UTC−6). En E2, M1 se leyó del volumen restaurado y M2 no estaba.

## 5. Puntos únicos de fallo detectados

1. **Credencial de GHCR con caducidad dentro de un SealedSecret** (E1, confirmado). La llave de Sealed Secrets funcionó y `ghcr-secret` se descifró, pero el token que contenía ya no era válido. Kyverno rechazó los Pods de los 5 servicios durante 69 min. Lo resolvió una intervención manual: token nuevo, [`rotate-ghcr-secret.sh`](../scripts/rotate-ghcr-secret.sh) y publicación en GitOps.
2. **Admission controller de Kyverno con 1 réplica** (E3, corrida 1, confirmado). Al drenar su nodo, el reemplazo no cupo y su webhook, que falla cerrado también en `DELETE`, bloqueó Pods nuevos y borrados. El drenaje no terminó en 15 min, aunque el servicio respondió el 100 % (1 740/1 740 sondeos). **Corregido**: 2 réplicas, una por nodo, con PDB.
3. **Sin capacidad N-1 con 2 nodos** (E3, corrida 2, confirmado). El drenaje terminó en 86 s con 1 355/1 355 sondeos OK, pero lo reservado (~2,7 vCPU) no cabe en un nodo de 1,9 y 13 Pods quedaron `Pending` hasta el `uncordon`. **Mitigado** con un tercer nodo `spare` (`Standard_D2s_v4`, otra familia porque la cuota de DSv2 está completa). Corrida 3 (05:43:10): drenaje en 35 s, **1 230/1 230 sondeos OK**, los 4 Deployments y los 3 StatefulSets se reprogramaron (MongoDB y NATS en el nodo `spare`). Solo 2 de las 5 réplicas del gateway quedaron `Pending` hasta el `uncordon`: su `topologySpreadConstraints` con `DoNotSchedule` no deja apilarlas en `spare` y al otro nodo le faltaban 2 m de CPU. Queda abierto: `ScheduleAnyway` en el gateway o más CPU por nodo.
4. **MySQL, MongoDB y NATS con 1 réplica y disco RWO.** En la corrida 2 MongoDB y NATS quedaron `Pending`; los sondeos no fallaron porque los endpoints de salud no consultan las bases. Sigue abierto.
5. **Una región y almacenamiento `Standard_LRS`** para el backend, el Key Vault y los respaldos.
6. **Un solo custodio** con acceso al Key Vault que guarda la llave.

Confirmado en AKS que ya no fallan los arreglos previos: la IP fija `pip-sa-p9-gateway` y `restorePVC.ignoreDelayBinding`, con la restauración terminada en 57 s.

## 6. Brecha y plan

- **RTO**: 94 min 27 s medido frente a 45 declarados, **+49 min, incumple**. La causa raíz es el PUF 1; el tramo automático hasta tener los datos restaurados tomó 19 min.
- **RPO**: E2 cumple (498 s ≤ 900). E1 **incumple por 9 s** (909 s): el peor caso real es la cadencia del Schedule más el intervalo entre escrituras previo al respaldo.

| Punto | Acción | Efecto esperado |
| --- | --- | --- |
| PUF 1 | Que `bootstrap.sh` valide `ghcr-secret` contra GHCR antes de ArgoCD, para fallar en el minuto 0 y no en el 20. Usar ACR con identidad administrada (sin token) o un token sin vencimiento con recordatorio. | Quita los 69 min de bloqueo |
| RPO | `Schedule` cada 5 min, o binlog de MySQL enviado al storage | RPO de minutos |
| PUF 4 | MySQL replicado (operador o InnoDB Cluster) o servicio gestionado | Drenaje sin corte en las rutas con estado |
| PUF 5 | `Standard_GRS` para los respaldos y el backend | Sobrevivir a la pérdida de la región |
| PUF 6 | Segundo custodio y copia del keyring en un vault de otra región | Sin dependencia de una persona |
