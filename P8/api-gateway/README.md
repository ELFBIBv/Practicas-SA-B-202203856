# API Gateway de P8

Esta copia conserva las rutas de la Práctica 7 y agrega dos endpoints con responsabilidades distintas:

- `GET /ready`: prueba de disponibilidad usada por Kubernetes. Siempre responde `200` si Nginx puede servir tráfico.
- `GET /health`: validación funcional usada por Argo Rollouts. Una imagen sana responde `200`; la versión defectuosa controlada responde `500`.

La separación permite que el pod defectuoso llegue a estar `Ready` y reciba únicamente la fracción canary. El `AnalysisTemplate` podrá detectar el error funcional en `/health` y abortar la promoción; la reversión no dependerá de que Kubernetes rechace el pod antes del análisis.

## Construir una versión sana

```bash
docker build \
  --build-arg APP_VERSION=1.0.0 \
  --build-arg FAULT_MODE=false \
  --tag sa-api-gateway:1.0.0 \
  P8/api-gateway
```

## Construir el fallo inducido

El sufijo `-faulty` es un identificador válido de *prerelease* de SemVer:

```bash
docker build \
  --build-arg APP_VERSION=1.1.0-faulty \
  --build-arg FAULT_MODE=true \
  --tag sa-api-gateway:1.1.0-faulty \
  P8/api-gateway
```

No se mantiene un archivo fuente defectuoso ni se cambia código a mano para la demostración. El mismo Dockerfile produce ambos artefactos de forma trazable, y el workflow decidirá `FAULT_MODE` a partir del tag de Git.
