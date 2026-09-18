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
