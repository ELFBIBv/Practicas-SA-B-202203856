# Guion del video demostrativo — Práctica 8

Duración objetivo: **7 a 7:30 min** (el enunciado pide 5-8 min). Basado en el estado real verificado el 19/09/2026:

- Corrida completa en verde: [run 35434282062](https://github.com/ELFBIBv/Practicas-SA-B-202203856/actions/runs/35434282062) (`workflow_dispatch` sobre `main`, 09:17–09:27 UTC, ~10 min: 6 tests + 7 build&push con Trivy/SBOM/Cosign + k6 + kind (canary/rollback) + Kyverno + `promote-to-gitops`).
- PR de promoción mergeado: [PR #6 "Promover sa-platform a e201a31"](https://github.com/ELFBIBv/Practicas-SA-B-202203856-gitops/pull/6) (09:27:25 UTC).
- ArgoCD sincronizó solo, automáticamente, 2 minutos después (09:29:36 UTC) — `sa-platform` en `Synced`/`Healthy`.
- Rollout `sa-platform-api-gateway`: fase `Healthy`, imagen estable `ghcr.io/elfbibv/sa-api-gateway:e201a31`, pasos 20/50/80 con `AnalysisTemplate` en cada uno.
- Kyverno: 3 `ClusterPolicy` en `Enforce` y `Ready`. Sealed Secrets: 5 secretos `SYNCED=True`.
- IP pública del gateway: `57.156.33.76`.

**No grabes esperando que el pipeline corra en vivo** (tarda ~10-12 min de punta a punta, no cabe en el video). Todo lo de arriba ya pasó hoy — el video muestra ese resultado y hace 2-3 acciones cortas en vivo (rechazo de Kyverno, verificación de firma) que sí caben en segundos.

---

## 0. Antes de grabar (checklist, fuera de cámara)

```bash
# 1. Contexto de kubectl apuntando al clúster real
az aks get-credentials --resource-group rg-practica8 --name aks-sa-p8 --overwrite-existing
kubectl config current-context   # debe decir aks-sa-p8

# 2. Confirmar que todo sigue sano (no debería tomar más de unos segundos)
kubectl get application sa-platform -n argocd
kubectl get pods -n sa-p5
kubectl get rollout -n sa-p5
kubectl get clusterpolicy
kubectl get sealedsecret -n sa-p5

# 3. Login a GHCR para que cosign pueda leer el manifiesto (el repo de paquetes es privado)
echo "TU_TOKEN_read:packages" | docker login ghcr.io -u ELFBIBv --password-stdin

# 4. Si no lo tenés, instala el plugin de rollouts para una vista más clara en cámara (opcional)
# https://argo-rollouts.readthedocs.io/en/stable/installation/#kubectl-plugin-installation
```

Pestañas de navegador abiertas y listas **antes** de grabar:

1. [Run 35434282062](https://github.com/ELFBIBv/Practicas-SA-B-202203856/actions/runs/35434282062) — la corrida completa en verde.
2. [PR #6 en el repo GitOps](https://github.com/ELFBIBv/Practicas-SA-B-202203856-gitops/pull/6) — mergeado.
3. [PR #1 en el repo de código](https://github.com/ELFBIBv/Practicas-SA-B-202203856/pull/1) — el bloqueado por Trivy (evidencia histórica, sigue siendo válida).
4. `P8/diagrama-flujo.md` renderizado en GitHub (para que se vea el Mermaid).
5. ArgoCD UI: corré `kubectl -n argocd port-forward svc/argocd-server 8080:443` en una terminal aparte y dejá `https://localhost:8080` ya logueado (`admin` + la password de `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`).
6. `P8/README.md` (para el cierre).

---

## 1. Intro (0:00 – 0:30)

**Qué decir:**

> "Hola, soy Álvaro Morales, carné 202203856. Esto es la Práctica 8: GitOps, entrega progresiva y seguridad de la cadena de suministro sobre la plataforma de microservicios de las prácticas anteriores. Voy a mostrar los 8 puntos que pide el enunciado: el repositorio GitOps, la aplicación sincronizada en ArgoCD, una ejecución exitosa del pipeline, una reversión automática por un canary defectuoso, un despliegue rechazado por política, un bloqueo por vulnerabilidad crítica, una imagen firmada y verificada, y el reporte de la prueba de carga."

**Qué mostrar:** tu cara/cámara si aplica, o directamente el README de `/P8` con la tabla de enlaces obligatoria a la vista.

---

## 2. Arquitectura: dos repos, un solo componente escribe al clúster (0:30 – 1:30)

**Qué decir:**

> "La idea central es GitOps: el repositorio de manifiestos es la única fuente de verdad, y el pipeline de CI nunca toca el clúster directamente. Ningún workflow ejecuta `kubectl apply`, `kubectl set image` ni `helm upgrade` contra Kubernetes, y no hay ningún kubeconfig guardado como secret. Lo único que hace el pipeline, cuando yo lo disparo manualmente, es abrir un Pull Request en un repositorio GitOps aparte. El único componente con permiso de escritura sobre el clúster real es ArgoCD, corriendo dentro del propio AKS."

**Qué mostrar:**
- El diagrama Mermaid de [`P8/diagrama-flujo.md`](diagrama-flujo.md) renderizado en GitHub — señalar con el mouse el punto donde el repo de código se detiene (el PR) y dónde empieza el lado de ArgoCD.
- El repo GitOps público: https://github.com/ELFBIBv/Practicas-SA-B-202203856-gitops — mostrar que es un repositorio *distinto*, con su propio chart de Helm y `argocd/application.yaml`.

**Comando opcional en terminal** (para reforzar "no hay kubeconfig en el pipeline"):
```bash
grep -rn "kubeconfig\|AZURE_CREDENTIALS\|kubectl apply\|helm upgrade" .github/workflows/ci-cd.yml
# no debería devolver ninguna línea que aplique contra el clúster real
```

---

## 3. Infraestructura como código: Terraform (1:30 – 2:00)

**Qué decir:**

> "El namespace, las cuotas de recursos, los límites y el RBAC del clúster no se crearon a mano: los administra Terraform."

**Qué mostrar:**
```bash
cat P8/terraform/apply.log | tail -20
kubectl get resourcequota,limitrange,sa,role,rolebinding -n sa-p5
```

> "Acá se ve el `ResourceQuota` y el `LimitRange` de plataforma que puso Terraform, y dos pares de ServiceAccount/Role/RoleBinding: uno de solo lectura y otro que además puede operar rollouts, pero ninguno de los dos tiene acceso a Secrets."

---

## 4. Pipeline: ejecución exitosa, de punta a punta (2:00 – 3:15)

**Qué decir:**

> "Esta es la corrida completa que disparé antes de grabar, con `workflow_dispatch` sobre `main`. Corren primero 6 jobs de prueba en paralelo, cada uno contra una base de datos real, no un mock. Cuando pasan, se construyen las 7 imágenes."

**Qué mostrar:** el [run 35434282062](https://github.com/ELFBIBv/Practicas-SA-B-202203856/actions/runs/35434282062) completo, todos los jobs en verde. Pasar el mouse por la lista: 6 tests, 7 `Build & Push`, `Prueba de carga (k6)`, `Despliegue K8s efímero (kind)`, `Kyverno: políticas de admisión`, `Proponer despliegue (PR al repo GitOps)`.

> "Entrá a uno de los jobs de `Build & Push`, por ejemplo `api-gateway`."

**Qué mostrar dentro del job** (abrir los pasos, sin leer todo el log, solo señalar los nombres):
1. `Trivy — reporte` y `Trivy — bloqueo` — "primero escanea, y si hay una CVE crítica el job se detiene *acá*, antes de publicar nada".
2. `SBOM` — "genera el inventario de software de la imagen".
3. `Publicar en GHCR` — "recién ahora se hace push, reutilizando la misma imagen que ya se escaneó, no una reconstrucción aparte".
4. `Cosign — firmar` — "firma en modo *keyless*, con el token OIDC de GitHub, sin ninguna llave privada guardada como secret".

> "Al final del run, el job `Proponer despliegue` abrió un Pull Request en el repo GitOps — no tocó el clúster."

**Qué mostrar:** el [PR #6 mergeado](https://github.com/ELFBIBv/Practicas-SA-B-202203856-gitops/pull/6), "Promover sa-platform a e201a31" — señalar que el diff es solo el tag de la imagen.

---

## 5. Bloqueo por vulnerabilidad crítica (3:15 – 3:50)

**Qué decir:**

> "Esta protección ya se activó de verdad durante el desarrollo, no es un ejercicio simulado. Este Pull Request quedó bloqueado porque Trivy encontró vulnerabilidades críticas con parche disponible en la imagen base de varios servicios."

**Qué mostrar:** [PR #1](https://github.com/ELFBIBv/Practicas-SA-B-202203856/pull/1) — el check fallido en rojo, y el job de Trivy con las 3 CVE `CRITICAL` listadas.

> "La imagen nunca llegó a publicarse en GHCR mientras esas vulnerabilidades no se corrigieron."

---

## 6. Imagen firmada y verificada (3:50 – 4:30)

**Qué decir:**

> "Cada imagen publicada queda firmada con Cosign. Esto lo estoy verificando ahora mismo, en vivo, contra el registro real."

**Comando en vivo** (ya con `docker login` hecho antes de grabar):
```bash
cosign verify \
  --certificate-identity "https://github.com/ELFBIBv/Practicas-SA-B-202203856/.github/workflows/ci-cd.yml@refs/heads/main" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/elfbibv/sa-api-gateway:e201a31 | jq .
```

> "La verificación confirma la identidad exacta: el workflow `ci-cd.yml`, corriendo sobre la rama `main` de mi repositorio, emitido por el issuer OIDC de GitHub Actions. Esta es la misma imagen que Kyverno va a exigir que esté firmada antes de admitir cualquier pod en el clúster — lo muestro en el siguiente punto."

*(Si el comando tarda o falla por red al grabar, tené ya un `cosign verify ... | jq .` corrido y guardado en una terminal como respaldo, y mostrá esa salida real en vez de recitarla de memoria.)*

---

## 7. Políticas de admisión: despliegue rechazado en vivo (4:30 – 5:15)

**Qué decir:**

> "El clúster tiene 3 políticas de Kyverno obligatorias: prohibir la etiqueta `latest` y cualquier registro que no sea el mío, exigir que el contenedor corra sin privilegios de root, y exigir que la imagen esté firmada. Las tres están en modo `Enforce`, no solo auditando."

**Comando en vivo:**
```bash
kubectl get clusterpolicy
```

> "Ahora intento correr un pod deliberadamente no conforme: la imagen pública de Nginx, `latest`, que además corre como root."

```bash
kubectl run policy-check-demo --image=nginx:latest --restart=Never -n sa-p5
```

**Qué mostrar:** el rechazo inmediato en la terminal, citando las políticas `restrict-image-registries` y `require-non-root-user` en el mensaje de error.

> "Rechazado en el acto, por dos políticas a la vez, antes de que el pod llegue a crearse."

```bash
kubectl delete pod policy-check-demo -n sa-p5 --ignore-not-found
```

---

## 8. Entrega progresiva y reversión automática (5:15 – 6:15)

**Qué decir:**

> "La promoción del `api-gateway` no es todo o nada: usa un `Rollout` de Argo Rollouts con 3 pasos, 20%, 50% y 80%, y en cada paso corre un `AnalysisTemplate` que consulta el endpoint `/health` del candidato antes de darle más tráfico."

**Comando en vivo:**
```bash
kubectl describe rollout sa-platform-api-gateway -n sa-p5
# o, si tenés el plugin instalado:
kubectl argo rollouts get rollout sa-platform-api-gateway -n sa-p5
```

> "Ahora mismo está `Healthy`, con la versión `e201a31` como estable. Pero esta protección ya se activó de verdad: en cada corrida del pipeline, el job `Despliegue K8s efímero (kind)` publica primero una versión sana y la promueve por los 3 pasos, y después publica deliberadamente una versión con `FAULT_MODE=true`, que responde HTTP 500 en `/health`."

**Qué mostrar:** abrir el job [`Despliegue K8s efímero (kind)`](https://github.com/ELFBIBv/Practicas-SA-B-202203856/actions/runs/35434282062) de la corrida de hoy, y el paso `Verificar que el canary detecta el fallo y revierte automáticamente` — mostrar el log real: el `AnalysisRun` en `Error` (`received non 2xx response code: 500`), el `Rollout` pasando a `Degraded`, y el peso del canary volviendo a `0`.

> "Argo Rollouts abortó la promoción solo, sin que nadie corriera un `kubectl rollback`, y la versión anterior siguió sirviendo el 100% del tráfico, en cuestión de segundos."

*(Nota para vos, no para decir en cámara: los timestamps exactos y el mensaje de error completo de este mismo escenario quedaron registrados en `informe-incidente.md`, por si el profesor pregunta un dato puntual.)*

---

## 9. ArgoCD: sincronización real y automática (6:15 – 6:50)

**Qué decir:**

> "Y quien aplicó el cambio de hoy al clúster real no fui yo con `kubectl`: fue ArgoCD, solo, cuando se mergeó el PR."

**Qué mostrar:** la UI de ArgoCD (`https://localhost:8080`, ya logueada) — la `Application` `sa-platform`, árbol de recursos en `Synced`/`Healthy`, y la pestaña **History and Rollback** mostrando el último sync iniciado por `automated sync policy`.

**Comando en vivo (alternativa o complemento):**
```bash
kubectl get application sa-platform -n argocd
kubectl get pods -n sa-p5
curl http://57.156.33.76/health
```

> "Respuesta real, desde una IP pública de Azure, sin `port-forward`."

---

## 10. Prueba de carga y cierre (6:50 – 7:20)

**Qué decir:**

> "Por último, cada corrida ejercita el gateway con k6: 20 usuarios virtuales concurrentes contra `/health` y las dos rutas de GraphQL, con un umbral de menos de 1% de error y menos de 500 milisegundos de latencia p95."

**Qué mostrar:**
```bash
cat P8/loadtest/reporte-referencia.json | jq '.metrics.http_req_duration, .metrics.http_req_failed'
```

**Cierre — qué decir:**

> "En resumen: el repositorio es la única fuente de verdad, ArgoCD es el único componente que escribe al clúster, ninguna imagen llega sin pasar por Trivy, SBOM y firma de Cosign, tres políticas de Kyverno bloquean lo que no cumple, los secretos viven cifrados con Sealed Secrets, y una versión defectuosa se revierte sola sin intervención humana. Gracias."

**Qué mostrar:** `P8/README.md`, tabla de enlaces obligatoria, scrolleando rápido.

---

## Después de grabar

Completar en `P8/README.md`, fila "Video demostrativo": la URL del video y el minutaje de cada punto, usando esta tabla como base:

| Punto (tabla 4.1) | Minuto aproximado |
| --- | --- |
| Repositorio GitOps | 0:30 |
| Aplicación en ArgoCD (Synced/Healthy) | 6:15 |
| Ejecución exitosa del pipeline | 2:00 |
| Reversión automática | 5:15 |
| Despliegue rechazado por política | 4:30 |
| Bloqueo por vulnerabilidad crítica | 3:15 |
| Imagen firmada | 3:50 |
| Reporte de prueba de carga | 6:50 |
