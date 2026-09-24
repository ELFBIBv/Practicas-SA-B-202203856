# Chart del API Gateway

Este chart reemplaza el `Deployment` de la Práctica 7 por un `Rollout` canary de Argo Rollouts.

## Flujo de promoción

1. Se crea la nueva ReplicaSet y se asigna el 20 % de las réplicas a la versión candidata.
2. El `AnalysisTemplate` consulta tres veces `GET /health` mediante el Service `sa-platform-api-gateway-canary`.
3. Si el resultado es `ok`, se pausa 30 segundos y avanza al 50 %.
4. Se repiten el análisis y la pausa antes de avanzar al 80 %.
5. Después del tercer análisis y su pausa, la versión candidata se promociona al 100 %.

Un código HTTP erróneo o un cuerpo cuyo campo `status` no sea `ok` hace fallar el análisis. Argo Rollouts aborta la promoción y conserva la ReplicaSet estable.

## Por qué existen tres Services

| Service | Responsabilidad |
| --- | --- |
| `sa-platform-api-gateway` | Entrada normal de usuarios; selecciona las réplicas del Rollout y conserva el nombre utilizado desde P7. |
| `sa-platform-api-gateway-stable` | Argo Rollouts le añade el hash de la ReplicaSet estable. |
| `sa-platform-api-gateway-canary` | Argo Rollouts le añade el hash de la ReplicaSet candidata; las validaciones nunca prueban accidentalmente la versión estable. |

En producción se utilizan cinco réplicas para representar exactamente el primer paso: una candidata de cinco equivale al 20 %. En `kind` se usan dos para reducir consumo, por lo que ese entorno sirve para validar los manifiestos, no para medir porcentajes exactos.
