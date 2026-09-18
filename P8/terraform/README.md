# Terraform — namespace, cuotas, límites y RBAC

Cubre exactamente el entregable de la sección 4 del enunciado: *"Código Terraform: Namespaces, cuotas, límites y RBAC, con evidencia de plan y apply."* No crea el clúster de AKS (eso sigue siendo `az aks create`, documentado en `P8/README.md`) — administra objetos **dentro** de un clúster que ya existe.

## Qué administra

| Archivo | Recurso | Para qué |
| --- | --- | --- |
| `namespace.tf` | `kubernetes_namespace.sa_platform` | El namespace `sa-p5` que usan el chart de Helm y la Application de ArgoCD. |
| `quota.tf` | `kubernetes_resource_quota.platform` | Cuota de **plataforma** (tenant): el techo del namespace. |
| `quota.tf` | `kubernetes_limit_range.platform` | Piso de seguridad de CPU/memoria por contenedor, a nivel de plataforma. |
| `rbac.tf` | `sa-platform-viewer` (ServiceAccount + Role + RoleBinding) | Acceso de solo lectura (`get/list/watch`) sobre pods, deployments, Rollouts, CronJobs. |
| `rbac.tf` | `sa-platform-operator` (ServiceAccount + Role + RoleBinding) | Lo mismo que `viewer`, más `patch` sobre `rollouts`/`rollouts/status` para poder hacer `kubectl argo rollouts promote/abort/retry` a mano. Sin acceso a Secrets, sin permiso de borrado. |

## Por qué hay dos ResourceQuota / LimitRange en el mismo namespace

El chart de Helm (`P8/charts/sa-platform/templates/namespace-quotas.yaml`) ya declara su propia `ResourceQuota`/`LimitRange`, con los valores de `values-azure.yaml` (bloque `quota:`). Ese es el presupuesto que la propia aplicación se autoimpone. Este Terraform agrega una **segunda** cuota, de nivel de plataforma, con nombres distintos (`sa-p5-platform-quota`, `sa-p5-platform-limits`) y valores iguales o más generosos.

No es redundante ni conflictivo: en Kubernetes, si un namespace tiene varias `ResourceQuota`, cada pod tiene que satisfacerlas **todas** simultáneamente. El patrón es real (equipo de plataforma fija el techo del tenant vía Terraform; el equipo de aplicación declara su propio presupuesto, más ajustado, vía Helm) y evita que Terraform y ArgoCD/Helm compitan por poseer el mismo objeto.

### Los números no son arbitrarios: están acotados por la capacidad física del clúster

Con el clúster de 2 nodos `Standard_DS2_v2` que crea `az aks create` en `P8/README.md`, la capacidad real asignable (descontando las reservas de sistema de AKS, antes de sumar lo que ya consumen `coredns`/`metrics-server`/CNI) es de **~3.9 vCPU y ~10Gi de memoria en total**. Por eso:

- `platform_quota` (este módulo): `requests 2.5 / limits 3.2 vCPU`, `requests 6Gi / limits 8Gi` — deja margen real debajo de esa capacidad física.
- `quota:` del chart de Helm (`values-azure.yaml`): `requests 2 / limits 3 vCPU`, `requests 5Gi / limits 7Gi` — queda por debajo del techo de plataforma, manteniendo el orden `plataforma > app`.
- Consumo real observado (sumando todas las réplicas, con margen para el pico transitorio del canary): ~1.2–1.7 vCPU, ~1.5–2.1Gi — bien por debajo de ambos techos.

Si en algún momento se agranda el node pool, estos tres niveles se pueden recalcular con la misma lógica; no son números "redondos" elegidos al azar.

## Prerequisitos

- Terraform >= 1.5.
- `kubectl` ya apuntando al clúster real: `az aks get-credentials --resource-group rg-practica8 --name aks-sa-p8 --overwrite-existing` (ver `P8/README.md`).
- El contexto de kubectl resultante (por defecto se llama igual que el clúster, `aks-sa-p8`) coincide con `kube_context` en `terraform.tfvars`.

## Cómo correrlo (evidencia de plan y apply)

```bash
cd P8/terraform
cp terraform.tfvars.example terraform.tfvars   # ajustar si el contexto se llama distinto

terraform init
terraform plan  -out=tfplan | tee plan.log      # evidencia de "plan"
terraform apply tfplan       | tee apply.log     # evidencia de "apply"

kubectl get resourcequota,limitrange,sa,role,rolebinding -n sa-p5
```

Guardar `plan.log`, `apply.log` y la salida de ese último `kubectl get` (o una captura) es la evidencia que pide la tabla de entregables — referenciarlos desde la tabla de enlaces obligatoria del `P8/README.md`.

## Nota sobre el estado (`terraform.tfstate`)

Este módulo usa backend local (`terraform.tfstate` queda en esta carpeta, y está en `.gitignore` porque puede contener datos del clúster). Para un solo estudiante corriendo esto desde su propia laptop alcanza; si en algún momento se necesita que más de una persona lo aplique, hay que migrar a un backend remoto (Azure Storage, por ejemplo) — no es necesario para esta entrega.
