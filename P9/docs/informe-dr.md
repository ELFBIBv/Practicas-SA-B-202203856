# Informe de la prueba de DR — Práctica 9

> **Estado: ejecutado en AKS el 2026-10-17.** Objetivos declarados el 2026-09-24, antes de cualquier prueba ([`decisiones-pendientes.md`](decisiones-pendientes.md) §2.5); no se ajustaron después de medir. Zona horaria: **UTC** en todas las marcas. Contexto de Kubernetes: `aks-sa-p9`.

## 1. Objetivos declarados

| Objetivo | Valor | Justificación |
| --- | --- | --- |
| **RTO** | **45 min** | Creación de AKS (20-25 min en `chilecentral`) + ArgoCD y controladores (≈10 min) + restauración de PVC y arranque de servicios (≈10 min) + margen. |
| **RPO** | **15 min** | Cadencia del `Schedule` `sa-p9-schedule` (`*/15 * * * *`). |

**RTO** = lanzamiento de `bootstrap.sh` → los 4 endpoints responden 2xx. **RPO** = inicio del desastre − escritura del último dato recuperado. La duración del `Restore` **no** es el RPO.

## 2. Escenario ejecutado

La capa persistente (backend, Key Vault, storage de Velero, GitOps, GHCR) quedó intacta en las pérdidas totales.

| | Escenario | Comando | Evidencia |
| --- | --- | --- | --- |
| **E1** | **Pérdida total**: AKS, nodos y discos de los PVC borrados el 2026-09-25 07:29:12; reconstrucción el 2026-10-17. | `make -C P9 bootstrap` | [cronología](../evidencia/reconstruccion/cronologia-20261017.md), [log](../evidencia/reconstruccion/bootstrap-20261017T020742Z.log), [actividad Azure](../evidencia/reconstruccion/azure-activity-log-2026-09-25.tsv) |
| **E2** | **Pérdida lógica de datos**: marcador M1 → respaldo programado → M2 → borrado → restauración aislada. | `make -C P9 dr-restore-test` | [log](../evidencia/restauracion/restauracion-20261017T035428Z.log) |
| **E3** | **Pérdida de un nodo**: `kubectl drain` sin `--force` (respeta PDB), sondeo HTTP cada 1 s, 3 corridas. | `make -C P9 dr-node-test` | [`evidencia/nodo/`](../evidencia/nodo/) |
| **E4** | **Segunda pérdida total**: AKS borrado el 2026-10-17 05:58:45; reconstrucción a las 16:18 desde **otro equipo**. | `make -C P9 bootstrap` | [cronología](../evidencia/reconstruccion/cronologia-20261017T161840Z.md), [log](../evidencia/reconstruccion/bootstrap-20261017T161840Z.log), [actividad Azure](../evidencia/reconstruccion/azure-activity-log-2026-10-17.tsv) |

`dr-rebuild-test.sh` (destruir y reconstruir en una corrida) no se ejecutó: E1 y E4 cubren la misma reconstrucción con el desastre registrado por Azure.

## 3. Tiempos medidos

| Hito | E1 (UTC) | E1 acumulado | E4 (UTC) | E4 acumulado |
| --- | --- | --- | --- | --- |
| Lanzamiento (`RTO_INICIO`) | 02:07:42 | 0 | 16:18:40 | 0 |
| Nodos `Ready` | 02:16:49 | 9 min 7 s | 16:29:12 | 10 min 32 s |
| Llave de Sealed Secrets restaurada | 02:17:01 | 9 min 19 s | 16:29:26 | 10 min 46 s |
| ArgoCD disponible | 02:21:46 | 14 min 4 s | 16:32:11 | 13 min 31 s |
| Datos restaurados (`Restore` `Completed`) | 02:26:22 (57 s) | 18 min 40 s | 16:37:41 (60 s) | 19 min 1 s |
| Servicios listos (`RTO_FIN`) | 03:42:09 ¹ | **94 min 27 s** | 16:41:35 | **22 min 55 s** |

¹ Observado en consola, no archivado; primera respuesta 2xx en archivo a las 04:04:59 (cota superior 117 min 17 s). En E1 la ola 0 estuvo bloqueada 69 min (02:26:41 → 03:35:45) por la credencial de GHCR (§5, PUF 1). En E4 no hubo intervención: el token rotado en E1 seguía vigente.

