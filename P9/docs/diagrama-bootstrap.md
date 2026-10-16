# Diagrama del bootstrap de recuperación — Práctica 9

Refleja el código real: [`scripts/bootstrap.sh`](../scripts/bootstrap.sh), [`scripts/lib/p9-config.sh`](../scripts/lib/p9-config.sh) (`P9_WAVES`), [`terraform/`](../terraform/) y [`gitops/apps/`](../gitops/apps/). Los números de etapa son los que imprime el log (`[STAGE] ===== N. ... =====`).

**Leyenda.** 🧑 acción humana permitida (solo 2: iniciar sesión y lanzar el comando) · ⚙️ automático (script/Terraform) · 🔄 automático (ArgoCD, sync waves) · 🗄️ sobrevive al desastre (fuera del clúster). No hay pasos manuales entre 🧑 y el fin del RTO.

```mermaid
flowchart TD
    classDef human fill:#fde68a,stroke:#b45309,color:#111
    classDef auto fill:#dbeafe,stroke:#1d4ed8,color:#111
    classDef argo fill:#dcfce7,stroke:#15803d,color:#111
    classDef persist fill:#f3e8ff,stroke:#7e22ce,color:#111
    classDef check fill:#fff,stroke:#6b7280,stroke-dasharray:4 3,color:#111

    H1["🧑 az login<br/>(Owner o Contributor + UAA)"]:::human
    H2["🧑 ./P9/scripts/bootstrap.sh<br/>RTO_INICIO"]:::human
    H1 --> H2

    subgraph EXT["🗄️ Fuera del clúster — sobrevive al desastre"]
        direction LR
        GH["Repo GitOps público<br/>ELFBIBv/...-gitops (main)"]:::persist
        GHCR["GHCR<br/>ghcr.io/elfbibv/* (firmadas)"]:::persist
        TFB["Backend Terraform<br/>rg-p9-tfstate / stp9tf… / tfstate<br/>blob lease = lock"]:::persist
        KV["Key Vault kv-sa-p9-202203856<br/>secret sealed-secrets-keyring"]:::persist
        VST["Storage Velero stp9velo… / velero-backups<br/>+ UAMI id-sa-p9-velero"]:::persist
    end

    H2 --> S1["⚙️ 1. Backend: az CLI crea/verifica<br/>RG + cuenta + contenedor (idempotente)<br/>+ object IDs del operador/custodio"]:::auto
    S1 -. crea/verifica .-> TFB
    S1 --> S2["⚙️ 2. terraform 00-persistent<br/>storage Velero, UAMI, Key Vault, roles"]:::auto
    S2 -. converge .-> VST
    S2 -. converge .-> KV
    S2 --> S3["⚙️ 3. terraform 01-cluster<br/>rg-p9-aks, IP pip-sa-p9-gateway,<br/>identidad del plano de control, AKS (≥2 nodos)"]:::auto
    S3 --> S4["⚙️ 4. kubeconfig propio + nodos Ready (≥2)"]:::check
    S4 --> S5["⚙️ 5. restore-sealed-secrets-key.sh<br/>lee keyring de Key Vault → Secret en kube-system<br/>ANTES de que exista el controlador"]:::auto
    KV -. keyring (en RAM, /dev/shm) .-> S5
    S5 --> S6["⚙️ 6. terraform 02-platform<br/>tenant sa-p5 · ArgoCD + Lua de health ·<br/>Velero (Workload Identity, BSL, VolumeSnapshotClass) ·<br/>AppProjects + Application raíz p9-root"]:::auto
    VST -. BSL default .-> S6

    S6 --> ROOT["🔄 p9-root (ns argocd)<br/>lee apps/ del repo GitOps"]:::argo
    GH -. apps/ .-> ROOT

    ROOT --> W30["🔄 ola -30: sealed-secrets<br/>(usa la llave restaurada)"]:::argo
    W30 --> W20["🔄 ola -20: kyverno · argo-rollouts<br/>(CRD + controladores)"]:::argo
    W20 --> W10["🔄 ola -10: platform-secrets (3 SealedSecret)<br/>· data-restore (Job: Restore de PVC<br/>desde el último Backup previo al clúster)"]:::argo
    VST -. Backup Completed .-> W10
    W10 --> W5["🔄 ola -5: kyverno-policies (3 en Enforce)"]:::argo
    W5 --> W0["🔄 ola 0: sa-platform<br/>(MySQL/Mongo sobre PVC restaurados,<br/>microservicios, Rollout del gateway)"]:::argo
    GHCR -. imágenes firmadas .-> W0
    W0 --> W5b["🔄 ola 5: velero-schedules<br/>(Schedule sa-p9-schedule, */15, ttl 1440h)"]:::argo
    W5b --> W10b["🔄 ola 10: platform-verify (Job de humo)"]:::argo

    W10b --> V["⚙️ 7-12. Verificación de bootstrap.sh:<br/>ArgoCD · olas Synced/Healthy · RESTORE_OK ·<br/>controladores + políticas Enforce · workloads · endpoint 2xx"]:::check
    V --> FIN(["RTO_FIN: /ready, /api/auth, /api/catalog,<br/>/api/orders responden 2xx"]):::check
```

