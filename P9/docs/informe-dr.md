# Informe de la prueba de DR — Práctica 9

> **Estado: PENDIENTE DE EJECUCIÓN.** Los objetivos están declarados desde el 2026-09-24 (antes de cualquier prueba, [`decisiones-pendientes.md`](decisiones-pendientes.md) §2.5). Los campos 3 a 6 se completan **solo** con los valores que imprime `make -C P9 dr-rebuild-test CONFIRM=aks-sa-p9` ([runbook R-6](runbook-recuperacion.md#r-6-prueba-de-dr-cronometrada-destruir-y-reconstruir)). Ningún valor de abajo es estimado presentado como medido. Zona horaria: **UTC** en todas las marcas.

## 1. Objetivos declarados

| Objetivo | Valor | Justificación |
| --- | --- | --- |
| **RTO** | **45 min** | Suma de lo que el bootstrap no puede acelerar: creación de AKS (20-25 min en `chilecentral`), ArgoCD + controladores (≈10 min), restauración de PVC con data mover + arranque de bases y microservicios (≈10 min), más margen. |
| **RPO** | **15 min** | Cadencia del `Schedule` `sa-p9-schedule` (`*/15 * * * *`): el peor caso es un desastre justo antes del siguiente respaldo. |

Definiciones: **RTO** = `RTO_FIN − RTO_INICIO` (lanzamiento de `bootstrap.sh` → los 4 endpoints responden 2xx). Se reporta también la **caída total** = `RTO_FIN − DESASTRE_INICIO`. **RPO** = `DESASTRE_INICIO − escrito_utc` del último dato recuperado (marcador `M1` en `sa_p5.p9_dr_marker`, hora del servidor MySQL). La duración del `Restore` **no** es el RPO.

## 2. Escenario ejecutado

Planificado (se ejecuta con `dr-rebuild-test.sh`, en este orden):

1. Marcador `M1` → espera del siguiente Backup **programado** `Completed` → marcador `M2` (debe perderse).
2. `DESASTRE_INICIO`: `destroy-cluster.sh` destruye con Terraform la etapa `01-cluster`: resource group `rg-p9-aks` (AKS, IP, identidad) y el RG de nodos `rg-p9-aks-nodes` (VMs, discos de PVC, red). **Se conservan** (fuera del dominio de fallo): backend `rg-p9-tfstate`, Key Vault `kv-sa-p9-202203856`, storage de Velero, repo GitOps y GHCR.
3. `bootstrap.sh all` sin intervención.

**Ejecutado:** pendiente — fecha, commit y ruta del log `P9/evidencia/reconstruccion/reconstruccion-<UTC>.log`.

## 3. Tiempos medidos

| Marca | Valor (UTC) |
| --- | --- |
| `DESASTRE_INICIO` / `DESASTRE_FIN` | pendiente / pendiente |
| `RTO_INICIO` / `RTO_FIN` | pendiente / pendiente |
| Desglose (del log): AKS listo · ArgoCD disponible · cada ola cerrada · `RESTORE_OK` | pendiente |

**RTO medido** = `RTO_FIN − RTO_INICIO` = pendiente. **Caída total** = pendiente.

## 4. Pérdida medida

| Dato | Valor |
| --- | --- |
| `M1` escrito / Backup usado (inicio–fin) / `M2` escrito | pendiente |
| ¿`M1` recuperado? ¿`M2` recuperado? | pendiente |
| Último `cron_logs.execution_time` recuperado | pendiente |

**RPO medido** = `DESASTRE_INICIO − escrito_utc(M1)` = pendiente. Datos no recuperados y por qué: pendiente (se espera `M2` y todo lo escrito tras el inicio del último Backup, por cadencia de 15 min).

Prueba complementaria de restauración lógica (clúster vivo, `dr-restore-test.sh`): pendiente — `P9/evidencia/restauracion/`.

## 5. Puntos únicos de fallo detectados

Detectados en la revisión y en las corridas parciales previas (a confirmar o ampliar con la prueba):

1. **Bases de datos con 1 réplica y disco RWO** (MySQL, MongoDB, NATS): el drenaje o pérdida de su nodo corta las rutas que las usan mientras el disco se reasigna. El PDB no lo evita.
2. **Una sola región** (`chilecentral`) y `Standard_LRS` para backend, Key Vault y respaldos: un desastre regional pierde clúster y respaldos a la vez.
3. **Cuota de 3 IP públicas por región**: el ajuste publicado en el repo GitOps el 2026-09-25 reutilizaba la IP de salida de AKS por su nombre GUID, que cambia con cada clúster; una reconstrucción habría dejado el gateway `<pending>`. Corregido en código con `pip-sa-p9-gateway` (nombre fijo); **pendiente de verificar en la prueba**.
4. **Deriva entre `P9/` y el repo GitOps**: 8 archivos corregidos directamente en el repo GitOps no estaban en `P9/`; volver a publicar desde `P9/` los habría revertido (incluido `RESTORE_MODE=required`). Corregido al sincronizar la fuente; el paso R-0.5 lo verifica antes de cada prueba.
5. **Variables de identidad implícitas**: `00-persistent` exigía object IDs que solo existían en la sesión del autor. Ahora `bootstrap.sh` los deriva de `az`.
6. **Restauración bloqueada por `WaitForFirstConsumer`** (ensayo local en kind, 2026-10-16): el data mover esperaba al Pod consumidor, que solo existe en la ola posterior al Job de restauración. Habría detenido la reconstrucción a los 30 min. Corregido con `restorePVC.ignoreDelayBinding`; **pendiente de confirmar en AKS**.
7. **Custodia de la llave de Sealed Secrets**: un único custodio humano y un único vault; si se pierde el acceso al vault, los SealedSecret son irrecuperables.

## 6. Brecha y plan

Brecha RTO: pendiente (medido − 45 min). Brecha RPO: pendiente (medido − 15 min). Análisis de causa raíz: pendiente.

Plan ya identificado, independiente del resultado:

| Punto | Acción para cerrarlo | Efecto esperado |
| --- | --- | --- |
| PUF 1 | MySQL con réplica (operador o `mysql` en modo InnoDB Cluster) o servicio gestionado (Azure Database for MySQL) | Drenaje sin corte en rutas con estado |
| PUF 2 | Replicación geográfica (`Standard_GRS`) del storage de Velero y del backend | Sobrevivir a la pérdida de la región |
| RPO | Bajar el Schedule a `*/5` o binlog shipping para MySQL | RPO de minutos en vez de 15 |
| RTO | La mayor parte es creación de AKS; mantener un clúster de reserva detenido (`az aks stop`) reduce el RTO a arranque + sync | RTO de ≈15 min |
| PUF 6 | Segundo custodio con `Key Vault Secrets Officer` y copia del keyring en un vault de otra región | Sin dependencia de una persona |
