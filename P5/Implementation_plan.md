# Plan de Implementación: Práctica 5 - Orquestación avanzada de microservicios en Kubernetes con Helm

Este documento detalla los pasos y modificaciones necesarias para cumplir con todos los requerimientos de la Práctica 5 del curso de Arquitectura de Software, partiendo de los microservicios actuales de la Práctica 4.

## User Review Required

> [!IMPORTANT]
> Este plan abarca la refactorización de Dockerfiles, creación de un ecosistema completo de Helm (con dependencias externas) y configuraciones de seguridad/redes en Kubernetes.
> Por favor, revisa las tecnologías propuestas (e.g. RabbitMQ vs Kafka, k6 vs Locust) y confirma si estás de acuerdo con la selección.

## Open Questions

> [!WARNING]
> 1. **Broker de Mensajería:** ¿Prefieres usar **RabbitMQ**, **Kafka** o **NATS**? (Mi recomendación es RabbitMQ por facilidad de configuración y consumo).
> 2. **Base de Datos:** Para la base de datos central que usa StatefulSet y donde los cronjobs insertarán, ¿qué motor prefieres? (PostgreSQL, MySQL, MongoDB).
> 3. **Pruebas de Carga:** ¿Prefieres **k6**, **Locust** o **hey**? (Mi recomendación es k6 o Locust).
> 4. **Microservicios:** Veo que en tu código hay carpetas `auth-service`, `catalog-service`, `order-service` y `notifications`. ¿Cuál de ellos se modificará para implementar el consumidor asíncrono del broker? (Por ejemplo, el servicio de notificaciones es un candidato ideal).

## Proposed Changes

A continuación se dividen los cambios por componentes.

### 1. Optimización de Contenedores y Seguridad (Docker)
Para cumplir con las políticas de seguridad (`runAsNonRoot`, `readOnlyRootFilesystem`) y optimización de tamaño:

- **[MODIFY]** `auth/auth-service/Dockerfile`: Cambiar a *multi-stage build* usando una imagen base mínima (ej. `alpine` o `distroless`) y configurar un usuario no root.
- **[MODIFY]** `catalog/catalog-service/Dockerfile`: Aplicar *multi-stage build* y usuario no root.
- **[MODIFY]** `orders/order-service/Dockerfile`: Aplicar *multi-stage build* y usuario no root.
- **[MODIFY]** `notifications/Dockerfile` (o equivalente): Aplicar *multi-stage build* y usuario no root.
- **[MODIFY]** `api-gateway/Dockerfile`: Usar `nginx:alpine` como usuario no root y ajustar permisos.

### 2. Creación del Chart de Helm Padre e Infraestructura
Se creará la estructura del chart de Helm centralizado que gestionará toda la plataforma.

- **[NEW]** `charts/sa-platform/Chart.yaml`: Definición del chart versión 0.1.0 y dependencias (Bitnami RabbitMQ y Bitnami PostgreSQL/MySQL).
- **[NEW]** `charts/sa-platform/values.yaml`: Valores por defecto de toda la plataforma.
- **[NEW]** `charts/sa-platform/values-dev.yaml` y `values-prod.yaml`: Sobrescritura de valores para ambiente de desarrollo y producción (réplicas, recursos, etc).
- **[NEW]** `charts/sa-platform/values.example.yaml`: Plantilla segura sin credenciales reales para el repositorio.
- **[NEW]** `charts/sa-platform/templates/_helpers.tpl`: Funciones y *named templates* requeridos por la rúbrica.

### 3. Subcharts de Microservicios
Cada microservicio será un subchart (o formará parte de las templates del chart padre si se prefiere un enfoque centralizado, aunque la práctica sugiere "chart padre que contenga como subcharts cada uno"). Para cumplir estrictamente:

- **[NEW]** `charts/sa-platform/charts/api-gateway/` (Deployment, HPA, PDB, Service, Ingress, NetworkPolicy)
- **[NEW]** `charts/sa-platform/charts/auth/` (Deployment, HPA, PDB, Service, NetworkPolicy, Secret/ConfigMap)
- **[NEW]** `charts/sa-platform/charts/catalog/` (Deployment, HPA, PDB, Service, NetworkPolicy)
- **[NEW]** `charts/sa-platform/charts/orders/` (Deployment, HPA, PDB, Service, NetworkPolicy)
- **[NEW]** `charts/sa-platform/charts/notifications/` (Deployment, HPA, PDB, Service, NetworkPolicy)

*Todas las plantillas implementarán:*
- Probes (`liveness`, `readiness`, `startup`).
- `securityContext` restrictivo.
- Variables desde ConfigMaps y credenciales desde Secrets (inyectados como variables de entorno).
- Ingress únicamente para el API Gateway.
- NetworkPolicies que aíslan el tráfico.
- RBAC (ServiceAccount, Role, RoleBinding dedicados).

### 4. CronJobs (Trabajos Programados)
Se crearán dos scripts/imágenes ligeras para los trabajos programados, y se agregarán a Helm.

- **[NEW]** `cronjobs/cron1/`: Script que inserta el carné y la fecha en la BD cada 2 minutos.
- **[NEW]** `cronjobs/cron2/`: Script que consulta la BD, agrupa por hora y publica el mensaje en el broker cada 10 minutos.
- **[NEW]** `charts/sa-platform/templates/cronjobs.yaml`: Definición en Helm de ambos CronJobs con `concurrencyPolicy: Forbid`.

### 5. Configuración de Límite de Recursos Globales
- **[NEW]** `charts/sa-platform/templates/namespace-quotas.yaml`: `ResourceQuota` y `LimitRange` para el namespace `sa-p5`.

### 6. Comunicación Asíncrona (Código fuente)
- **[MODIFY]** Código de uno de los servicios productores (ej. `orders`) para enviar un evento al broker al crear una orden, retornando inmediatamente.
- **[MODIFY]** Código del servicio consumidor (ej. `notifications`) para suscribirse a la cola durable, procesar el evento de manera segura (ACK explícito) y manejar acumulación si está caído.

### 7. Pruebas de Carga
- **[NEW]** `scripts/load_test.js` (si usamos k6) o `locustfile.py` (si usamos Locust).

## Verification Plan

### Automated Tests & Linting
- Ejecutar `helm lint charts/sa-platform` para verificar que no hay errores ni advertencias.
- Ejecutar el build de todos los Dockerfiles y anotar el tamaño resultante para la tabla comparativa.

### Manual Verification
1. **Despliegue y Ciclo de vida:** 
   - `helm install sa-platform ./charts/sa-platform -f values-dev.yaml -n sa-p5 --create-namespace`
   - `helm upgrade` para demostrar que se aplica sin *downtime* (RollingUpdate).
   - `helm rollback` para demostrar la reversibilidad.
2. **Persistencia:** Borrar el pod de la base de datos (`kubectl delete pod`) y verificar que los datos insertados por los cronjobs o la app persisten al reiniciarse.
3. **Resiliencia (HPA):** Ejecutar el script de pruebas de carga (`k6 run scripts/load_test.js`) y observar con `kubectl get hpa -w` cómo escalan los microservicios.
4. **Seguridad (NetworkPolicies):** Levantar un pod temporal no autorizado (ej. `busybox`) e intentar hacer ping o curl a un microservicio o base de datos interno para evidenciar que el tráfico lateral está bloqueado.
5. **Comunicación asíncrona:** Apagar el consumidor (escalar a 0 réplicas), enviar peticiones al productor, encender el consumidor y verificar que procesa los mensajes acumulados.