## Quién crea y administra cada componente

| Componente | Lo crea | Lo administra después | Sobrevive al desastre |
| --- | --- | --- | --- |
| Backend de Terraform (`rg-p9-tfstate`, cuenta `stp9tf…`, contenedor `tfstate`) | `bootstrap.sh` etapa 1 con Azure CLI (huevo-gallina: no puede ser Terraform) | `lib/tfstate-backend.sh` (idempotente) | Sí |
| Storage de Velero, UAMI, Key Vault | Terraform `00-persistent` (`prevent_destroy`) | Terraform | Sí |
| Keyring de Sealed Secrets en Key Vault | Custodio, **antes** del desastre (`backup-sealed-secrets-key.sh`) | Custodio | Sí |
| RG `rg-p9-aks`, IP `pip-sa-p9-gateway`, identidad, AKS | Terraform `01-cluster` | Terraform | No (se destruye en la prueba) |
| Secret de la llave en `kube-system` | `restore-sealed-secrets-key.sh` (etapa 5) | Controlador (sin rotación) | No — se reinyecta |
| ArgoCD, Velero (servidor, node-agent, BSL, VSC), AppProjects, `p9-root` | Terraform `02-platform` | Terraform | No |
| Applications hijas | `p9-root` (desde `apps/` del repo GitOps) | `p9-root` | No |
| Controladores, políticas, secretos sellados, `sa-platform`, Schedule | Cada Application hija | ArgoCD (`selfHeal`) | No |
| PVC de MySQL/MongoDB | Job `p9-data-restore` (Velero `Restore`) | Chart `sa-platform` (los adopta) | Su **contenido** sí, vía Velero |

**Sin ciclos:** `p9-root` vive en el AppProject `p9-bootstrap`, que solo admite objetos `Application` en `argocd`; nunca puede administrar ArgoCD, sus AppProjects ni a sí misma (ver [`terraform/modules/app-of-apps-seed/main.tf`](../terraform/modules/app-of-apps-seed/main.tf)).

## Excepciones que el diagrama hace explícitas

- **Velero lo instala Terraform, no ArgoCD:** su credencial federada necesita el `oidc_issuer_url` del clúster y debe existir antes de que el Pod arranque ([`docs/diseno-velero.md`](diseno-velero.md) §1). Es automático dentro del mismo comando.
- **La llave de Sealed Secrets se reinyecta con `kubectl` desde el script:** es automático (etapa 5) y ocurre antes de ArgoCD, no es un paso del operador.
- **La custodia inicial de la llave** es una acción humana **previa** al desastre, no parte de la reconstrucción.
