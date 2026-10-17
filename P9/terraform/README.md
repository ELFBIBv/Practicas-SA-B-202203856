# Terraform de P9: reconstrucción de día cero

Hay dos etapas, cada una con su propio estado remoto en Azure Storage con bloqueo:

| Etapa | Estado | Crea |
| --- | --- | --- |
| [`01-cluster/`](01-cluster/) | `p9/01-cluster.tfstate` | Resource group `rg-p9-aks` y AKS `aks-sa-p9` (2 × `Standard_DS2_v2`, tier Free, OIDC + Workload Identity) |
| [`02-platform/`](02-platform/) | `p9/02-platform.tfstate` | Namespace `sa-p5` con cuotas y RBAC (módulo `tenant`, heredado de P8), ArgoCD (`argo-cd` 10.9.2) y la siembra del app-of-apps (AppProjects `p9-bootstrap`/`p9-platform` y Application raíz `argocd/p9-root`) |

Módulos en [`modules/`](modules/): `cluster`, `tenant`, `argocd` y `app-of-apps-seed`.

**No ejecute `terraform init/plan/apply` a mano.** El backend es parcial: `P9/scripts/bootstrap.sh` lo crea o lo reutiliza, pasa los `-backend-config` de cada etapa y exporta los `TF_VAR_*` compartidos para que las dos etapas hablen del mismo clúster. Comandos:

```bash
./P9/scripts/bootstrap.sh            # reconstrucción completa (make -C P9 bootstrap)
./P9/scripts/bootstrap.sh plan       # solo planes
./P9/scripts/destroy-cluster.sh --confirm aks-sa-p9   # IRREVERSIBLE: solo 01-cluster
make -C P9 fmt-check validate        # validación estática sin tocar Azure
```

Diseño completo en [`../docs/terraform-dia-cero.md`](../docs/terraform-dia-cero.md). El backend y el locking están en [`../docs/terraform-backend.md`](../docs/terraform-backend.md).

## Cuotas en dos niveles (heredado de P8)

`modules/tenant` crea `sa-p5-platform-quota` y `sa-p5-platform-limits`, el techo de **plataforma**. El chart `sa-platform` declara su propia `ResourceQuota`, más ajustada (`values-azure.yaml`, bloque `quota:`). Kubernetes exige que cada Pod cumpla **todas** las cuotas del namespace, así que no hay conflicto. Además, Terraform y ArgoCD no se disputan el mismo objeto.

Los valores (`requests 2.5 / limits 3.2 vCPU`, `requests 6Gi / limits 8Gi`) quedan por debajo de la capacidad asignable de 2 × `Standard_DS2_v2`: unos 3.9 vCPU y 10 Gi después de las reservas de AKS.

## Evidencia

Los `plan.log`, `apply.log` y `kubectl-get-evidencia.log` que había aquí eran copias idénticas de los de `P8/terraform/`, y se eliminaron de P9. El original sigue en P8. La evidencia de P9 se generará con `make -C P9 bootstrap`.
