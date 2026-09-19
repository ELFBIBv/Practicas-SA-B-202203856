# Cambios hacia GitOps — bitácora por fases

Este documento explica, fase por fase, los cambios hechos para que la Práctica 8 cumpla con el flujo GitOps exigido por el enunciado (`Practica_8_2S2026.md`, sección 3): el pipeline de CI nunca debe aplicar cambios directo al clúster; ArgoCD es el único componente con permiso de escritura hacia AKS, y toma esos cambios de un repositorio GitOps independiente.

## Fase 1 — Eliminar el despliegue directo y abrir el flujo de PR hacia GitOps

**Qué se hizo:**

1. Se creó el repositorio público [`ELFBIBv/Practicas-SA-B-202203856-gitops`](https://github.com/ELFBIBv/Practicas-SA-B-202203856-gitops), independiente de este repo de código. Contiene una copia del chart de Helm (`charts/sa-platform/`, sincronizada desde `P8/charts/sa-platform`) y el manifiesto `argocd/application.yaml` que ArgoCD usará para sincronizar el namespace `sa-p5`.
2. En [`.github/workflows/ci-cd.yml`](../.github/workflows/ci-cd.yml) se eliminó por completo el job `deploy-to-aks`, que hacía `az login`, `az aks get-credentials`, `kubectl apply` y `helm upgrade --install` directo contra AKS usando el secret `AZURE_CREDENTIALS`.
3. En su lugar se agregó el job `promote-to-gitops`, que:
   - Sincroniza el chart de Helm (`P8/charts/sa-platform/`) hacia el repo GitOps con `rsync`.
   - Actualiza el tag de imagen de cada servicio al commit corto recién publicado en GHCR, editando `values-azure.yaml` con `yq`.
   - Abre un Pull Request contra `main` del repo GitOps con `gh pr create`.
   - Se sigue disparando solo manualmente (`workflow_dispatch` con el checkbox `deploy`), igual que antes.

**Por qué:**

El enunciado prohíbe el despliegue directo desde el pipeline: "prohibición de despliegue directo" es un criterio eliminatorio. El patrón correcto es *pull-based*: el pipeline de CI solo construye, prueba y publica imágenes, y propone el cambio como una revisión (PR) en un repositorio de manifiestos separado. Quien aplica ese cambio al clúster es ArgoCD, corriendo dentro del propio AKS, después de que el PR se mergea. Así el pipeline de GitHub Actions deja de tener credenciales de Azure y ya no puede, aunque quisiera, tocar el clúster directamente.

**Qué queda pendiente después de esta fase (fases siguientes):**

- Instalar ArgoCD en el clúster AKS persistente y aplicar `argocd/application.yaml` del repo GitOps (requiere clúster real — ver aviso más abajo).
- Crear el secret `ghcr-secret` (imagePullSecret) en el clúster de forma declarativa, hoy solo documentado como pendiente en el README del repo GitOps.
- Terraform para namespaces, cuotas, límites y RBAC.
- Políticas de admisión (Kyverno/Gatekeeper), escaneo de vulnerabilidades bloqueante (Trivy), SBOM y firma de imágenes (Cosign).
- Prueba de carga (k6/Locust).
- Completar la tabla de enlaces obligatoria del README con evidencia real una vez que lo anterior exista.

**Acción manual requerida (no puedo hacerla yo):** para que el job `promote-to-gitops` funcione, hace falta crear el secret `GITOPS_PAT` en el repo de código, un Personal Access Token (classic) con scope `repo` que tenga permiso de escritura sobre `Practicas-SA-B-202203856-gitops`. Pasos:


```bash
# GitHub → Settings (de tu cuenta) → Developer settings → Personal access tokens →
# Tokens (classic) → Generate new token, con el scope "repo" completo.
echo "TU_TOKEN_AQUI" | gh secret set GITOPS_PAT --repo ELFBIBv/Practicas-SA-B-202203856
```

**Aviso sobre Azure:** esta fase no necesitó tocar Azure ni AKS — es un cambio puramente de CI y de estructura de repos. La próxima fase que sí lo requiere es instalar ArgoCD sobre un clúster AKS persistente y aplicar `argocd/application.yaml`; en ese punto se lo avisaré explícitamente antes de continuar, porque implica costo real por hora y acceso a un clúster que no tengo credenciales para crear ni alcanzar desde este entorno.

### Fase 1.1 — Fix: diff de PR ilegible por el round-trip de `yq`

Al probar la Fase 1 en un run real, el PR abierto en el repo GitOps mostraba decenas de líneas en blanco borradas además del cambio de tag, porque `yq -i` reescribe el YAML completo al guardar (pierde el formato original). Eso mezclaba el cambio real (7 tags) con ruido de reformateo, dificultando la revisión del PR.

**Fix:** se reemplazó `yq` por [`P8/scripts/bump-image-tag.py`](scripts/bump-image-tag.py), un script que ubica el bloque de cada servicio con una expresión regular y reemplaza únicamente su línea `tag: "..."`, sin tocar el resto del archivo. Probado localmente contra el `values-azure.yaml` real: produce exactamente 7 líneas cambiadas, nada más, y el YAML resultante sigue siendo válido. Verificado también en un run real de GitHub Actions — el PR #2 en el repo GitOps mostró el diff limpio esperado.

## Fase 2 — Terraform: namespace, cuotas, límites y RBAC

**Qué se hizo:**

Se agregó [`P8/terraform/`](terraform/), un módulo de Terraform que usa el provider `kubernetes` (no `azurerm`: el enunciado pide Terraform para lo que vive *dentro* del clúster — namespace, cuotas, límites, RBAC — no para crear el AKS en sí, que se sigue haciendo con `az aks create` como ya documentaba `P8/README.md`). Administra:

- `kubernetes_namespace.sa_platform`: el namespace `sa-p5`.
- `kubernetes_resource_quota.platform` + `kubernetes_limit_range.platform`: una cuota y un límite de **nivel de plataforma** (tenant), con nombres distintos a los que ya crea el chart de Helm (`sa-platform-quota`/`sa-platform-limits`, definidos en `templates/namespace-quotas.yaml` con los valores de `values-azure.yaml`). No son redundantes: Kubernetes exige que cada pod satisfaga *todas* las ResourceQuota de su namespace a la vez, así que esto modela un patrón real — la plataforma fija un techo (Terraform) dentro del cual la aplicación se autoimpone un presupuesto más ajustado (Helm). El razonamiento completo está en `P8/terraform/README.md`.
- Dos pares ServiceAccount + Role + RoleBinding: `sa-platform-viewer` (solo lectura: `get/list/watch` sobre pods, deployments, Rollouts, CronJobs) y `sa-platform-operator` (lo mismo, más `patch` sobre `rollouts`/`rollouts/status` para poder hacer `kubectl argo rollouts promote/abort/retry` a mano). Ninguno de los dos tiene acceso a Secrets ni permiso de borrado.

El código se validó localmente con `terraform fmt -check` y `terraform validate` (ambos en verde) — **no** se corrió `terraform plan`/`apply` contra un clúster real, porque no tengo credenciales de Azure ni acceso al AKS desde este entorno.

### Fase 2.1 — Fix: la cuota de plataforma excedía la capacidad física del clúster

Al revisar los valores por defecto de `platform_quota` (a pedido explícito, no fue algo que yo detectara antes de que se preguntara), aparecieron números elegidos sin cruzarlos contra la capacidad real del clúster: `limits_cpu: "8"` y `requests_cpu: "4"` superaban las **~3.9 vCPU asignables** que da un clúster de 2 nodos `Standard_DS2_v2` (después de las reservas de sistema de AKS), y `limits_memory: "10Gi"` ocupaba el 100% de la memoria asignable (~10Gi), sin dejar margen para `coredns`/`metrics-server`/CNI. No rompía nada (Kubernetes acepta una cuota más grande que la capacidad física sin quejarse), pero como "techo" no era real — nunca se podría alcanzar, porque el clúster se queda sin nodos antes.

**Fix:** `platform_quota` bajó a `requests_cpu: "2500m"` / `limits_cpu: "3200m"` / `requests_memory: "6Gi"` / `limits_memory: "8Gi"`, con margen real debajo de la capacidad física.

Eso dejó expuesto un segundo problema, preexistente: el `quota:` del chart de Helm (`values-azure.yaml`, `requestsCpu: "3"` / `limitsCpu: "6"`) ya era irreal para el mismo clúster de 2 nodos, y ahora además quedaba por encima del nuevo techo de plataforma, invirtiendo el diseño de dos capas (la plataforma debe ser el límite más generoso). Se ajustó también a `requestsCpu: "2"` / `requestsMemory: 5Gi` / `limitsCpu: "3"` / `limitsMemory: 7Gi` — con margen sobre el consumo real observado (~1.2-1.7 vCPU / ~1.5-2.1Gi sumando todas las réplicas, incluyendo el pico transitorio del canary) y por debajo del techo de plataforma. Verificado con `helm lint --strict` y `helm template` sobre el chart real: renderiza correctamente con los nuevos valores.

**Por qué:**

El enunciado pide explícitamente "Código Terraform: Namespaces, cuotas, límites y RBAC, con evidencia de plan y apply" como entregable propio, separado de los Helm charts. Mantener esta responsabilidad en Terraform (en vez de meterlo todo en el chart) separa dos preocupaciones distintas: gobernanza de la plataforma (quién puede entrar al namespace, cuánto puede consumir como techo) vs. despliegue de la aplicación (qué corre y con qué imagen), que es justamente el tipo de separación que la Práctica 8 evalúa.

**Acción tuya pendiente (necesito que corras esto vos, con tu acceso a Azure):**

```bash
az aks get-credentials --resource-group rg-practica8 --name aks-sa-p8 --overwrite-existing

cd P8/terraform
cp terraform.tfvars.example terraform.tfvars   # ajustar si hace falta
terraform init
terraform plan  -out=tfplan | tee plan.log
terraform apply tfplan       | tee apply.log
kubectl get resourcequota,limitrange,sa,role,rolebinding -n sa-p5
```

Guardá `plan.log`, `apply.log` y la salida de ese `kubectl get` — es la evidencia de "plan y apply" que pide la rúbrica, y hay que enlazarla desde la tabla de enlaces obligatoria de `P8/README.md`.

**Aviso sobre Azure:** esta es la primera fase que si necesita tocar un clúster real para completarse (el `terraform apply`). Yo no tengo esas credenciales ni acceso desde este entorno, así que el código queda listo y validado sintácticamente, pero el `apply` te corresponde a vos correrlo cuando tengas tiempo/crédito de tu suscripción de estudiante. Avisame el resultado (o pegame el log si algo falla) y seguimos.

## Fase 3 — Trivy bloqueante, SBOM y firma con Cosign en el pipeline

**Qué se hizo:**

En el job `build-and-push` de [`ci-cd.yml`](../.github/workflows/ci-cd.yml), el paso único "Build y push" se dividió en una secuencia de 10 pasos. Corre igual en `push` y en `pull_request` (antes, el build en PR solo validaba que el Dockerfile compilara; ahora además lo escanea):

1. **Build local** (`push: false`, `load: true`): la imagen se construye y queda solo en el runner, nada se sube a GHCR todavía.
2. **Trivy — reporte** (no bloqueante, `CRITICAL,HIGH`, JSON): se sube como artifact del run (`trivy-report-<servicio>`) pase lo que pase después — es la evidencia de "Reporte de Trivy" del enunciado.
3. **Trivy — bloqueo** (`CRITICAL`, `exit-code: 1`): si la imagen tiene una vulnerabilidad crítica, este paso falla y **todo lo que sigue se salta automáticamente** (comportamiento por defecto de GitHub Actions ante un paso fallido) — no se genera SBOM, no se publica en GHCR, no se firma nada. Esto es lo que hace cumplir el criterio "Trivy bloqueante".
4. **SBOM** (CycloneDX, vía Trivy): solo se llega acá si el paso anterior pasó. Se sube como artifact (`sbom-<servicio>`).
5. **Publicar en GHCR**: recién acá se hace `docker push` de los tags ya construidos (no se reconstruye nada, se reutiliza la imagen del paso 1).
6. **Cosign — instalar y firmar** (`cosign sign`, keyless vía OIDC de GitHub — sin manejar ninguna llave privada) + **adjuntar el SBOM** a la imagen firmada en GHCR (`cosign attach sbom`).

Los pasos 5 y 6 mantienen la misma condición que ya existía (`if: github.event_name != 'pull_request'`): en un PR se escanea y se bloquea igual, pero nunca se publica ni se firma nada, porque todavía no hay nada que "promover".

Para la firma keyless se agregó el permiso `id-token: write` al job (además de los `contents: read`/`packages: write` que ya tenía) — es lo que le permite a Cosign pedirle a GitHub un token OIDC de corta duración en vez de usar una llave privada guardada en un secret.

**Validado, no solo escrito:**
- `python3 -c "import yaml..."` → el archivo sigue siendo YAML válido.
- [`actionlint`](https://github.com/rhysd/actionlint) (el linter dedicado de GitHub Actions, no solo YAML genérico) → cero errores: valida contextos, expresiones `if`, tipos de las referencias `steps.*.outputs.*`, etc.
- Se verificó contra la API de GitHub que las versiones fijadas de las actions existen de verdad: `aquasecurity/trivy-action@v0.36.0` (el intento inicial, `@0.28.0` sin la `v`, no habría resuelto) y `sigstore/cosign-installer@v3`.
- **No** se corrió el pipeline real (eso sí lo tenés que hacer vos disparando un push/PR); lo que sí se verificó es que la definición del workflow es válida y las dependencias externas existen.

**Por qué:**

El enunciado pide "Evidencia de seguridad: Reporte de Trivy, archivo SBOM y salida de verificación de firma con Cosign" y, por separado, "Bloqueo por vulnerabilidad crítica: URL directa al Pull Request bloqueado" e "Imagen firmada: Referencia completa registro/imagen:tag" en la tabla de enlaces obligatoria. Escanear *antes* de publicar (en vez de escanear la imagen ya publicada) es lo que hace que el bloqueo sea real: una imagen con una vulnerabilidad crítica **nunca llega a existir en GHCR**, no queda ahí "publicada pero marcada como insegura".

**Nada de esto necesitó Azure ni ningún clúster** — corre íntegramente dentro de GitHub Actions. Para generar la evidencia real solo hace falta disparar el pipeline (push normal o un PR) desde `feature/Practica8`; no hay ninguna acción tuya pendiente relacionada con Azure en esta fase.

### Fase 3.1 — El bloqueo se activó de verdad (no fue un simulacro) y el fix

Al correr el pipeline real, el escaneo bloqueante hizo exactamente lo que tenía que hacer: `api-gateway` (`nginx:1.29.1-alpine`, Alpine 3.22.1) tenía 3 vulnerabilidades `CRITICAL` con parche ya publicado (`libssl3`/`libcrypto3` CVE-2026-31789, `pcre2` CVE-2025-58050), y el job se puso en rojo. Otros servicios basados en Alpine/Debian probablemente comparten el mismo tipo de problema (paquetes del sistema operativo desactualizados dentro de la imagen base, no un bug de la aplicación).

**Fix:** se agregó una línea de actualización de paquetes del SO justo después del `FROM` en la imagen final de cada Dockerfile afectado — `RUN apk update && apk upgrade --no-cache` en las bases Alpine (`api-gateway`, `auth-service`, `notification-service`) y `RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*` en las bases Debian slim (`catalog-service`, `order-service`, `cron1`, `cron2`). No cambia la versión mayor de la imagen base, solo trae los parches ya publicados para esa misma versión.

**Verificado, no solo escrito:** se construyó `api-gateway` localmente con Docker antes y después del fix, y se escaneó con Trivy real (`v0.74.0`, misma herramienta que usa el pipeline) contra la imagen ya parcheada: **0 vulnerabilidades CRITICAL** (antes: 3). Los otros 6 Dockerfile se recompilaron localmente para confirmar que el cambio no rompe el build (sí compilan); no se repitió el escaneo completo en los seis por tiempo, pero la técnica es la misma que ya se comprobó end-to-end.

Esta corrida fallida real (antes del fix) ya es evidencia legítima de "Bloqueo por vulnerabilidad crítica" para la tabla de enlaces obligatoria — vale la pena guardar la URL de ese run antes de que quede tapada por corridas más nuevas ya en verde.

### Fase 3.2 — El fix de la 3.1 no alcanzaba para todo: dos CVE más, de origen distinto

Al abrir el [PR #1](https://github.com/ELFBIBv/Practicas-SA-B-202203856/pull/1) hacia `main` (para reproducir el bloqueo como PR de verdad, ver conversación) y después aplicar el fix de la Fase 3.1, dos servicios siguieron fallando: `auth-service` y `order-service`. El `apk upgrade`/`apt-get upgrade` de la 3.1 solo cubre paquetes del sistema operativo — estas dos CVE eran de **otro origen**, cada una distinta:

- **`auth-service`:** `tar@6.2.1` (`CVE-2026-59873`) — no es una dependencia de la aplicación ni de Alpine: viene empaquetada **dentro del propio `npm`** que trae `node:20-alpine` (`/usr/local/lib/node_modules/npm/node_modules/tar`). Confirmado inspeccionando la imagen final con `docker run ... find`. Como la imagen final corre la app ya compilada vía `CMD ["node", "dist/index.js"]` — nunca usa `npm`/`npx`/`corepack` en runtime — el fix fue **eliminarlos del todo** de la imagen final (`RUN rm -rf /usr/local/lib/node_modules/npm ...`), no solo parchear `tar`. Además de resolver la CVE, reduce la superficie de ataque y el tamaño de la imagen.
- **`order-service`:** `h11@0.14.0` (`CVE-2025-43859`) — esta sí es una dependencia real de la aplicación, transitiva de `httpx==0.25.0` (usado para la llamada HTTP a `catalog-service`). `catalog-service` no tiene este problema porque no usa `httpx` (es servidor, no cliente HTTP). No alcanzaba con pinnear `h11` a mano: `httpx==0.25.0` exige una versión de `h11` incompatible con la parcheada. El fix fue subir `httpx` a `0.28.1`, que sí admite `h11>=0.16.0`.

**Verificado, no solo escrito:**
- `order-service`: se instaló `requirements.txt` completo en un venv limpio (sin conflictos, `h11` quedó en `0.16.0`) y se reconstruyó la imagen con Docker (compila bien).
- `auth-service`: se reconstruyó la imagen, se confirmó que `npm`/`tar` ya no existen en el filesystem de la imagen final, se corrió el contenedor con variables de entorno dummy y arrancó correctamente ("Auth Service is running on http://localhost:4000"), y se escaneó con Trivy real contra la imagen ya arreglada: **0 vulnerabilidades CRITICAL** (confirmado también parseando el JSON del reporte, no solo mirando la tabla).
- Antes de tocar `httpx`, se revisó el uso real en el código (`main.py`): solo `httpx.post(...)` y `httpx.RequestError`, API estable entre 0.25 y 0.28 — sin riesgo de romper nada.

**Lección para las próximas veces:** un `apk upgrade`/`apt-get upgrade` solo cubre paquetes del sistema operativo. Las vulnerabilidades en dependencias de la aplicación (`pip`, `npm`) o en herramientas empaquetadas dentro de la imagen base (como `npm` trayendo su propio `tar`) necesitan su propio fix, caso por caso — no hay un único comando que las resuelva todas.

### Fase 3.3 — El fix de `httpx` de la 3.2 rompió los tests de `order-service`

Al subir el fix de la Fase 3.2, el job "Test: order-service" empezó a fallar en la *colección* de tests (antes de llegar a ejecutar ninguno): `TypeError: Client.__init__() got an unexpected keyword argument 'app'` en `TestClient(main.app)`. Causa: `httpx==0.28.1` **eliminó por completo** el parámetro de compatibilidad `app=` que versiones viejas de Starlette (la que trae `fastapi==0.103.1`, ya bastante desactualizado) usan internamente para construir `TestClient`. No es un problema del fix de seguridad en sí — es que el salto de versión (`0.25.0` → `0.28.1`) fue más grande del necesario.

**Fix:** en vez de `httpx==0.28.1`, se bajó a `httpx==0.27.2` — la última versión de la serie 0.27, donde ese parámetro todavía existe (con warning de deprecación, pero funciona) y que **ya resuelve `h11` a `0.16.0`** igual que 0.28.1 (probado explícitamente: `httpx==0.26.0`, `0.27.0` y `0.27.2` resuelven `h11` a la misma versión parcheada; el salto más grande a 0.28 no aportaba nada extra en materia de seguridad, solo rompía compatibilidad).

**Verificado, no solo escrito:** se levantó un MySQL real en Docker (mismo esquema que usa CI, `orders-db/init.sql`), se instaló el `requirements.txt` completo con `httpx==0.27.2` en un venv limpio, y se corrieron los 3 tests de `tests/test_main.py` de punta a punta: **3 passed**. Se reconstruyó además la imagen de Docker completa y se volvió a escanear con Trivy real: sigue en **0 CRITICAL** (confirmado parseando el JSON).

**Lección para las próximas veces:** al subir una dependencia solo para resolver una CVE, conviene subir al **mínimo** que resuelve el problema, no al último release disponible — saltos más grandes traen más riesgo de romper compatibilidad con el resto del código (en este caso, con una versión vieja de Starlette que ningún commit de esta fase tocó). Y, sobre todo: verificar corriendo los tests reales, no solo instalando las dependencias — el venv sin tests habría dejado pasar este error igual.

### Fase 3.4 — Nueva CVE real, meses después: `anyio` 3.7.1 (CVE-2026-63374)

Al mergear `feature/Practica8` a `main` para disparar la corrida fresca del pipeline (después de todas las fases anteriores), Trivy bloqueó de nuevo — esta vez `catalog-service` y `order-service`, con una CVE **CRITICAL** distinta y más reciente: `CVE-2026-63374` en `anyio==3.7.1` ("TLSStream IDNA 2003 host name encoding enables potential TLS certificate spoofing"), corregida en `4.14.2`. Ni catalog ni orders fijan `anyio` directo en su `requirements.txt` — llega transitivo, y quien lo fija es `fastapi==0.103.1` (`Requires-Dist: anyio<4.0.0,>=3.7.1`), así que la 3.7.1 era simplemente la más vieja permitida por esa restricción, sin que nadie la hubiera pedido a propósito.

**Investigación antes del fix:** subir `anyio` solo (`pip install anyio>=4.14.2`) falla de inmediato con `ResolutionImpossible` contra `fastapi==0.103.1` — confirma que hay que subir `fastapi` también. Se descargaron los wheels de varias versiones de `fastapi` (`0.104.0` a `0.110.0`) y se inspeccionó su `METADATA` directamente (`unzip -p ... | grep anyio`) para encontrar la primera que **deja de fijar** `anyio`: `0.104.0`–`0.107.0` todavía tienen `anyio<4.0.0`; `0.108.0` ya no lo declara (queda a cargo de `starlette`, que si permite `<5`). Mínimo real: `fastapi==0.108.0`.

**Fix:** `fastapi==0.103.1` → `0.108.0` y `anyio>=4.14.2` fijado explícito, en los `requirements.txt` de `catalog-service` y `order-service`. Efecto colateral esperado: `starlette` sube de `0.27.0` a `0.32.0.post1` (lo exige `fastapi==0.108.0`), pero es una dependencia transitiva sana, no algo que haya que fijar a mano.

**Verificado, no solo escrito:** se instalaron ambos `requirements.txt` completos en venvs limpios (sin conflictos), se levantaron MongoDB y MySQL reales en Docker (mismo esquema que usa CI para orders), y se corrieron los tests reales de los dos servicios: **3 passed** en catalog, **3 passed** en orders. Se reconstruyeron las dos imágenes de Docker completas y se escanearon con Trivy real: **0 CRITICAL** en ambas (confirmado parseando el JSON, no solo leyendo la tabla).

**Por qué importa dejarlo anotado:** confirma que el escaneo bloqueante de Trivy sigue funcionando como control real incluso meses después de la Fase 3 — no es un cheque que se corrió una vez y se olvidó, vuelve a bloquear cada vez que aparece una CVE nueva en cualquier dependencia, directa o transitiva.

## Fase 4 — Kyverno: 3 políticas de admisión

**Qué se hizo:**

Se agregó [`P8/kyverno/policies/`](kyverno/policies/) con 3 `ClusterPolicy`:

1. **`restrict-image-registries`**: solo permite imágenes de `ghcr.io/elfbibv/*`. Rechaza cualquier cosa de Docker Hub, de otro registry o de otro owner de GHCR.
2. **`require-non-root-user`**: exige `runAsNonRoot: true` (a nivel de pod o de contenedor). Formaliza como regla del clúster algo que todos los Dockerfile del proyecto ya hacían por convención (`USER 10001`).
3. **`verify-image-signatures`**: usa la función `verifyImages` de Kyverno para exigir que la imagen esté firmada con Cosign en modo keyless por el propio workflow de CI (mismo mecanismo de la Fase 3), verificando contra el log público de Sigstore (Rekor). Es la política que más directamente conecta con lo que ya existía: sin esto, firmar las imágenes en el pipeline sería un ejercicio sin consecuencias — con esto, el clúster efectivamente exige esa firma antes de correr nada.

En `ci-cd.yml` se agregó el job `kyverno-policy-check` (corre en paralelo a `deploy-kind`, en su propio clúster kind independiente para no arriesgar ese job ya probado). Instala Kyverno vía Helm, aplica las 3 políticas, e intenta desplegar dos pods deliberadamente no conformes:
- `nginx:latest` (Docker Hub, corre como root) → debe rechazarlo `restrict-image-registries` + `require-non-root-user`.
- Una imagen propia (`ghcr.io/elfbibv/...`) pero sin `runAsNonRoot` y sin que Kyverno pueda verificar su firma en ese clúster efímero → debe rechazarla `require-non-root-user` y/o `verify-image-signatures`.

El job falla explícitamente (`exit 1`) si alguno de los dos pods **no** es rechazado — no es un test cosmético, si las políticas dejaran de funcionar el job se pone rojo.

**Validado en vivo, no solo escrito:** se instaló Kyverno de verdad en un clúster `kind` local (mismo mecanismo que usará CI) y se probaron las 3 políticas a mano:
- `kubectl run ... --image=nginx:latest` → rechazado en el acto por `restrict-image-registries` **y** `require-non-root-user` simultáneamente (mensaje de error real capturado, ver conversación).
- Se confirmó que `verify-image-signatures` **sí se activa** y evalúa imágenes de `ghcr.io/elfbibv/*`: al intentar verificar una imagen real y firmada (`sa-notification-service:9d19481`, ya publicada por el PR #1), Kyverno la rechazó porque no pudo autenticarse contra GHCR para leer la firma — comportamiento correcto y seguro por defecto (falla cerrado, no abierto). Se intentó además cablear credenciales de registry a Kyverno (`admissionController.extraArgs: --imagePullSecrets=regcred`) para probar el camino "permitido" completo, pero no se pudo cerrar el ciclo end-to-end porque el token usado tampoco tenía scope `read:packages` real — limitación del entorno de prueba, no de la política.

**Qué queda pendiente:** el camino "permitido" de `verify-image-signatures` (una imagen firmada que Kyverno logra verificar con éxito) todavía no se demostró de punta a punta. Se va a validar naturalmente cuando Kyverno se instale en el AKS real (Fase futura), donde sí va a existir un `imagePullSecret` con credenciales de lectura reales sobre GHCR (el mismo `ghcr-secret` que ya usa el chart de Helm). Mientras tanto, lo que sí quedó demostrado — y es el requisito eliminatorio real — es que las 3 políticas están activas y bloquean correctamente lo que no cumple.

**Por qué:**

El enunciado pide 3 políticas de admisión con "evidencia de un despliegue rechazado". Elegí estas 3 específicamente porque cada una cierra un círculo con algo que ya existía en fases anteriores: la restricción de registry y la verificación de firma le dan sentido real al escaneo de Trivy y a la firma de Cosign de la Fase 3 (de nada sirve escanear y firmar en el pipeline si el clúster no exige después que lo que llegue haya pasado por ese pipeline), y el requisito de usuario no-root formaliza una convención que ya estaba en el código pero que hasta ahora nadie forzaba.

**Nada de esto necesitó Azure** — se escribió y se probó íntegramente con un `kind` local. El job de CI tampoco lo necesita.

## Fase 5 — Prueba de carga con k6

**Qué se hizo:**

Se agregó [`P8/loadtest/api-gateway-load-test.js`](loadtest/api-gateway-load-test.js): una prueba de carga contra el API Gateway con un perfil de 3 etapas (calentamiento 5→carga sostenida 20 VUs→enfriamiento), que ejercita `GET /health`, `POST /api/catalog/graphql` (`{ products { ... } }`) y `POST /api/orders/graphql` (`{ orders { ... } }`) — las mismas rutas que ya expone `nginx.conf` del gateway real. Umbrales: menos de 1% de requests fallidos y p95 de latencia bajo 500ms.

En `ci-cd.yml` se agregó el job `load-test`: despliega un baseline propio en su propio clúster `kind` (independiente de `deploy-kind`, mismo motivo de aislamiento que Kyverno), expone el gateway con `kubectl port-forward`, y corre k6 contra él. El reporte (`--summary-export`) se sube como artifact.

**Validado en vivo contra el stack real, no contra un mock — y encontré 3 problemas reales en el camino:**

1. **El primer intento del propio script tenía un bug de verificación:** los `check()` solo miraban el status HTTP (`r.status === 200`). GraphQL devuelve **200 incluso cuando el resolver falla** (el error queda en el campo `errors` del body). Se comprobó a mano: con MySQL todavía no listo, `orders/graphql` devolvía `{"data": null, "errors": [...]}"` con status 200, y el check original lo daba por bueno igual. Fix: se agregó `!JSON.parse(r.body).errors` a cada check, y se probó explícitamente en ambas direcciones (con un body de error y uno sano) para confirmar que ahora sí distingue los dos casos.
2. **Los `check()` fallidos, por sí solos, no hacen fallar a k6** — solo quedan reportados, a menos que haya un threshold sobre la métrica `checks`. Se agregó `checks: ['rate>0.99']` a `thresholds`; sin este agregado, el bug del punto 1 hubiera sido invisible incluso después de corregir los checks.
3. **El job de CI tenía el mismo hueco que casi todos los anteriores: faltaba esperar a que los StatefulSets (MySQL/MongoDB/NATS) estuvieran listos antes de medir**, algo que `deploy-kind` sí hace. Comprobado desplegando el chart real en un `kind` local con las 7 imágenes reconstruidas: sin ese wait, la primera consulta a MySQL tardaba tanto en conectar que el p95 de la corrida llegó a **30 segundos** (vs. el umbral de 500ms), y `orders/graphql` literalmente no podía conectarse a la base. Con el wait agregado, mismo clúster, misma carga: p95 bajó a **15ms**, 500/500 checks en verde. Se agregó el loop de `kubectl rollout status statefulset/...` que le faltaba al job.

**Por qué:**

El enunciado pide "Pruebas automatizadas: scripts de humo, integración y carga, con sus reportes de ejecución" y, en la tabla de enlaces obligatoria, la ruta del archivo del reporte dentro del repositorio. La ruta del script queda documentada acá; el reporte de cada corrida (que cambia cada vez) se sube como artifact del run de CI, igual que se hizo con los reportes de Trivy y el SBOM en la Fase 3 — no tiene sentido versionar un archivo que se regenera en cada ejecución.

**Nada de esto necesitó Azure** — se escribió y se probó íntegramente contra un `kind` local con el chart real desplegado. El job de CI tampoco lo necesita.

**Dos errores reales que aparecieron recién en la primera corrida en GitHub Actions** (no los agarró la prueba local, porque al verificar a mano se corrieron los comandos adaptados en la propia terminal en vez del YAML tal cual, y eso tapó los dos huecos sin querer):

1. `Error: unknown flag: --server-side` — el job `load-test` usa `--server-side=false` en el `helm upgrade --install` (una flag de Helm 4), pero nunca instalaba esa versión como sí hace `deploy-kind`; corría con el Helm 3.x por defecto del runner, que no la reconoce. Fix: agregar el paso `azure/setup-helm@v4` fijando `v4.3.0`, igual que `deploy-kind`.
2. `no matches for kind "Rollout"/"AnalysisTemplate" in version "argoproj.io/v1alpha1"` — el chart de `sa-platform` define recursos de Argo Rollouts, y `load-test` nunca instalaba esos CRDs antes de desplegar. Fix: agregar el mismo paso "Instalar el controlador de Argo Rollouts" que ya tenía `deploy-kind` (sin el plugin `kubectl-argo-rollouts`, que no hace falta acá porque `load-test` no corre canary).

Se comparó el resto de los pasos de `load-test` contra `deploy-kind` uno por uno para confirmar que no quedara un tercer hueco del mismo tipo. Con ambos fixes, la corrida [35374724033](https://github.com/ELFBIBv/Practicas-SA-B-202203856/actions/runs/35374724033) terminó completa, con los 3 jobs nuevos (`kyverno-policy-check`, `load-test`, `deploy-kind`) en verde.

## Fase 6 — Informe de incidente y diagrama del flujo

**Qué se hizo:** se agregaron [`P8/informe-incidente.md`](informe-incidente.md) y [`P8/diagrama-flujo.md`](diagrama-flujo.md), los dos entregables del enunciado que no dependen de tener un AKS real levantado.

El informe de incidente usa los 5 campos exactos que pide la sección 4.2 del enunciado (qué falló, cómo se detectó, cómo se contuvo, tiempo de recuperación, cómo prevenirlo), con datos tomados directamente de los logs reales de la corrida 35374724033 — no inventados: el mensaje de error real de Argo Rollouts (`received non 2xx response code: 500`), los timestamps exactos del fallo inducido y de la contención (17.7 segundos calculados restando los dos timestamps reales), y el estado real de los `ReplicaSet`/`AnalysisRun` tras el aborto (`SetWeight: 0`, `ActualWeight: 0`, confirmando que el tráfico hacia el canario se cortó por completo en ese momento — no que haya sido 0% durante toda la ventana de análisis previa; ver la corrección de esta nota en `informe-incidente.md`, sección "Cómo se contuvo").

El diagrama es Mermaid embebido en Markdown (GitHub lo renderiza nativo, sin depender de ninguna herramienta externa ni de generar una imagen aparte). Se validó que el diagrama efectivamente renderiza sin errores de sintaxis instalando `@mermaid-js/mermaid-cli` y su Chrome headless localmente, generando un SVG real a partir del mismo bloque `mermaid` del archivo, y revisando que la estructura del SVG resultante (todos los nodos, las 3 ramas de validación en rojo, el nodo de rollback) coincidiera con lo esperado — no se asumió que iba a renderizar bien solo por tener sintaxis "razonable".

De paso se completaron con evidencia real 4 filas más de la tabla de enlaces obligatoria del README (ejecución exitosa, reversión automática, despliegue rechazado por política, imagen firmada), todas apuntando a la misma corrida 35374724033 — dejando explícito en cada una que esa evidencia es del `kind` efímero del pipeline, no de AKS todavía, para no sobrerrepresentar lo que falta.

**Por qué:** el enunciado exige exactamente 5 campos en el informe de incidente (ni más ni menos) y un diagrama "desde el commit hasta el clúster, con puntos de validación y de reversión" — ambos se pueden construir con evidencia que ya existe del pipeline, sin necesitar Azure para nada. Se dejó explícito en el diagrama que el repo de código nunca cruza hacia el clúster: todo lo que hace es proponer un PR en el repo GitOps, y quien aplica el cambio es ArgoCD — es el mismo principio de separación que ya se documentó en README-gitops.md del repo GitOps.

**Nada de esto necesitó Azure.**

## Fase 7 — Clúster AKS real y Terraform aplicado

**Qué se hizo:** se levantó el clúster de verdad, con permiso explícito del usuario y confirmando primero la cuota disponible (`az vm list-usage`) y qué suscripción quedaba activa (`az account set --subscription "Azure for Students"`, verificado con `az account list` que la otra suscripción vinculada a la cuenta — de pago — no era la default, para no gastar de ahí por error):

```bash
az group create --name rg-practica8 --location chilecentral
az aks create --resource-group rg-practica8 --name aks-sa-p8 \
  --location chilecentral --tier free --node-count 2 --node-vm-size Standard_DS2_v2 \
  --network-plugin azure --network-plugin-mode overlay --network-dataplane cilium \
  --generate-ssh-keys
```

Clúster con 2 nodos `Ready` en `chilecentral`. Luego se corrió el Terraform de `P8/terraform/` (namespace, cuotas, límites, RBAC) contra ese clúster real: `terraform init` → `terraform plan -out=tfplan` (revisado antes de aplicar: 9 recursos a crear, 0 a destruir) → `terraform apply tfplan`. Los 9 recursos se crearon sin error, y se verificaron con `kubectl get resourcequota,limitrange,sa,role,rolebinding -n sa-p5` contra el clúster real — evidencia guardada en `terraform/plan.log`, `terraform/apply.log` y `terraform/kubectl-get-evidencia.log`.

**Un detalle operativo que vale la pena dejar anotado:** al correr `az aks get-credentials`, el `~/.kube/config` local estaba corrupto (28 bytes, sin las claves `clusters`/`contexts`) — resto de haber borrado varios clústeres `kind` efímeros durante las pruebas locales de las Fases 4-6. Se respaldó (`mv` a `.bak`, no se borró) antes de dejar que `az aks get-credentials` generara uno nuevo.

**Por qué:** era el paso bloqueante para todo lo que falta (ArgoCD, Kyverno en el clúster real, Sealed Secrets, disparar el pipeline hacia AKS). Terraform no crea el clúster en sí — solo administra namespace/cuotas/RBAC dentro de uno que ya existe (ver `terraform/README.md`) — por eso el clúster se creó primero, a mano con `az aks create`, siguiendo el procedimiento ya documentado en `P8/README.md`.

## Fase 8 — ArgoCD real, sincronizando el clúster de verdad

**Qué se hizo, comando por comando:**

### 1. Instalar ArgoCD

```bash
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

El `--dry-run=client -o yaml | kubectl apply -f -` es el patrón para crear un namespace de forma idempotente (no falla si ya existe, a diferencia de `kubectl create namespace` a secas). El segundo comando es el manifiesto oficial de instalación de ArgoCD (deployments, CRDs, RBAC). **Falló**: `metadata.annotations: Too long: may not be more than 262144 bytes` en el CRD de `ApplicationSet` — el mismo límite de 256KB en la anotación `last-applied-configuration` que ya habíamos documentado para los CRDs de Argo Rollouts en el job `deploy-kind` del pipeline. Se reconoció el error al toque por ser el mismo patrón, y se resolvió igual:

```bash
kubectl apply --server-side --force-conflicts -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd wait --for=condition=available --timeout=180s deployment --all
```

`--server-side` mueve el cálculo del diff al propio API server (que no tiene ese límite de 256KB, es una limitación específica del enfoque cliente de `last-applied-configuration`). El `wait` es para no seguir hasta que los 6 deployments de ArgoCD estén realmente disponibles, no solo creados.

### 2. Leer antes de aplicar (comandos de solo lectura, nada se modificó)

```bash
gh api repos/ELFBIBv/Practicas-SA-B-202203856-gitops/contents/argocd/application.yaml --jq '.content' | base64 -d
gh api repos/ELFBIBv/Practicas-SA-B-202203856-gitops/contents/charts/sa-platform --jq '.[].name'
gh api repos/ELFBIBv/Practicas-SA-B-202203856-gitops/contents/charts/sa-platform/values-azure.yaml --jq '.content' | base64 -d
```

Antes de aplicar un `Application` de ArgoCD contra un clúster real, había que saber exactamente qué iba a hacer: a qué repo/rama/path apunta, si el chart ya tenía contenido real (sí, de una sincronización manual anterior del repo GitOps) y qué necesitaba `values-azure.yaml` para funcionar. Ahí se vio que el chart pide dos secretos (`ghcr-secret`, `sa-platform-nats-auth`) que el repo GitOps **deliberadamente no versiona en texto plano** (así lo dice su propio README).

### 3. Confirmar que los paquetes de GHCR son privados, antes de pedir un token

```bash
gh api /orgs/ELFBIBv/packages/container/sa-api-gateway   # 404, no aplica (no es org)
gh api /user/packages/container/sa-api-gateway            # 403: falta scope read:packages
docker logout ghcr.io
docker pull ghcr.io/elfbibv/sa-api-gateway:6d8d12d         # unauthorized
```

En vez de asumir que hacía falta un token y pedírselo al usuario sin más, se probó un pull completamente anónimo (`docker logout` primero, para no arrastrar ninguna sesión previa). `unauthorized` (no `not found`) confirma que el paquete es privado de verdad — si fuera público, el pull anónimo habría funcionado igual.

### 4. Crear los dos secretos que el chart necesita

```bash
NATS_TOKEN=$(openssl rand -hex 32)
kubectl create secret generic sa-platform-nats-auth -n sa-p5 --from-literal=token="$NATS_TOKEN"
```

Este lo generó el agente porque no depende de ninguna cuenta externa: es solo un valor aleatorio para que los pods de NATS se autentiquen entre ellos, nadie más lo necesita saber.

```bash
kubectl create secret docker-registry ghcr-secret -n sa-p5 \
  --docker-server=ghcr.io --docker-username=ELFBIBv --docker-password=<PAT del usuario>
```

Este lo creó el usuario, con su propio Personal Access Token de GitHub (scope `read:packages`). Generar tokens de acceso de una cuenta ajena no es algo que un agente deba hacer por su cuenta, aunque técnicamente pudiera pedirlo — es una credencial real de la persona dueña de la cuenta.

```bash
kubectl get secret ghcr-secret -n sa-p5   # solo para confirmar que ya existía antes de seguir
```

### 5. Aplicar la Application y diagnosticar por qué no sincronizaba

```bash
kubectl apply -f application.yaml
kubectl get application sa-platform -n argocd
kubectl describe application sa-platform -n argocd
```

Quedó en `OutOfSync`. El `describe` mostró la causa real en sus eventos: `Rollout.argoproj.io "" not found`, `AnalysisTemplate.argoproj.io "" not found`. El clúster `aks-sa-p8` nunca había tenido instalados los CRDs de Argo Rollouts — solo se instalaban dentro de los clústeres `kind` efímeros que usa el pipeline de CI para sus propias pruebas, nunca contra AKS. Mismo fix ya usado ahí:

```bash
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --server-side --force-conflicts -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
kubectl -n argo-rollouts wait --for=condition=available --timeout=180s deployment --all
```

### 6. Forzar el reintento sin esperar el backoff automático

```bash
kubectl annotate application sa-platform -n argocd argocd.argoproj.io/refresh=hard --overwrite
```

ArgoCD ya tenía reintentos automáticos programados (`retry.limit: 3` con backoff creciente, definido en el propio `application.yaml`), pero esperar minutos de backoff sin necesidad no tenía sentido ahora que la causa raíz (CRDs faltantes) ya estaba resuelta — este annotation le pide un refresh y reintento inmediatos.

### 7. Verificar que quedó sano de verdad, no solo "Synced"

```bash
kubectl rollout status deployment/sa-platform-auth -n sa-p5      # y catalog, notifications, orders
kubectl rollout status statefulset/sa-platform-mysql -n sa-p5    # y mongodb, nats
bash P8/scripts/wait-for-rollout.sh sa-platform-api-gateway sa-p5 Healthy 180
kubectl get pods,svc -n sa-p5
curl http://<IP-pública-del-LoadBalancer>/health
curl -X POST http://<IP-pública>/api/catalog/graphql -d '{"query":"{ products { id } }"}'
```

`Synced` en ArgoCD solo confirma que los manifiestos ya se aplicaron al clúster, no que la aplicación esté realmente sirviendo tráfico. Por eso se esperó cada componente explícitamente (deployments, luego statefulsets — mismo orden que ya se había aprendido que importa, ver Fase 5) y, al final, se le mandó tráfico HTTP real a la IP pública que Azure le asignó al `Service` tipo `LoadBalancer`, para confirmar con una respuesta real y no con el estado reportado por Kubernetes.

**Resultado:** `Synced` / `Healthy`, 7 servicios corriendo (`1/1` o `2/2` cada uno), Rollout del gateway en fase `Healthy`, respuestas reales de `/health` y de la GraphQL de `catalog` desde una IP pública de internet — no `port-forward`, no `kind`.

**Por qué:** es el corazón del entregable de la práctica — que ArgoCD, no el pipeline de CI, sea quien aplica cambios al clúster real. Con esto, la separación que ya estaba documentada en el README del repo GitOps (el pipeline de código nunca toca AKS directamente) queda demostrada en la práctica, no solo escrita.

### 8. Entrar a la UI de ArgoCD y sacar la evidencia visual

ArgoCD, por defecto, expone su servidor (`argocd-server`) como `ClusterIP` — sin IP pública, a propósito: su usuario `admin` puede modificar cualquier cosa del clúster, y dejarlo abierto a todo internet sin SSO/autenticación adicional sería un riesgo real que no tenía sentido asumir solo para esta entrega. Para llegar a la UI sin exponerla, se usó el mecanismo estándar de `kubectl`, un túnel autenticado contra el propio API server de AKS (no expone nada nuevo hacia afuera):

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

El primer comando saca la contraseña autogenerada del usuario `admin` (Secret que ArgoCD crea solo en su primera instalación); el `; echo` es solo para que el prompt no quede pegado al valor decodificado, ya que `base64 -d` no agrega salto de línea. El segundo abre el túnel: quien entra a `https://localhost:8080` en su navegador en realidad está hablando, a través de ese túnel, con el pod `argocd-server` corriendo en Azure — no hay ningún servidor corriendo localmente (se explicó la mecánica completa en la conversación, dado que no era obvio a primera vista).

Con la sesión iniciada (`admin` + esa contraseña), se sacaron dos capturas reales, guardadas en [`P8/evidencia/`](evidencia/):

- [`argocd-sync.png`](evidencia/argocd-sync.png): vista de árbol de recursos de la `Application` — `Healthy`/`Synced`, con cada componente (`sa-platform-auth`, `sa-platform-catalog`, `sa-platform-notifications`, `sa-platform-orders`, cuotas, límites) mostrando su propio estado de salud.
- [`argocd-historial.png`](evidencia/argocd-historial.png): pestaña "History and Rollback", detalle del último sync — iniciado por `automated sync policy` (no a mano), 1m35s de duración, y el mismo commit "Merge pull request #2 from ELFBIBv/promote/6d8d12d" que se describe abajo.

**Hallazgo al revisar esa captura:** el mensaje del commit sincronizado (`Merge pull request #2 from ELFBIBv/promote/6d8d12d`) llevó a revisar el [PR #2 del repo GitOps](https://github.com/ELFBIBv/Practicas-SA-B-202203856-gitops/pull/2) con `gh pr view 2 --repo ELFBIBv/Practicas-SA-B-202203856-gitops --json title,url,mergedAt,body,commits`. Confirma que el job `promote-to-gitops` del pipeline **ya se había disparado y mergeado de verdad** (autor `sa-platform-ci`, el bot configurado en ese job), el 18/09 04:08 UTC — antes de que ArgoCD existiera en este clúster. O sea: el mecanismo "CI abre PR → se mergea" ya estaba probado de punta a punta; lo que faltaba, y se completó hoy, era tener un ArgoCD real esperando para recogerlo.

**Qué queda pendiente de esta fase:** aunque el mecanismo de PR ya se probó una vez (PR #2, antes de esta sesión), no hubo todavía una corrida fresca de `workflow_dispatch` que dispare ese mismo flujo con **todo lo que se agregó después** (Kyverno, k6, informe de incidente) y que ArgoCD la sincronice en vivo mientras está corriendo — eso es lo que falta para una evidencia end-to-end completamente actual. Los dos secretos (`ghcr-secret`, `sa-platform-nats-auth`) siguen siendo secretos planos creados a mano, no Sealed Secrets — esa migración sigue pendiente.

## Fase 9 — Kyverno en el clúster real, incluyendo el camino "permitido" completo

**Qué se hizo:** se instaló Kyverno en `aks-sa-p8` (mismo mecanismo que en `kind`, Fase 4) y se aplicaron las 3 políticas de `P8/kyverno/policies/`:

```bash
helm install kyverno kyverno/kyverno -n kyverno --create-namespace --wait --timeout 180s
kubectl apply -f P8/kyverno/policies/
```

**Caso rechazado, contra el clúster real:**

```bash
kubectl run policy-check-external-image --image=nginx:latest --restart=Never
```

Rechazado en el acto por `restrict-image-registries` y `require-non-root-user` simultáneamente — mismo resultado que ya se había probado en `kind`, ahora confirmado contra AKS.

**Caso permitido — esta vez sí se pudo cerrar del todo, a diferencia de la Fase 4:** en `kind` no se había podido probar el camino "permitido" de `verify-image-signatures` porque ningún token a mano tenía scope `read:packages` real. Acá sí, porque ya existe `ghcr-secret` en `sa-p5` con el PAT real del usuario. El problema es que Kyverno necesita sus propias credenciales de registry — no las del pod que se está evaluando — así que hubo que dárselas al propio controlador de Kyverno:

```bash
# Copiar el secret ya existente al namespace donde vive el admission controller de Kyverno
kubectl get secret ghcr-secret -n sa-p5 -o json | \
  python3 -c "import json,sys; d=json.load(sys.stdin); d['metadata']={'name':'ghcr-secret','namespace':'kyverno'}; print(json.dumps(d))" | \
  kubectl apply -f -

# helm show values kyverno/kyverno reveló el campo correcto: no es un --extraArgs
# (eso se había probado sin éxito en la Fase 4), es un valor raíz del chart:
helm upgrade kyverno kyverno/kyverno -n kyverno --reuse-values \
  --set existingImagePullSecrets[0]=ghcr-secret --wait --timeout 180s
```

Con eso wireado, se probó primero con la imagen que el chart tiene desplegada hoy (`sa-notification-service:6d8d12d`): Kyverno **sí logró autenticarse** (el error cambió de `UNAUTHORIZED: authentication required` a `no signatures found` — prueba de que la credencial ya funcionaba), pero esa build en particular no tenía firma asociada. Se repitió con una imagen que sí se había confirmado firmada en esta misma sesión (`ghcr.io/elfbibv/sa-api-gateway@sha256:0d4942874e...`, la misma referencia de la fila "Imagen firmada" del README):

```bash
kubectl run policy-check-signed2 \
  --image="ghcr.io/elfbibv/sa-api-gateway@sha256:0d4942874e02de72c2092a554fba5ed3e1da8b1331091c38ccb3a8bc262b9763" \
  --overrides='{"spec":{"containers":[{"...","securityContext":{"runAsNonRoot":true,"runAsUser":10001}}]}}' \
  --dry-run=server
# → pod/policy-check-signed2 created (server dry run)
```

**Admitido.** Con esto quedan demostradas las 3 políticas en ambas direcciones, contra el clúster real: rechazan lo que no cumple y permiten lo que sí — incluyendo la verificación criptográfica real de la firma de Cosign, que en la Fase 4 había quedado como pendiente por una limitación de credenciales del entorno de prueba, no de la política en sí.

**Por qué:** cerraba una brecha real: en la Fase 4 se dejó documentado explícitamente que el camino "permitido" de `verify-image-signatures` no se había probado por falta de credenciales, y que se completaría "cuando Kyverno se instale en el AKS real". Este es exactamente ese momento.

## Fase 10 — Sealed Secrets: los dos secretos ya no son texto plano

**Qué se hizo:** se instaló el controlador de Sealed Secrets y se migraron `ghcr-secret` y `sa-platform-nats-auth` (creados a mano en la Fase 8) a `SealedSecret` cifrados, verificando el ciclo completo — no solo que "se aplicó sin error".

```bash
# El repo de Helm de Bitnami se movió de bitnami-labs a bitnami (redirect 301
# confirmado); con la URL vieja el repo daba 404.
helm repo add sealed-secrets https://bitnami.github.io/sealed-secrets
helm install sealed-secrets-controller sealed-secrets/sealed-secrets -n kube-system --wait --timeout 180s
```

Se instaló también el CLI `kubeseal` (binario oficial de GitHub Releases, mismo patrón que k6/terraform/kind en fases anteriores). Para cada secreto, se tomó el contenido real ya existente en el clúster (no se volvió a pedir el token de GHCR ni se regeneró el de NATS) y se cifró contra la clave pública del controlador:

```bash
kubectl get secret <nombre> -n sa-p5 -o json | python3 -c "..." | \
  kubeseal --controller-name=sealed-secrets-controller --controller-namespace=kube-system --format yaml \
  > <nombre>-sealed.yaml
```

**Verificación real, no solo "se aplicó":** al aplicar el `SealedSecret` con el mismo nombre/namespace que el `Secret` plano ya existente, el controlador **se negó a pisarlo** (`"already exists and is not managed by SealedSecret"`) — comportamiento de seguridad esperado, no un bug: no adopta secretos que no creó él. Para completar la migración había que borrar el plano primero y dejar que el `SealedSecret` lo regenerara:

```bash
kubectl delete secret ghcr-secret -n sa-p5
kubectl delete sealedsecret ghcr-secret -n sa-p5   # forzar reconciliación; un "apply" sin cambios no dispara reintento
kubectl apply -f ghcr-secret-sealed.yaml
```

Con eso, `kubectl get sealedsecret` mostró `SYNCED: True` y el `Secret` resultante pasó a tener `ownerReferences` apuntando al `SealedSecret`. Se comparó el `.dockerconfigjson` descifrado contra el original (`diff` entre ambos, decodificados de base64) — **idéntico**. Se repitió el mismo procedimiento para `sa-platform-nats-auth`. Después de migrar los dos, se confirmó que la `Application` de ArgoCD seguía `Synced`/`Healthy` y que los pods de `sa-p5` seguían corriendo sin interrupciones.

Los dos archivos `SealedSecret` resultantes (cifrados, seguros de versionar) se prepararon en un clon local del repo GitOps, en una carpeta nueva `sealed-secrets/` con su propio README explicando cómo se generan y qué pasa si el clúster se recrea desde cero. **No se publicaron** — en un entorno académico, con la migración ya verificada funcionando de punta a punta contra el clúster real (que es lo que demuestra la práctica), no había necesidad real de además abrir un PR y mergearlo en un repositorio aparte solo para dejar una copia de los mismos archivos cifrados. El paso 4 del procedimiento del README documenta igual cómo se generarían y aplicarían, para quien sí lo necesite.

**Por qué:** el propio README del repo GitOps ya dejaba anotado desde la Fase 8 que los secretos creados a mano eran un paso intermedio, pendiente de migrar. Con Sealed Secrets, el valor cifrado sí puede vivir en el repo público sin exponer nada — solo el controlador del clúster real puede descifrarlo — cerrando la única pieza de la cadena de suministro que hasta ahora dependía de un paso manual fuera de cualquier control de versiones.

## Fase 11 — Bug real en Cosign: se firmaba el digest equivocado

**Qué pasó:** al mergear el PR #3 del repo GitOps (la primera corrida fresca de punta a punta, con Kyverno ya instalado en el clúster real desde la Fase 9), ArgoCD falló el sync con `1 Error`, `App Health: Degraded`. El mensaje real:

```
admission webhook "mutate.kyverno.svc-fail" denied the request:
resource Deployment/sa-p5/sa-platform-auth was blocked due to the following policies
verify-image-signatures:
  autogen-verify-signature: 'failed to verify image ghcr.io/elfbibv/sa-auth-service:d9044d7:
  ... UNAUTHORIZED: authentication required' (retried 3 times)
```

**Primer diagnóstico (y primer callejón sin salida):** parecía el mismo problema de credenciales de la Fase 9. Se verificó que el token seguía siendo válido (`docker login` + `docker pull` reales con exactamente esas credenciales: funcionaron perfecto) y que el flag `--imagePullSecrets=ghcr-secret` seguía presente en el deployment de Kyverno. Se probó igual reiniciar el pod del admission controller por si había cacheado un token de GHCR vencido (esos tokens duran pocos minutos) — `kubectl rollout restart deployment kyverno-admission-controller -n kyverno`. Con eso el error **cambió**, de `UNAUTHORIZED` a `no signatures found`: confirma que sí era un tema de caché de autenticación, pero destapó un problema distinto y más serio debajo.

**El problema real:** se comparó el digest que Kyverno intentaba verificar contra lo que de verdad estaba publicado en GHCR:

```bash
docker buildx imagetools inspect ghcr.io/elfbibv/sa-auth-service:d9044d7 --format '{{json .Manifest}}'
# digest real publicado: sha256:cc4a9ee6...

docker buildx imagetools inspect ghcr.io/elfbibv/sa-auth-service:sha256-cc4a9ee6....sig
# ERROR: not found — no existe firma para ese digest
```

Revisando el log real del job `Build & Push: auth-service` de esa corrida, el paso "Firmar la imagen con Cosign" sí reportó éxito — pero firmó otro digest: `sha256:b71e14c4...`, que es el digest de **`steps.build.outputs.digest`**, el de la build *local* (`push: false, load: true`) que se hace para poder escanear con Trivy antes de publicar nada. El digest que de verdad queda publicado tras el `docker push` (`cc4a9ee6...`) es distinto — BuildKit agrega provenance/attestations al pushear que cambian el digest del manifest respecto al build local. El pipeline llevaba firmando el digest equivocado **desde la Fase 3**, y nadie lo había notado porque hasta la Fase 9 nada verificaba la firma contra el digest realmente publicado — Cosign reportaba éxito igual, solo que firmando una referencia que nunca llegó a existir en el registry bajo ese digest.

**Fix real, en `ci-cd.yml`:** capturar el digest **después** del `docker push`, no reusar el del build local:

```bash
# en el step "Publicar en GHCR", después de pushear cada tag:
digest=$(docker inspect --format='{{index .RepoDigests 0}}' "$first_tag" | sed 's/^.*@//')
echo "digest=$digest" >> "$GITHUB_OUTPUT"
# y en "Firmar la imagen con Cosign": DIGEST="${{ steps.push.outputs.digest }}"
# en vez de steps.build.outputs.digest
```

**Verificado antes de aplicar el fix, no a ciegas:** se confirmó a mano que `docker inspect --format='{{index .RepoDigests 0}}'` sobre la imagen recién pusheada sí devuelve el digest real y correcto (`cc4a9ee6...`), coincidiendo con lo que reporta `docker buildx imagetools inspect` contra el registry.

**Por qué importa:** esto es exactamente el tipo de bug que **Kyverno existe para atrapar** — la cadena de suministro llevaba meses "firmando" imágenes cuya firma nunca hubiera pasado una verificación real, porque nada la verificaba de verdad hasta que se instaló Kyverno contra el clúster real con `verifyImages` activo. Es la mejor evidencia posible de por qué la política 3 (`verify-image-signatures`) no es un ejercicio cosmético: encontró un bug real que Trivy, los tests y el resto del pipeline nunca hubieran detectado.

**Qué falta:** disparar de nuevo `workflow_dispatch` con este fix ya en `main`, para que las imágenes se firmen con el digest correcto esta vez, y repetir el ciclo PR al repo GitOps → merge → ArgoCD sincroniza — ahora sí debería quedar `Synced`/`Healthy` sin el error de Kyverno.

## Fase 12 — Revisión externa (Codex): 7 hallazgos, verificados y corregidos

**Qué pasó:** se compartió una revisión de otro asistente (Codex) sobre el estado del proyecto en este punto. Antes de tocar nada se verificó cada hallazgo contra el código y el clúster real — no se asumió que la revisión tuviera razón solo por venir de otra IA. Los 7 resultaron reales. Se corrigieron los 7, incluyendo dos (Auth y Orders) que son código de **P5**, no de P8 — decisión explícita del usuario, dado que son vulnerabilidades reales y esta entrega es la que tiene sentido para endurecerlas.

### 1. `promote-to-gitops` no esperaba las 3 validaciones, y corría desde cualquier rama

Verificado leyendo `ci-cd.yml`: `needs: build-and-push` solamente (no `deploy-kind`/`kyverno-policy-check`/`load-test`, que corren en paralelo), y el `if` no chequeaba `github.ref`. Fix:

```yaml
needs: [build-and-push, deploy-kind, kyverno-policy-check, load-test]
if: >-
  github.event_name == 'workflow_dispatch' &&
  github.event.inputs.deploy == 'true' &&
  github.ref == 'refs/heads/main'
```

No hace falta `always()`: si cualquiera de los 4 falla, GitHub Actions salta `promote-to-gitops` por default. Además, el enunciado exige `helm lint` en el pipeline (sección 3.3 y rúbrica 2.2, 8 puntos) y no corría en ningún lado — se agregó como gate antes de proponer el PR, con `--strict` contra `values-azure.yaml` (el que de verdad llega a producción). Probado: `helm lint --strict` pasa limpio (`0 chart(s) failed`).

### 2. El README tenía frases desactualizadas y evidencia con formato incompleto

- 3 frases "ArgoCD... pendiente de instalar" que ya no eran ciertas (quedaron así desde antes de la Fase 8) — corregidas.
- "Imagen firmada" solo mostraba el digest; el enunciado pide `registro/imagen:tag`. Se agregó también la referencia por tag.
- "Reporte de prueba de carga" enlazaba el script y un artifact, pero el JSON estaba en `.gitignore` — no había ninguna "ruta del archivo" real que resolviera. Se descargó el reporte real de una corrida en verde y se versionó como `P8/loadtest/reporte-referencia.json`, con una excepción en `.gitignore` (`!loadtest/reporte-referencia.json`) para que las corridas ad-hoc locales sigan sin versionarse pero esta referencia sí.
- Se confirmó que el repo de código es **privado** (`gh repo view --json visibility`) — los links a runs de Actions requieren estar autenticado. Se le preguntó al usuario cómo resolverlo (agregar colaborador / hacerlo público / dejar como está); respondió que el profesor ya tiene acceso, así que se agregó una nota aclaratoria en el README en vez de cambiar la visibilidad del repo por cuenta propia.

### 3. `sa-platform-nats-auth`: choque real entre Helm y el SealedSecret

Se probó en vivo antes de asumir nada: se forzó un sync real de ArgoCD y se compararon los 4 secrets que Codex señaló (`auth-secrets`, `mongodb`, `mysql`, `nats-auth`) antes y después — **no cambiaron**, así que el `lookup` de Helm sí funciona correctamente contra nuestro ArgoCD real (la non-determinismo que describe Codex es real solo para `helm template`/`lint` sin contexto de clúster vivo, como corre él mismo localmente, no para un sync real). Lo que sí era un problema real: `natsAuthSecretCreate: true` seguía activo en `values-azure.yaml` (heredado de `values.yaml`), o sea que el chart *también* intentaba gestionar el mismo secret que ya gestiona el `SealedSecret` de la Fase 10. Fix: `natsAuthSecretCreate: false` en `values-azure.yaml` únicamente (en `kind`, sin Sealed Secrets, se mantiene en `true`). Verificado con `helm template`: ya no se renderiza ningún `Secret` con ese nombre en azure, y sí se sigue renderizando en kind.

### 4. Evidencia del canary con afirmaciones incorrectas

Verificado en `rollout.yaml`: los pasos reales son `20/50/80`, no `10%` como decía el diagrama. Y el `Service` principal (`sa-platform-api-gateway`, el de la IP pública) usa el mismo selector genérico que ambas versiones de pods comparten — sin un traffic router dedicado, Argo Rollouts aproxima el peso por cantidad de pods, así que **durante la ventana de análisis (antes del abort) sí puede haber tráfico real de usuarios hacia el canario**. El "0% de tráfico" del informe de incidente y del diagrama era una sobre-simplificación: lo único confirmado con la evidencia real es que, *tras* el aborto, quedó en `ActualWeight: 0`. Se corrigieron `diagrama-flujo.md` (pasos reales, orden correcto de firma-después-de-publicar, y una nota explícita sobre el mecanismo de tráfico) e `informe-incidente.md` (sección "Cómo se contuvo" reescrita con la precisión técnica correcta, sin retirar el resto de la evidencia real que sí es exacta: los timestamps, el mensaje de error, los 17.7s).

### 5. Las 3 políticas de Kyverno aplicaban a todo el clúster

Verificado en los 3 YAML: ningún `match.any[].resources` tenía `namespaces`. Fix: se agregó `namespaces: [sa-p5]` a las 3. Probado en un `kind` real: el mismo pod no conforme (`nginx:latest`) se rechaza dentro de `sa-p5` y se **permite** fuera (`default`) — confirmando que el alcance acotado funciona como se espera, sin bloquear por accidente componentes de plataforma (`argocd`, `kyverno`, `sealed-secrets`, `kube-system`). El job `kyverno-policy-check` de CI se actualizó para probar en `sa-p5` (crea el namespace antes de aplicar las políticas) y se agregó un caso nuevo que confirma explícitamente que fuera de `sa-p5` no se bloquea. También se aprovechó para acotar la identidad de Cosign en `verify-image-signatures`: de `refs/heads/*` a `refs/heads/main` — seguro porque el fix del hallazgo 1 ya garantiza que solo se promueve algo construido desde `main`. Aplicado también contra el clúster AKS real (`kubectl apply`, quedó `configured`, no `created` — las políticas ya existían de la Fase 9).

### 6. Escalación de privilegios en Auth + sin validación de JWT en Catalog/Orders

Confirmado en el código: `let rol = requestedRol === 'Admin' ? 'Admin' : 'Cliente';` en `auth-service/src/index.ts` — cualquiera podía registrarse como Admin mandando `"rol": "Admin"` en el body, sin ninguna verificación de que quien llamaba ya fuera administrador. Fix: el registro público siempre crea `Cliente`, sin excepción (no existe, ni se agregó, un flujo de alta de administradores por API — si hiciera falta uno, tendría que exigir que quien lo invoque ya esté autenticado como Admin). Verificado: `npm run build` compila limpio y los 4 tests existentes de `auth-service` (`security.test.ts`, `jwt.test.ts`) siguen pasando.

Ni `catalog-service` ni `order-service` verificaban el JWT para nada — se agregó verificación real (no llamadas HTTP a `/validate`, sino decodificación local del mismo `JWT_SECRET` que ya usa `auth-service` para firmar, vía `PyJWT`, evitando una dependencia de red extra por cada mutación):

- `catalog-service`: `create_product` exige rol `Admin` (gestión de catálogo). `update_product_stock` exige *cualquier* usuario autenticado, no específicamente Admin — es una operación interna que dispara `order-service` en nombre de un Cliente durante el checkout, no algo que un Cliente llame directo; exigirle Admin habría roto el flujo normal de compra.
- `order-service`: `create_order` exige autenticación y toma `user_id` del JWT validado, ya no como argumento GraphQL que mandaba el cliente (antes se podía crear una orden a nombre de cualquier otro usuario con solo cambiar ese argumento). Reenvía el `Authorization` del comprador cuando llama a `updateProductStock` en catalog, porque esa mutación ahora exige un caller autenticado.
- El `JWT_SECRET` se comparte vía el mismo Secret que ya usa `auth-service` (`{{ .Release.Name }}-auth-secrets`), inyectado como env var nueva en los `Deployment` de `catalog` y `orders`. Se confirmó además que `nginx.conf` del gateway no necesitaba ningún cambio: ninguna de sus 3 rutas (`/api/auth/`, `/api/catalog/`, `/api/orders/`) pisa el header `Authorization`, así que ya viaja transparente de punta a punta (comportamiento por defecto de `proxy_pass`, no hacía falta agregar `proxy_set_header Authorization` a mano).

**Verificado con tests reales, no solo escrito:** se agregaron casos nuevos a las dos suites de Python (rechazo sin token, rechazo con rol incorrecto, y — de paso, junto con el hallazgo 7 — rechazo por stock insuficiente y por cantidad negativa) y se corrieron contra MongoDB/MySQL reales en Docker: **7/7 passed** en catalog, **5/5 passed** en orders. Se reconstruyeron las dos imágenes con `PyJWT` agregado y se re-escanearon con Trivy real: **0 CRITICAL** en ambas.

### 7. Stock no atómico en Orders (race condition + cantidad negativa)

Confirmado: `create_order` consultaba el stock en una llamada GraphQL separada de la que lo descontaba — dos compras concurrentes podían pasar ambas la validación leyendo el mismo stock. Y `update_product_stock` hacía `$inc: {stock: -quantity_to_discount}` sin validar signo, así que una cantidad negativa aumentaba el stock en vez de descontarlo. Fix, en `catalog-service` (que es quien tiene la base de datos, el lugar correcto para que la atomicidad sea real):

```python
result = products_collection.find_one_and_update(
    {"_id": ObjectId(id), "stock": {"$gte": quantity_to_discount}},
    {"$inc": {"stock": -quantity_to_discount}},
    return_document=ReturnDocument.AFTER
)
```

El stock mínimo pasa a ser parte del filtro del propio `find_one_and_update` (atómico a nivel de MongoDB), no un chequeo previo separado — de dos compras concurrentes, como mucho una gana la condición atómica; la otra recibe `None`. Se rechaza explícitamente `quantity_to_discount < 0` antes de llegar a Mongo. Del lado de `order-service`, se eliminó el chequeo de stock ahora redundante (`if product_data["stock"] < quantity`) y se reemplazó por depender del resultado real de `updateProductStock`: si devuelve `null`, la orden no se crea (antes, un fallo en ese paso podía dejar el stock ya descontado sin una orden que lo respalde — ahora es imposible, porque la orden se inserta *después* de confirmar que el descuento atómico tuvo éxito).

**Por qué importa, en conjunto:** ninguno de estos 7 hallazgos había sido detectado por Trivy, por los tests que ya existían, ni por ninguna de las fases anteriores — hacía falta leer el código con otro criterio (seguridad, concurrencia, exactitud de la documentación) para encontrarlos. Confirma algo que ya se sabía en abstracto pero vale la pena decir en concreto: escanear vulnerabilidades conocidas (Trivy) y tener tests que pasan no es lo mismo que estar libre de bugs de lógica o de diseño de permisos — son capas complementarias, no sustitutas.

## Fase 13 — Recuperación del sync real: Kyverno, versión canary y rotación accidental de Secrets

### 1. El `1 Error` inicial de ArgoCD sí era Kyverno, pero no una firma inválida

El sync del commit GitOps `d281539` intentó desplegar las imágenes `705a98e` y quedó `OutOfSync`/`Degraded`. Los seis recursos nuevos mostraron el mismo rechazo:

```text
verify-image-signatures: failed to verify image ghcr.io/elfbibv/...:705a98e:
GET https://ghcr.io/token?... UNAUTHORIZED: authentication required
```

Se comprobó que `ghcr-secret` existía tanto en `sa-p5` como en `kyverno`, que ambos tenían el mismo contenido, que el token podía leer el manifiesto privado con Docker y que el admission controller tenía permisos para leer el Secret. Reiniciar Kyverno tampoco eliminó el error. La diferencia estaba en el autogen de la política: la validación anticipada de `Deployment`/`CronJob` no reutilizaba de forma fiable las credenciales de la plantilla, mientras la admisión del Pod real sí funcionaba.

La primera mitigación fue cambiar temporalmente `validationFailureAction` a `Audit`; eso dejó completar el sync, pero también dejó de bloquear imágenes sin firma, así que **no** se aceptó como solución final. El arreglo definitivo en `03-verify-image-signatures.yaml` fue:

- volver a `Enforce`;
- declarar `imageRegistryCredentials.secrets: [ghcr-secret]` explícitamente;
- desactivar el autogen solo para esa regla con `pod-policies.kyverno.io/autogen-controllers: none`.

La garantía no se pierde: todo `Deployment`, `Job` o `CronJob` necesita crear un Pod antes de ejecutar código, y ese Pod sigue pasando por la regla `Enforce`. Pruebas de admisión con `--dry-run=server` en AKS:

```text
ghcr.io/elfbibv/sa-api-gateway:705a98e       -> permitido
ghcr.io/elfbibv/sa-notification-service:6d8d12d -> rechazado: no signatures found
```

El segundo resultado es importante: el error dejó de ser `UNAUTHORIZED`, por lo que Kyverno sí autenticó contra GHCR y llegó a la verificación Cosign. La CI también se endureció para crear un `ghcr-secret` efímero en su kind, probar el rechazo de una referencia no verificable y, en `main`, el allow path de una imagen realmente firmada.

### 2. El `Degraded` posterior ya no era Kyverno: el gateway reportaba otra versión

Con la política temporalmente en `Audit`, ArgoCD completó el sync y pasó a `Synced`, pero el Rollout abortó en el primer análisis. El `AnalysisRun` devolvió:

```json
{"status":"ok","version":"0.0.0-dev"}
```

El valor esperado era `705a98e`. La imagen era funcional, pero el job matricial nunca enviaba `APP_VERSION` al Dockerfile del gateway, así que conservaba su default. El workflow ahora calcula el mismo short SHA de siete caracteres que usa como tag y lo pasa como build arg:

```yaml
build-args: |
  APP_VERSION=${{ steps.sha.outputs.short }}
```

Este cambio necesita una imagen nueva: no puede reparar retroactivamente `705a98e`. Hasta publicar una corrida nueva desde `main`, el Rollout conserva estable `6d8d12d`, rechaza el candidato incorrectamente versionado y la Application permanece `Synced`/`Degraded` por ese aborto anterior.

### 3. El sync reveló que `lookup + randAlphaNum` no era estable bajo ArgoCD

Después del sync, `cron1` y `cron2` comenzaron a fallar aunque sus imágenes arrancaban. `cron1` mostró `Access denied for user 'user'`. Se compararon **hashes**, sin imprimir valores: las contraseñas del Secret `sa-platform-mysql` y del proceso MySQL no coincidían; ocurrió lo mismo con MongoDB. Los `managedFields` mostraron que `argocd-controller` había actualizado los Secrets a las `07:33Z`, mientras las bases seguían usando las credenciales con las que inicializaron sus volúmenes horas antes.

Esto corrige una conclusión de la Fase 12: una prueba anterior no observó rotación, pero una reconciliación fresca sí demostró que el `lookup` de los templates no constituye persistencia confiable durante el render aislado de ArgoCD. Los valores aleatorios cambiaron sin cambiar la base ya inicializada.

La corrección fue:

- configurar `mysql.auth.existingSecret`, `mongodb.auth.existingSecret` y `auth.secrets.existingSecret` en `values-azure.yaml`;
- configurar también `global.mysqlSecretName` y `global.mongodbSecretName` para que consumidores y subcharts apunten al mismo objeto;
- versionar tres `SealedSecret` cifrados en el chart, activados solo en Azure;
- mantener `sealedSecrets.enabled: false` en los perfiles local/kind, donde Helm continúa creando Secrets efímeros;
- adoptar en AKS los Secrets existentes y restaurar MySQL/MongoDB con las credenciales activas de sus procesos, no con los valores ya rotados por Argo.

Se reiniciaron Auth, Catalog y Orders de forma secuencial para que leyeran los valores restaurados. Los tres terminaron con `2/2` réplicas. Luego se ejecutaron Jobs manuales y temporales a partir de ambos CronJobs:

```text
cron1 -> Inserted record for 202203856 ...
cron2 -> Published: {"event":"HOURLY_SUMMARY", ...}
```

Los dos Jobs de prueba se eliminaron después de guardar su salida. Los `SealedSecret` quedaron `Synced=True`, los hashes de Secret/proceso coinciden y Argo ya no incluye esos tres Secrets generados en su estado deseado.

### 4. Otros dos efectos encontrados durante la recuperación

- Las políticas de registry y non-root bloqueaban la recreación de NATS, MySQL y MongoDB porque son imágenes de terceros dentro de `sa-p5`. Se desactivó su autogen y se excluyeron únicamente los nombres exactos `sa-platform-{nats,mysql,mongodb}-0`. La primera versión usaba selectores de etiquetas, pero se endureció porque un Pod malicioso podía falsificar `app=mysql`; un dry-run confirmó que esa evasión ahora vuelve a ser rechazada, mientras los tres Pods reales siguen admitidos.
- La cuota de `limits.cpu: 3` deja poco margen para el `maxSurge` de los Deployments. Durante los reinicios aparecieron rechazos transitorios de cuota, pero Kubernetes reintentó y los tres rollouts terminaron. No fue la causa del error original de Argo, pero debe considerarse si se aumentan réplicas o límites.

### Estado al cerrar esta fase

- ArgoCD: `Synced`, operación `Succeeded`.
- Kyverno: verificación de firma otra vez en `Enforce`; allow y deny path comprobados en AKS.
- MySQL/MongoDB/Auth: Secrets estables bajo Sealed Secrets.
- Cron1/Cron2: ejecución funcional comprobada.
- Rollout: `Degraded` de forma esperada para la imagen antigua `705a98e`, porque reporta `0.0.0-dev`. La corrección de build está lista localmente y requiere publicar una nueva imagen desde `main` para completar la promoción.
