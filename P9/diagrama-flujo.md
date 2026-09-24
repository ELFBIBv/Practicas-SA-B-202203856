# Diagrama del flujo — del commit al clúster

Arquitectura real del pipeline implementado en [`.github/workflows/ci-cd.yml`](../.github/workflows/ci-cd.yml). Dos mitades separadas a propósito: el repo de código nunca tiene credenciales de Azure ni acceso directo al clúster — todo lo que puede hacer es proponer un cambio abriendo un PR en el [repo GitOps](https://github.com/ELFBIBv/Practicas-SA-B-202203856-gitops). El único componente con permiso de escritura sobre el clúster es ArgoCD, corriendo adentro del propio AKS.

```mermaid
flowchart TD
    A["git push / Pull Request"] --> B["Test: 6 servicios<br/>(DB real: MySQL/MongoDB como servicio)"]
    B --> C["Build & Push: 7 imágenes"]
    C --> V1{{"✅ Trivy: ¿CRITICAL?"}}
    V1 -- "sí → bloquea" --> X1["❌ No se publica en GHCR<br/>(evidencia: PR #1)"]
    V1 -- "no" --> C2["SBOM (CycloneDX)"]
    C2 --> D["Publicar en GHCR<br/>ghcr.io/elfbibv/*"]
    D --> D2["Firma keyless (Cosign)<br/>sobre el digest ya publicado"]

    D2 --> E1["Despliegue efímero en kind<br/>canary sano + fallo inducido"]
    D2 --> E2["Kyverno: 3 políticas de admisión<br/>(kind propio)"]
    D2 --> E3["Prueba de carga k6<br/>(kind propio)"]

    E1 --> V2{{"✅ ¿Las 3 validaciones en verde?"}}
    E2 --> V2
    E3 --> V2
    V2 -- "no" --> X2["❌ Pipeline falla,<br/>no se propone despliegue"]
    V2 -- "sí" --> F{{"¿workflow_dispatch<br/>con deploy=true?"}}
    F -- "no" --> FX["Fin: solo quedó validado"]
    F -- "sí" --> G["promote-to-gitops:<br/>abre PR en el repo GitOps<br/>con el tag de imagen actualizado"]

    subgraph CD["Repo GitOps + AKS — el pipeline de CI nunca entra acá"]
        G --> H["Revisión humana del PR"]
        H --> I["Merge a main del repo GitOps"]
        I --> J["ArgoCD detecta el cambio<br/>y sincroniza (Synced/Healthy)"]
        J --> K["Argo Rollouts: canary en AKS<br/>pasos 20% → 50% → 80%, AnalysisRun sobre /health en cada paso"]
        K --> V3{{"✅ ¿Análisis pasa?"}}
        V3 -- "sí" --> M["Promoción por pasos<br/>hasta 100% estable"]
        V3 -- "no" --> N["🔄 Rollback automático<br/>canary escalado a 0 réplicas<br/>(exposición real acotada al peso del paso<br/>y a la ventana de análisis, ~18s;<br/>ver informe-incidente.md)"]
    end

    style V1 fill:#7f1d1d,color:#fff
    style V2 fill:#7f1d1d,color:#fff
    style V3 fill:#7f1d1d,color:#fff
    style X1 fill:#450a0a,color:#fff
    style X2 fill:#450a0a,color:#fff
    style N fill:#1e3a5f,color:#fff
```

## Puntos de validación (gates que pueden detener el flujo)

| Punto | Qué valida | Evidencia |
| --- | --- | --- |
| Trivy (en `Build & Push`) | Bloquea la imagen si tiene una CVE `CRITICAL` | [PR #1 bloqueado](https://github.com/ELFBIBv/Practicas-SA-B-202203856/pull/1) |
| Kyverno (`kyverno-policy-check`) | Rechaza pods que no cumplan registry/non-root/firma | Ver `CAMBIOS-GITOPS.md`, Fase 4 |
| k6 (`load-test`) | Umbrales de error rate y p95 de latencia | Ver `CAMBIOS-GITOPS.md`, Fase 5 |
| AnalysisRun de Argo Rollouts (canary, en `kind` y en AKS) | `/health` del candidato antes de darle más tráfico | Ver `informe-incidente.md` |

## Punto de reversión

El único punto de reversión automática es el `AnalysisRun` del canary: si `/health` del candidato falla, Argo Rollouts aborta el Rollout y escala el canary a 0 réplicas sin intervención humana, dejando el 100% del tráfico (desde ese momento) en la versión estable anterior.

**Precisión importante:** el `Service` que recibe tráfico real (`sa-platform-api-gateway`, el que tiene la IP pública) no usa un traffic router dedicado — selecciona pods de ambas versiones a la vez (mismo selector genérico, sin distinguir estable de canario), y Argo Rollouts aproxima el peso configurado ajustando cuántos pods de cada ReplicaSet hay corriendo. Eso significa que **durante la ventana de análisis de cada paso (antes del abort) sí puede llegar tráfico real de usuarios al canario**, proporcional al peso de ese paso (20% en el primer paso) — el rollback deja el tráfico en 0% hacia el canario recién *después* de abortar, no durante toda la promoción. El `AnalysisRun` en sí consulta al candidato por un `Service` interno aparte (`-canary`), separado del tráfico de usuarios. Documentado con evidencia real (timestamps, mensajes de error reales) en [`informe-incidente.md`](informe-incidente.md).