**E2**: restauración 04:02:59 → 04:04:21 = **82 s**. **E3**: ver §5.

## 4. Pérdida medida

| | Último dato recuperado | Desastre | **RPO** | Datos perdidos |
| --- | --- | --- | --- | --- |
| **E1** | `cron_logs` 2026-09-25 07:14:03 (respaldo `sa-p9-schedule-20260925071541`, inicio 07:15:41) | 07:29:12 | **909 s** | 7 ejecuciones de `cron1` (07:16 a 07:28) |
| **E2** | M1, escrito 03:54:34.570 (respaldo `sa-p9-schedule-20261017040057`, 04:00:57–04:02:42) | 04:02:52 | **498 s** | M2 (escrito 04:02:51, después del respaldo), como se esperaba |
| **E4** | `cron_logs` 05:44:04 (respaldo `sa-p9-schedule-20261017054536`, inicio 05:45:36) | 05:58:45 | **881 s** | ≈7 ejecuciones de `cron1`; su disco se borró y no se pueden contar |

Se verificó contenido, no solo volúmenes: en E1 las 13 filas del 2026-09-25 (la aplicación escribe en UTC−6); en E2 M1 presente y M2 ausente; en E4 la última fila consultada en el clúster reconstruido.

## 5. Puntos únicos de fallo detectados

1. **Credencial de GHCR con caducidad dentro de un SealedSecret** (E1). La llave funcionó y `ghcr-secret` se descifró, pero el token ya no era válido: Kyverno rechazó los 5 servicios durante 69 min. Se resolvió a mano con un token nuevo, [`rotate-ghcr-secret.sh`](../scripts/rotate-ghcr-secret.sh) y publicación en GitOps.
2. **Kyverno con 1 réplica** (E3, corrida 1). Al drenar su nodo, su webhook (falla cerrado también en `DELETE`) bloqueó Pods nuevos y borrados; el drenaje no terminó en 15 min, aunque el servicio respondió 1 740/1 740 sondeos. **Corregido**: 2 réplicas con PDB.
3. **Sin capacidad N-1 con 2 nodos** (E3, corrida 2): drenaje en 86 s con 1 355/1 355 sondeos OK, pero ~2,7 vCPU reservadas no caben en 1,9 y 13 Pods quedaron `Pending`. **Mitigado** con un nodo `spare` (`Standard_D2s_v4`; la cuota de DSv2 está completa). Corrida 3: drenaje en 35 s, 1 230/1 230 sondeos OK, todo reprogramado salvo 2 de 5 réplicas del gateway (`DoNotSchedule` y 2 m de CPU faltantes). Abierto: `ScheduleAnyway` o más CPU.
4. **MySQL, MongoDB y NATS con 1 réplica y disco RWO**: en la corrida 2 quedaron `Pending`; los sondeos no fallaron porque los endpoints de salud no consultan las bases. Abierto.
5. **Una región y `Standard_LRS`** para backend, Key Vault y respaldos.
6. **Un solo custodio** con acceso al Key Vault de la llave.

## 6. Brecha y plan

- **RTO**: E1, 94 min 27 s frente a 45, **incumple por 49 min**; causa raíz, el PUF 1 (el tramo automático hasta datos restaurados tomó 19 min). E4 **cumple** (22 min 55 s), pero solo porque el token seguía vigente: el PUF 1 sigue abierto.
- **RPO**: E2 (498 s) y E4 (881 s) cumplen; E1 **incumple por 9 s** (909 s). El peor caso es la cadencia del Schedule más el intervalo entre escrituras previo al respaldo; E4 quedó a 19 s del límite.

| Punto | Acción | Efecto esperado |
| --- | --- | --- |
| PUF 1 | `bootstrap.sh` valida `ghcr-secret` contra GHCR antes de ArgoCD; a mediano plazo, ACR con identidad administrada | Falla en el minuto 0, sin los 69 min de bloqueo |
| RPO | `Schedule` cada 5 min, o binlog de MySQL al storage | RPO de minutos |
| PUF 4 | MySQL replicado o servicio gestionado | Drenaje sin corte en rutas con estado |
| PUF 5 | `Standard_GRS` para respaldos y backend | Sobrevivir a la pérdida de la región |
| PUF 6 | Segundo custodio y copia del keyring en otra región | Sin dependencia de una persona |
