# P9/gitops — contenido que se publica en el repositorio GitOps

Esta carpeta es la **fuente** en el repo de código. ArgoCD **no** la lee desde aquí: lee el repositorio GitOps [`ELFBIBv/Practicas-SA-B-202203856-gitops`](https://github.com/ELFBIBv/Practicas-SA-B-202203856-gitops), rama `main`. `P9/scripts/publish-gitops.sh` copia este contenido a un clon local de ese repo para abrir un PR.

| Ruta en el repo GitOps | Origen en este repo | Quién la sincroniza |
| --- | --- | --- |
| `apps/` | `P9/gitops/apps/` | Application raíz `p9-root` (creada por Terraform, `P9/terraform/modules/app-of-apps-seed`) |
| `policies/kyverno/` | `P9/kyverno/policies/` | Application hija `kyverno-policies` |
| `charts/sa-platform/` | `P9/charts/sa-platform/` | Application hija `sa-platform` |

**Regla anticiclo:** `apps/` solo contiene objetos `Application` hijos. Nunca debe contener la raíz, un `AppProject` ni la instalación de ArgoCD. Esos objetos son de Terraform. Si alguien los agrega, el AppProject `p9-bootstrap` rechaza el sync.

**Sin finalizer en las hijas:** si una hija se quita de `apps/`, la raíz la poda, pero sus recursos quedan huérfanos en vez de borrarse en cascada. Así un error en Git no puede borrar los volúmenes de MySQL/MongoDB.
