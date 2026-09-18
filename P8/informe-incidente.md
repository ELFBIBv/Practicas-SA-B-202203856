# Informe de incidente — fallo inducido en el canary de `api-gateway`

Evidencia real, tomada del job [`Despliegue K8s efímero (kind)`](https://github.com/ELFBIBv/Practicas-SA-B-202203856/actions/runs/35374724033/job/105697632563) del run [35374724033](https://github.com/ELFBIBv/Practicas-SA-B-202203856/actions/runs/35374724033) (commit `9f7bd5e`, 2026-09-18). No es un escenario hipotético: es la corrida real del pipeline sobre un clúster `kind` efímero.

## Qué falló

Se publicó deliberadamente una segunda revisión del `Rollout` `sa-platform-api-gateway` (`api-gateway:v8.0.2`) construida con `FAULT_MODE=true`. Ese build-arg hace que el `Dockerfile` genere el `nginx.conf` de la imagen con el endpoint `/health` devolviendo **HTTP 500** (`{"status":"error",...}`) en vez de 200 — un fallo de aplicación real, no simulado a nivel de infraestructura.

## Cómo se detectó

El `AnalysisTemplate` `sa-platform-api-gateway-health` (`P8/charts/sa-platform/charts/api-gateway/templates/analysis-template.yaml`) hace que Argo Rollouts consulte `http://sa-platform-api-gateway-canary.sa-p5.svc.cluster.local/health` cada 2 segundos, con `consecutiveErrorLimit: 0` y `failureLimit: 0` — es decir, cero tolerancia: una sola respuesta no-2xx ya reprueba la métrica. El `AnalysisRun` `sa-platform-api-gateway-7b855579c7-3-1` quedó en estado `Error` con el mensaje real:

```
Error Message: received non 2xx response code: 500
```

## Cómo se contuvo

Argo Rollouts abortó automáticamente el Rollout (`Status: ✖ Degraded`, mensaje `RolloutAborted: Step-based analysis phase error/failed`) y escaló el ReplicaSet del canary a 0 réplicas (`ScaledDown`, `SetWeight: 0`, `ActualWeight: 0`). El ReplicaSet estable (`api-gateway:v8.0.1`) nunca dejó de servir el 100% del tráfico del `Service` — el `AnalysisRun` prueba al canary directamente por su propio Service interno, no mediante tráfico real de usuarios, así que **0% del tráfico de usuarios llegó a la versión defectuosa**. Ningún paso manual intervino: la contención fue enteramente automática.

## Tiempo de recuperación

Del `helm upgrade --install` que publicó la versión defectuosa (`17:38:12.735 UTC`) a la confirmación del estado `Degraded` con el canary ya en 0 réplicas (`17:38:30.410 UTC`): **17.7 segundos**. No hubo ningún período posterior de indisponibilidad que "recuperar" — el estable nunca se interrumpió.

## Cómo prevenirlo

El control que faltó es una **prueba de humo sobre la imagen ya construida, antes de publicarla**: un paso de CI que levante el contenedor recién construido y valide `GET /health -> 200` (lo mismo que hoy solo valida Argo Rollouts, pero corrido más temprano, en el job `Build & Push`, antes del `docker push` a GHCR). Con eso, una imagen que devuelve 500 en su propio healthcheck nunca llegaría siquiera a publicarse en el registry, y el canary — que ya demostró funcionar correctamente como última línea de defensa — ni se enteraría del problema.
