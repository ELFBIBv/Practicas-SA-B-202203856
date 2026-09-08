# Evidencias de funcionamiento

Este documento registra los resultados técnicos observados el **4 de septiembre de 2026**, tras una reinstalación limpia del release (se detectó y corrigió un bug en el token de NATS: un token aleatorio que empezaba con dígito rompía el parser de `nats.conf`; ver `templates/nats-secret.yaml`). Las capturas deben agregarse sin incluir tokens, valores de Secrets ni credenciales.

## Evidencias ya verificadas

| Evidencia | Resultado observado |
| --- | --- |
| AKS administrado | `aks-sa-p6`, `Succeeded`, región `chilecentral` |
| Nodos | 2/2 `Ready`, SKU `Standard_DS2_v2`, autoscaler fijado en 2-2 |
| Release | `sa-platform`, namespace `sa-p5`, chart `0.2.0`, revisión 1, estado `deployed` (instalación limpia) |
| Aplicaciones | API Gateway, Auth, Catalog, Orders y Notifications con 2/2 pods `Running` |
| Infraestructura | MySQL 1/1, MongoDB 1/1 y NATS 2/2 contenedores `Running` |
| HPA | Los cinco HPA reportaron métricas de CPU y mantuvieron 2 réplicas |
| PVC | Tres PVC de 2 GiB, `Bound`, `managed-csi`, `StandardSSD_LRS` |
| Acceso público | `57.156.9.223`, API Gateway `HTTP 200` |
| Healthchecks | Auth, Catalog y Orders respondieron `HTTP 200` desde internet |
| Auth | Registro `HTTP 201`; validación JWT `HTTP 200` |
| Catálogo | Producto `6a9b4f155450c3f408db6ed1` creado, `HTTP 200` |
| Órdenes | Pedido `#1`, total `51.0`, estado `PENDING`, `HTTP 200` |
| Evento asíncrono | Notifications confirmó `ORDER_CREATED` para pedido `#1` |
| CronJob 1 | Insertó el registro de `202203856` cada 2 minutos (`Complete`) |
| CronJob 2 | Programado cada 10 minutos; primera corrida aún no cumplida al momento de esta validación |
| NetworkPolicy | `azure` activo (antes `none`); un pod `busybox` sin las etiquetas autorizadas fue bloqueado al intentar llegar a MySQL y a Catalog (`wget: download timed out`) |

Respuesta pública observada:

```text
GET /                              -> healthy (HTTP 200)
GET /api/auth/health               -> Auth Service is running (HTTP 200)
GET /api/catalog/health            -> Catalog Service is running (HTTP 200)
GET /api/orders/health             -> Orders Service is running (HTTP 200)
```

Evento asíncrono observado:

```text
[NOTIFICACION ASINCRONA]: Evento 'ORDER_CREATED' procesado exitosamente para el Pedido #1
```

CronJob 1 observado:

```text
Inserted record for 202203856 at 2026-09-04 17:04:02.364133-06:00
Inserted record for 202203856 at 2026-09-04 17:06:02.302189-06:00
```

Bloqueo de NetworkPolicy observado:

```text
$ kubectl exec -n sa-p5 np-test -- wget -q -T 5 -O - http://sa-platform-mysql:3306
wget: download timed out
$ kubectl exec -n sa-p5 np-test -- wget -q -T 5 -O - http://sa-platform-catalog:8000/health
wget: download timed out
```

## Capturas obligatorias pendientes

- [ ] Vista de Azure Portal donde se observe `aks-sa-p6` y el resource group.
- [ ] `kubectl get nodes -o wide` con los dos nodos `Ready`.
- [ ] `kubectl get pods -n sa-p5 -o wide` sin pods activos en error.
- [ ] `kubectl get pvc,svc,hpa -n sa-p5`.
- [ ] Peticiones desde internet con la IP pública y códigos `200`.
- [ ] Creación del pedido y log del consumo asíncrono.
- [ ] CronJob 2 en estado `Complete` con su log (esperar a que cumpla su ciclo de 10 minutos).
- [ ] Consulta del pedido antes y después de recrear el pod de MySQL.
- [ ] Azure Cost Analysis filtrado por `rg-practica6`.
- [ ] Evidencia de eliminación del resource group después de la calificación.

## Pendientes conocidos del clúster

El bug del token de NATS y la falta de aplicación de `NetworkPolicy` (que aparecían como pendientes en la validación anterior) ya quedaron resueltos: el token ahora se genera solo con letras (`randAlpha`) y el clúster aplica `networkPolicy: azure` de forma verificada.

El costo real sigue pendiente de captura en Azure Portal (Cost Management); no debe sustituirse con una cifra inventada.
