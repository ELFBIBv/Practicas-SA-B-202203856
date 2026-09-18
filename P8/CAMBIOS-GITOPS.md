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
