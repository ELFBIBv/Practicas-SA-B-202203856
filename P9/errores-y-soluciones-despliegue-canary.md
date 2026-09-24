# Errores y soluciones del despliegue canary de la Práctica 8

## 1. Objetivo de este documento

Este documento reconstruye los problemas encontrados durante la implementación y validación del despliegue canary del `api-gateway` con Helm, Kubernetes, Kind y Argo Rollouts.

Para cada problema se describe:

- qué se observó;
- cuál era la causa;
- cómo se corrigió;
- por qué se eligió esa corrección;
- qué evidencia confirmó el resultado.

La reconstrucción se basa en los commits de la rama `feature/Practica8`, los manifiestos actuales y la ejecución exitosa de GitHub Actions correspondiente al commit `8f87053`.

Ejecución final:

- [GitHub Actions: fix(canary): validar la version candidata en el analisis](https://github.com/ELFBIBv/Practicas-SA-B-202203856/actions/runs/35192828463)

## 2. Resultado final

El escenario que finalmente funcionó fue el siguiente:

```text
v8.0.0: baseline inicial
    ↓
v8.0.1: candidato saludable
    ↓ 20 % → análisis correcto
    ↓ 50 % → análisis correcto
    ↓ 80 % → análisis correcto
    ↓
v8.0.1 queda como versión estable
    ↓
v8.0.2: candidato defectuoso
    ↓ primer análisis recibe HTTP 500
    ↓ AnalysisRun queda Error
    ↓ Rollout queda Degraded
    ↓ peso del canary vuelve a 0
    ↓
v8.0.1 continúa como versión estable
```

En el registro final Argo informó:

```text
RolloutAborted: Rollout aborted update to revision 3
Metric "candidate-health" assessed Error
consecutiveErrors (1) > consecutiveErrorLimit (0)
received non 2xx response code: 500
```

También mostró:

```text
Status:         Degraded
SetWeight:      0
ActualWeight:   0
Stable image:   api-gateway:v8.0.1
Updated:        0
```

Por lo tanto, la versión defectuosa `v8.0.2` no fue promovida y la revisión saludable `v8.0.1` permaneció estable.

## 3. Commits principales

| Commit | Propósito principal |
|---|---|
| `8b36a0f` | Copiar la Práctica 7 como base de la Práctica 8 |
| `bd478d6` | Preparar variantes saludable y defectuosa del gateway |
| `48262bb` | Convertir el gateway de Deployment a Rollout canary |
| `6f36839` | Adaptar el workflow a P8 y ejecutar el escenario canary en Kind |
| `e7aab89` | Corregir la instalación de los CRD de Argo Rollouts |
| `51f677d` | Reemplazar la espera genérica de Helm por esperas explícitas |
| `a30051b` | Resolver conflictos de propiedad entre Helm, Argo y el HPA |
| `d8d805d` | Esperar el estado de la generación actual del Rollout |
| `f12ac99` | Hacer estricta la detección del fallo canary |
| `e3b6f8f` | Reemplazar etiquetas mutables por versiones `v8.0.x` |
| `8f87053` | Validar la versión candidata y evitar conexiones HTTP antiguas |

Los tres primeros commits establecieron la base del ejercicio. Los siguientes fueron corrigiendo problemas encontrados durante las ejecuciones reales de GitHub Actions.

## 4. Diseño necesario para probar el fallo canary

### 4.1 Separación entre readiness y validación funcional

El gateway expone dos endpoints con propósitos diferentes en [`api-gateway/nginx.conf`](api-gateway/nginx.conf):

- `GET /ready`: responde HTTP 200 mientras Nginx pueda servir tráfico.
- `GET /health`: responde HTTP 200 en una imagen sana y HTTP 500 en una imagen construida con `FAULT_MODE=true`.

El [`api-gateway/Dockerfile`](api-gateway/Dockerfile) recibe dos argumentos:

```dockerfile
ARG APP_VERSION=0.0.0-dev
ARG FAULT_MODE=false
```

Durante la construcción reemplaza los marcadores del archivo de Nginx:

```text
FAULT_MODE=false → /health devuelve 200 y status=ok
FAULT_MODE=true  → /health devuelve 500 y status=error
```

Esta separación era necesaria porque no se quería que Kubernetes rechazara inmediatamente el pod defectuoso mediante el readiness probe. El pod debía quedar `Ready`, recibir tráfico canary y ser evaluado por Argo Rollouts.

Si `/health` también se hubiera utilizado como readiness probe, Kubernetes habría retirado el pod de los endpoints antes del análisis. Eso no demostraría una promoción canary con validación funcional, sino únicamente un pod que nunca estuvo listo.

### 4.2 Rollout, Services y AnalysisTemplate

El gateway dejó de usar un `Deployment` tradicional y pasó a usar un `Rollout` en [`charts/sa-platform/charts/api-gateway/templates/rollout.yaml`](charts/sa-platform/charts/api-gateway/templates/rollout.yaml).

La estrategia utiliza:

- un Service estable;
- un Service canary;
- pesos de 20 %, 50 % y 80 %;
- un análisis después de cada cambio de peso;
- pausas breves entre etapas.

Argo Rollouts modifica los selectores de los Services para que cada uno apunte al ReplicaSet correspondiente. El análisis consulta el Service canary, no el Service general ni el estable.

## 5. Error de permisos al ejecutar Nginx sin root

### Síntoma

Durante la preparación inicial del gateway, el contenedor podía terminar con un error similar a:

```text
mkdir() "/var/cache/nginx/client_temp" failed (13: Permission denied)
```

### Causa

El contenedor se ejecuta con el UID numérico `10001`, pero algunos directorios heredados de la imagen de Nginx no pertenecían a ese UID.

Aunque anteriormente se había creado un usuario con nombre, Kubernetes ejecutaba el proceso según el UID definido en el `securityContext`. La propiedad basada en un nombre de usuario no garantizaba que coincidiera con el UID efectivo.

### Solución

En `bd478d6` se prepararon explícitamente los directorios necesarios:

```dockerfile
RUN chown -R 10001:10001 /var/cache/nginx \
    && chown -R 10001:10001 /var/log/nginx \
    && chown -R 10001:10001 /etc/nginx/conf.d \
    && touch /var/run/nginx.pid \
    && chown 10001:10001 /var/run/nginx.pid

USER 10001:10001
```

### Por qué de esta manera

Se alineó la propiedad de los archivos con el UID real utilizado en Kubernetes. Esto mantiene el contenedor sin privilegios y evita depender de que un nombre de usuario tenga el mismo UID en todas las imágenes base.

## 6. Error instalando los CRD de Argo Rollouts

### Síntoma

La instalación del controlador de Argo Rollouts fallaba al aplicar sus CRD.

### Causa

El `kubectl apply` tradicional guarda el manifiesto aplicado en la anotación:

```text
kubectl.kubernetes.io/last-applied-configuration
```

Los CRD de Argo Rollouts son suficientemente grandes como para que esa anotación pueda superar el límite permitido por Kubernetes.

### Solución

En `e7aab89` la instalación cambió a Server-Side Apply:

```bash
kubectl apply \
  --server-side \
  --force-conflicts \
  -n argo-rollouts \
  -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
```

La implementación actual está en [`../.github/workflows/ci-cd.yml`](../.github/workflows/ci-cd.yml).

### Por qué de esta manera

Server-Side Apply no necesita almacenar todo el manifiesto en la anotación `last-applied-configuration`. La propiedad de campos queda registrada en `managedFields` dentro de Kubernetes.

Además, el clúster de Kind se crea desde cero en cada ejecución. En ese contexto, el manifiesto oficial de Argo puede considerarse la fuente autoritativa y `--force-conflicts` no pisa configuración de usuario preexistente.

## 7. Helm agotaba el tiempo esperando el Rollout

### Síntoma

El despliegue inicial podía agotar su timeout cuando se ejecutaba:

```bash
helm upgrade --install ... --wait
```

El Rollout aparecía con un estado genérico o `Unknown`, aunque el controlador de Argo sí estuviera procesándolo.

### Causa

Helm conoce cómo esperar recursos nativos como Deployments y StatefulSets. El recurso `Rollout` es un CRD y tiene estados específicos como:

- `Progressing`;
- `Paused`;
- `Healthy`;
- `Degraded`.

La espera genérica no representaba adecuadamente la semántica del controlador de Argo.

### Solución

En `51f677d` se quitó `--wait` de Helm y se separaron las esperas:

```text
Deployments  → kubectl rollout status deployment/...
StatefulSets → kubectl rollout status statefulset/...
Rollout      → scripts/wait-for-rollout.sh
```

El workflow correspondiente está en [`../.github/workflows/ci-cd.yml`](../.github/workflows/ci-cd.yml) y la espera personalizada en [`scripts/wait-for-rollout.sh`](scripts/wait-for-rollout.sh).

### Por qué de esta manera

Cada recurso es esperado con una herramienta que entiende su modelo de estado. Helm sigue instalando y actualizando los manifiestos, mientras que la sincronización de la CI se realiza explícitamente.

## 8. Conflictos de propiedad entre Helm, Argo Rollouts y el HPA

### Síntoma

Helm informó conflictos como los siguientes:

```text
conflict with "rollouts-controller" using v1: .spec.selector
conflict with "kube-controller-manager" with subresource "scale": .spec.replicas
```

Los conflictos afectaban:

- los Services estable y canary del gateway;
- el Rollout del gateway;
- los Deployments de auth, catalog, notifications y orders.

### Causa

Helm 4 utiliza Server-Side Apply por defecto para releases nuevas. Server-Side Apply registra qué administrador controla cada campo.

En este caso existían tres administradores:

```text
Helm                    → manifiestos declarativos
Argo Rollouts           → selectores de Services stable/canary
HPA / scale controller  → spec.replicas
```

Helm intentaba reclamar campos que los otros controladores modificaban de forma legítima.

### Solución

El commit `a30051b` aplicó varias correcciones relacionadas.

Primero, se fijó una versión concreta de Helm:

```yaml
- uses: azure/setup-helm@v4
  with:
    version: v4.3.0
```

Esto evita que una actualización futura de la acción cambie silenciosamente el comportamiento del pipeline.

Segundo, los despliegues utilizan:

```bash
helm upgrade --install ... --server-side=false
```

Tercero, cuando el autoscaling está habilitado, Helm deja de renderizar `spec.replicas`:

```yaml
{{- if not .Values.autoscaling.enabled }}
replicas: {{ .Values.replicaCount }}
{{- end }}
```

La misma regla se aplicó al gateway y a los Deployments administrados por un HPA.

Finalmente, los HPA quedaron parametrizados y condicionados por:

```yaml
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 5
  targetCPUUtilizationPercentage: 70
```

En el gateway, el HPA apunta al recurso correcto:

```yaml
scaleTargetRef:
  apiVersion: argoproj.io/v1alpha1
  kind: Rollout
```

Puede revisarse en [`charts/sa-platform/charts/api-gateway/templates/hpa.yaml`](charts/sa-platform/charts/api-gateway/templates/hpa.yaml).

### Por qué de esta manera

La solución aplica la regla de un responsable por campo:

- Argo Rollouts controla el hash agregado a los selectores stable/canary.
- El HPA controla `spec.replicas`.
- Helm controla la definición restante de los recursos.

Es importante distinguir este caso de la instalación de los CRD. Server-Side Apply fue útil para instalar los CRD grandes de Argo, pero no era conveniente para los recursos de la aplicación que son modificados constantemente por varios controladores.

## 9. El script podía leer el estado de una generación anterior

### Síntoma

Después de publicar una revisión nueva, el script podía observar inmediatamente `Healthy`, aunque el nuevo Rollout todavía no hubiera sido procesado.

También podía quedarse esperando `Degraded` durante todo el timeout mientras mostraba una fase que pertenecía a otra revisión.

### Causa

Las actualizaciones de Kubernetes son asíncronas.

Cuando Helm modifica el Rollout:

1. `metadata.generation` se incrementa inmediatamente.
2. Argo procesa la nueva especificación.
3. `status.observedGeneration` alcanza la nueva generación.
4. `status.phase` se actualiza para esa generación.

Durante el intervalo entre los pasos 1 y 3, `status.phase` puede conservar el valor anterior.

### Solución

En `d8d805d`, [`scripts/wait-for-rollout.sh`](scripts/wait-for-rollout.sh) comenzó a consultar:

```bash
{.metadata.generation}
{.status.observedGeneration}
{.status.phase}
```

Solo acepta el estado cuando:

```bash
generation == observedGeneration
```

También falla inmediatamente si la generación actual termina `Healthy` cuando la prueba esperaba `Degraded`:

```bash
if [[ "$generation" == "$observed_generation" && \
      "$phase" == "Healthy" && "$expected" == "Degraded" ]]; then
  exit 1
fi
```

### Por qué de esta manera

Una fase sin su generación no es suficiente para sincronizar una CI. La comparación garantiza que el estado observado pertenece exactamente al manifiesto que acaba de aplicar Helm.

Además, el fallo anticipado evita esperar 180 segundos cuando Argo ya terminó la revisión con un resultado incorrecto.

## 10. El análisis toleraba el primer fallo

### Síntoma

El candidato defectuoso no siempre terminaba inmediatamente como `Degraded`.

La configuración inicial de Kind utilizaba:

```yaml
count: 1
failureLimit: 1
consecutiveErrorLimit: 1
```

### Causa

Existían dos posibles clases de resultado negativo:

- `Failed`: la solicitud produjo un resultado evaluable, pero la condición no se cumplió.
- `Error`: el proveedor no pudo producir una medición válida; por ejemplo, una respuesta HTTP 500.

Los límites en `1` permitían tolerar el primer fallo o error. Al mismo tiempo, Kind solo realizaba una medición, por lo que la prueba no expresaba claramente la política deseada.

### Solución

En `f12ac99` la configuración cambió a:

```yaml
count: 3
failureLimit: 0
consecutiveErrorLimit: 0
```

También se mantuvo un `initialDelay: 5s` antes de comenzar las mediciones.

### Por qué de esta manera

- Un candidato saludable debe producir varias respuestas correctas, no una sola respuesta afortunada.
- Un candidato defectuoso debe rechazarse desde el primer HTTP 500.
- El retraso inicial permite que el pod, los selectores y los endpoints se estabilicen antes de consultar el Service.

La ejecución final confirmó la utilidad de `consecutiveErrorLimit: 0`: el primer HTTP 500 produjo `consecutiveErrors (1) > consecutiveErrorLimit (0)` y abortó la revisión.

## 11. Uso de etiquetas mutables o ambiguas

### Síntoma y riesgo

El proyecto todavía utilizaba `latest` en distintos valores y nombres genéricos como `healthy-v2` o `fault` para el ejercicio canary.

Esto generaba varias dificultades:

- no era evidente qué contenido correspondía a cada revisión;
- una etiqueta reutilizada podía apuntar a contenido diferente;
- `IfNotPresent` podía conservar una imagen ya disponible en el nodo;
- resultaba más difícil demostrar qué imagen estaba ejecutando cada pod.

### Solución

El commit `e3b6f8f` definió tres versiones:

```yaml
BASELINE_IMAGE_TAG: v8.0.0
HEALTHY_CANARY_IMAGE_TAG: v8.0.1
FAULT_CANARY_IMAGE_TAG: v8.0.2
```

El workflow hace lo siguiente:

1. Descarga desde GHCR las imágenes construidas para el commit.
2. Las etiqueta localmente como `v8.0.0`.
3. Construye el gateway `v8.0.1` con `FAULT_MODE=false`.
4. Construye el gateway `v8.0.2` con `FAULT_MODE=true`.
5. Carga las imágenes exactas en Kind.
6. Pasa las etiquetas a Helm mediante `--set-string`.

También se reemplazaron imágenes base mutables del servicio de notificaciones:

```dockerfile
FROM golang:1.26.4-alpine AS builder
FROM alpine:3.21
```

### Por qué de esta manera

La etiqueta forma parte del PodTemplate del Rollout. Una etiqueta nueva produce una revisión y un ReplicaSet nuevos de forma inequívoca.

Las versiones también mejoran la trazabilidad:

```text
v8.0.0 → baseline
v8.0.1 → versión promovida
v8.0.2 → versión rechazada
```

### Qué demostró esta corrección

La ejecución posterior comprobó que `v8.0.2` sí había sido construida, cargada en Kind y ejecutada por el nuevo ReplicaSet. Sin embargo, el Rollout todavía terminó `Healthy`.

Por tanto, las imágenes ambiguas eran un riesgo real que debía corregirse, pero no eran la causa final del falso positivo del análisis.

## 12. El análisis podía recibir una respuesta saludable anterior

### Síntoma

Después de todos los cambios anteriores, el comportamiento era:

```text
v8.0.2 se construyó con FAULT_MODE=true
v8.0.2 estaba cargada en Kind
los pods utilizaban v8.0.2
la generación nueva sí había sido observada
pero el Rollout terminaba Healthy
```

El análisis únicamente evaluaba:

```yaml
jsonPath: "{$.status}"
successCondition: result == "ok"
```

No comprobaba qué versión había respondido.

### Causa más probable

Argo consultaba siempre el mismo nombre DNS del Service canary. Los clientes HTTP pueden reutilizar conexiones persistentes y Kubernetes realiza el balanceo principalmente al establecer una conexión.

Al cambiar el selector del Service, una conexión que ya estuviera abierta podía continuar hablando con el pod saludable anterior. También existe un breve periodo de propagación mientras los selectores y EndpointSlices se actualizan.

El resultado era un falso positivo: el análisis recibía `status=ok`, pero esa respuesta podía no pertenecer al candidato que se estaba evaluando.

### Solución

El commit `8f87053` agregó dos defensas.

#### Primera defensa: no reutilizar la conexión

```yaml
headers:
  - key: Connection
    value: close
```

Esto obliga a cerrar la conexión después de la medición. Una solicitud posterior debe establecer una conexión nueva y volver a pasar por el Service y sus endpoints actuales.

#### Segunda defensa: validar la identidad del candidato

El AnalysisTemplate ahora recibe:

```yaml
args:
  - name: candidate-url
  - name: expected-version
```

Y evalúa el objeto JSON completo:

```yaml
successCondition: >-
  result.status == "ok" &&
  result.version == "{{ args.expected-version }}"
```

Cada etapa del Rollout pasa la etiqueta configurada:

```yaml
- name: expected-version
  value: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
```

La implementación se encuentra en:

- [`charts/sa-platform/charts/api-gateway/templates/analysis-template.yaml`](charts/sa-platform/charts/api-gateway/templates/analysis-template.yaml)
- [`charts/sa-platform/charts/api-gateway/templates/rollout.yaml`](charts/sa-platform/charts/api-gateway/templates/rollout.yaml)

### Por qué se aplicaron ambas defensas

Solo cerrar la conexión mejora el enrutamiento, pero no demuestra qué versión respondió.

Solo comparar la versión detectaría una respuesta antigua, pero el análisis seguiría dependiendo de que el enrutamiento se corrija en una medición posterior.

Con ambas defensas:

| Respuesta recibida | Resultado |
|---|---|
| `v8.0.2` responde HTTP 500 | El proveedor Web produce `Error` y Argo aborta |
| `v8.0.1` responde HTTP 200 | La versión no coincide y la condición falla |
| `v8.0.2` responde HTTP 200 y versión correcta | Solo este caso podría aprobarse |

Argo Rollouts admite los encabezados `key/value` y, cuando no se especifica `jsonPath`, utiliza el cuerpo JSON completo como `result`:

- [WebMetric de Argo Rollouts v1.10.0](https://github.com/argoproj/argo-rollouts/blob/v1.10.0/pkg/apis/rollouts/v1alpha1/analysis_types.go)
- [Documentación del proveedor Web](https://argo-rollouts.readthedocs.io/en/stable/analysis/web/)
- [Conexiones persistentes del cliente HTTP de Go](https://pkg.go.dev/net/http#Transport)

### Qué confirmó la ejecución exitosa

La ejecución final no falló por una versión incorrecta. Esta vez alcanzó realmente el endpoint defectuoso y recibió:

```text
received non 2xx response code: 500
```

Esto confirma que:

- el Service canary alcanzó al candidato defectuoso;
- el proveedor Web detectó el HTTP 500;
- `consecutiveErrorLimit: 0` abortó el análisis;
- el Rollout quedó `Degraded`;
- la versión estable siguió siendo `v8.0.1`.

La comparación de versión permanece como defensa adicional contra futuros retrasos o errores de enrutamiento.

## 13. Mejora de la evidencia diagnóstica

Antes del último cambio, el workflow ejecutaba primero:

```bash
bash P8/scripts/wait-for-rollout.sh ...
```

Como GitHub Actions ejecuta Bash con comportamiento de salida ante errores, si ese comando devolvía `1`, el paso terminaba inmediatamente. Los comandos que debían imprimir los AnalysisRuns nunca se ejecutaban.

En `8f87053` se preservó el código de salida:

```bash
verification_status=0
bash P8/scripts/wait-for-rollout.sh ... || verification_status=$?
```

Después se recopila:

- estado detallado del Rollout;
- YAML completo de los AnalysisRuns;
- selectores de los Services stable y canary;
- EndpointSlices del Service canary;
- pods, imágenes y hashes del gateway.

Finalmente se devuelve el resultado original:

```bash
exit "$verification_status"
```

### Por qué de esta manera

La recolección de evidencia no debe convertir un fallo real en éxito, pero tampoco debe perderse porque la primera comprobación terminó con error.

Por eso se guarda el resultado, se imprimen los datos de diagnóstico y al final se conserva el mismo código de salida.

## 14. Explicación de la captura final

La captura muestra cuatro comportamientos distintos de GitHub Actions.

### 14.1 `Verificar que el canary detecta el fallo y revierte automáticamente` — verde, 21 segundos

El color verde no significa que `v8.0.2` fuera saludable. Significa que la prueba negativa obtuvo el resultado esperado:

```text
fase esperada: Degraded
fase observada: Degraded
```

La secuencia registrada fue:

```text
0s  → Progressing
5s  → Progressing
10s → Progressing
15s → Progressing
20s → Degraded
```

En ese momento el script devolvió `0`, porque su objetivo era comprobar que el candidato defectuoso fuera rechazado.

Los aproximadamente 21 segundos incluyen:

- creación y disponibilidad del candidato;
- retraso inicial del análisis;
- solicitud HTTP a `/health`;
- reconciliación del estado por Argo;
- polling cada cinco segundos del script.

### 14.2 `Verificar el despliegue` — verde, 0 segundos

Ese paso tiene:

```yaml
if: always()
```

Por eso se ejecuta aunque un paso anterior falle. Su función es imprimir el inventario final:

- pods;
- PVC y Services;
- CronJobs;
- Rollout;
- AnalysisTemplate.

Los `0s` son un redondeo de GitHub Actions: los comandos terminaron en menos de un segundo. El icono verde confirma que sí se ejecutó.

Este paso no exige que el Rollout esté `Healthy`. En esta prueba, `Degraded` es deliberadamente el estado correcto.

### 14.3 `Diagnóstico si algo falló` — omitido, 0 segundos

Ese paso utiliza:

```yaml
if: failure()
```

Como la prueba canary y la verificación final terminaron correctamente, la condición fue falsa y GitHub lo marcó como `skipped`.

El círculo gris con una diagonal no representa un error. Indica que el paso no necesitaba ejecutarse.

Si un paso hubiera terminado en rojo, este diagnóstico habría mostrado:

- descripción de los pods;
- logs de los contenedores;
- descripción completa del Rollout.

### 14.4 `Post Crear clúster local con kind` — verde, 3 segundos

Este paso no aparece escrito explícitamente con ese nombre en el workflow. Es agregado automáticamente por:

```yaml
- name: Crear clúster local con kind
  uses: helm/kind-action@v1
```

La acción oficial define:

```yaml
runs:
  using: node24
  main: main.js
  post: cleanup.js
```

Al finalizar el job, GitHub ejecuta `cleanup.js` para eliminar el clúster temporal de Kind y limpiar sus recursos.

Por eso aparece con el prefijo `Post` y se ejecuta aunque no exista un paso manual con ese nombre.

Fuente:

- [helm/kind-action: action.yml](https://github.com/helm/kind-action/blob/v1/action.yml)

## 15. Por qué el job completo termina verde si se publicó una versión defectuosa

La versión defectuosa no es un fallo inesperado del pipeline; es la entrada de una prueba.

La condición que se está evaluando es:

```text
¿Argo detecta la versión defectuosa y evita promoverla?
```

Por tanto:

| Comportamiento del Rollout | Resultado del pipeline |
|---|---|
| `v8.0.2` termina `Degraded` y `v8.0.1` sigue estable | Éxito |
| `v8.0.2` termina `Healthy` | Fallo |
| El Rollout nunca termina dentro del timeout | Fallo |
| El clúster o algún servicio no puede desplegarse | Fallo |

El verde de GitHub Actions significa que el mecanismo de protección funcionó, no que la revisión defectuosa haya sido aceptada.

## 16. Diferencia entre rollback, abort y estado Degraded

En esta prueba, la expresión “revierte automáticamente” significa principalmente una reversión de tráfico y promoción:

- el candidato no se convierte en estable;
- el peso del canary vuelve a cero;
- el Service estable continúa apuntando a `v8.0.1`;
- el ReplicaSet defectuoso deja de ser la revisión activa.

El objeto Rollout queda `Degraded` para conservar evidencia de que la nueva revisión falló. No es necesario que el Rollout vuelva inmediatamente a mostrar `Healthy` para demostrar la protección.

El estado `Degraded` es útil porque hace visible que hubo una revisión rechazada y permite inspeccionar sus AnalysisRuns.

## 17. Lecciones principales

### 17.1 No basta con consultar “algún endpoint saludable”

La validación debe demostrar tanto el comportamiento como la identidad del candidato:

```text
status correcto + versión esperada
```

### 17.2 El estado de Kubernetes siempre debe asociarse a su generación

`status.phase=Healthy` por sí solo puede ser información antigua. Para automatización se debe comprobar:

```text
metadata.generation == status.observedGeneration
```

### 17.3 Los campos administrados por controladores no deben declararse desde varios lugares

- HPA controla réplicas.
- Argo controla selectores stable/canary.
- Helm controla la configuración declarativa restante.

### 17.4 Las imágenes deben ser identificables

Las etiquetas `v8.0.0`, `v8.0.1` y `v8.0.2` hicieron posible seguir cada revisión desde la construcción hasta el pod.

Para entornos reales, cada etiqueta debería tratarse como inmutable o complementarse con un digest de imagen.

### 17.5 Las pruebas negativas también deben terminar en verde

Una prueba negativa es exitosa cuando el sistema rechaza correctamente la entrada defectuosa.

En este caso:

```text
candidato defectuoso + Rollout Degraded + estable preservado = prueba exitosa
```

### 17.6 La evidencia debe recopilarse antes de finalizar el paso

Guardar temporalmente el código de salida permitió imprimir AnalysisRuns, selectores y endpoints sin ocultar el resultado real del comando de verificación.

## 18. Archivos principales para estudiar

- [`../.github/workflows/ci-cd.yml`](../.github/workflows/ci-cd.yml): flujo completo de CI/CD y escenario Kind.
- [`scripts/wait-for-rollout.sh`](scripts/wait-for-rollout.sh): sincronización por generación y fase.
- [`api-gateway/Dockerfile`](api-gateway/Dockerfile): construcción saludable o defectuosa.
- [`api-gateway/nginx.conf`](api-gateway/nginx.conf): endpoints `/ready` y `/health`.
- [`charts/sa-platform/charts/api-gateway/templates/rollout.yaml`](charts/sa-platform/charts/api-gateway/templates/rollout.yaml): estrategia canary.
- [`charts/sa-platform/charts/api-gateway/templates/analysis-template.yaml`](charts/sa-platform/charts/api-gateway/templates/analysis-template.yaml): validación de estado y versión.
- [`charts/sa-platform/charts/api-gateway/templates/service.yaml`](charts/sa-platform/charts/api-gateway/templates/service.yaml): Services general, estable y canary.
- [`charts/sa-platform/charts/api-gateway/templates/hpa.yaml`](charts/sa-platform/charts/api-gateway/templates/hpa.yaml): escalado del Rollout.
- [`charts/sa-platform/values-kind.yaml`](charts/sa-platform/values-kind.yaml): tiempos y recursos reducidos para la CI efímera.

## 19. Conclusión

No existió un único error. La solución final fue el resultado de corregir varias capas:

1. permisos del contenedor;
2. instalación de CRD;
3. espera correcta de recursos personalizados;
4. propiedad de campos entre controladores;
5. sincronización por generación;
6. tolerancia de las métricas;
7. identidad de imágenes;
8. enrutamiento y validación de la versión candidata;
9. conservación de evidencia diagnóstica.

Cada corrección eliminó una fuente distinta de incertidumbre. La última ejecución demostró el comportamiento completo: el canary saludable fue promovido, el candidato defectuoso produjo HTTP 500, Argo abortó la revisión y la versión estable permaneció atendiendo el tráfico.
