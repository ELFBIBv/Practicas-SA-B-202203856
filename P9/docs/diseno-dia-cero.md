Implementé el día cero de Terraform en `P9/`. Pasa `fmt`, `validate`, `shellcheck` y un render de los dos charts de Argo, pero **no lo he ejecutado contra Azure**. Además, el bootstrap todavía no puede llegar a verde sin dos cosas ajenas a este diseño (ver "Qué falta").

## Recomendación

**Terraform en dos etapas, cada una con su estado:**
- `01-cluster` crea el resource group y el AKS.
- `02-platform` instala, dentro del clúster, el namespace con cuotas y RBAC, ArgoCD y la siembra del app-of-apps.

**Por qué dos etapas:** `02-platform` obtiene las credenciales de un clúster que ya existe. Con una sola raíz, los providers `kubernetes`/`helm` se configurarían con valores que aún no se conocen. Eso funciona el día cero, pero cuando el clúster desaparece y el estado sigue ahí, Terraform intenta conectarse con credenciales viejas y la reconstrucción falla.

**ArgoCD lo instala Terraform con Helm** (chart `argo-cd` 10.9.2, ArgoCD v3.5.3), como pide el enunciado. Terraform espera a que esté listo y, si la release ya existe en el clúster, la adopta en vez de fallar.

**La raíz del app-of-apps también la crea Terraform**, con el chart `argocd-apps`. No uso `kubernetes_manifest` porque necesita el CRD `Application` durante el `plan`, y en día cero ese CRD todavía no existe.

**El módulo de P8 se conserva** como `modules/tenant`. Crea `sa-p5` antes de la siembra, así Terraform y ArgoCD no compiten por crear el namespace.

## Diseño

**Recursos de Azure:**
- AKS en tier Free, con la versión por defecto de la región para no quedar bloqueado por una versión retirada tras un desastre.
- 2 × `Standard_DS2_v2` con disco de 64 GB: es lo que P8 ya corrió, cabe en la cuota de estudiante y es el mínimo para la prueba de drenaje.
- Identidad administrada, OIDC y Workload Identity, que Velero puede usar sin llaves.
- La misma red que P8 (Azure CNI overlay + Cilium).
- **No** creo ACR, Log Analytics ni VNet propia: el enunciado no los exige y cuestan.

**Ciclo de administración:** Terraform es el único dueño de ArgoCD, de los dos AppProject y de la raíz `argocd/p9-root`. La raíz vive en el proyecto `p9-bootstrap`, que solo admite objetos `Application` en `argocd`, así que no puede administrarse a sí misma ni a ArgoCD. Las hijas están en `P9/gitops/apps/`: sealed-secrets (−30), argo-rollouts y kyverno (−20), kyverno-policies (−5) y sa-platform (0).

**[PUNTO DE INTEGRACIÓN CON bootstrap.sh]** Mantuve el contrato (backend → `init` → `plan -out` → `apply` de ese plan), ahora por etapa. Orden completo:

1. Backend remoto.
2. `01-cluster`.
3. Credenciales en un kubeconfig propio y espera de nodos `Ready` (al menos 2).
4. Llave de Sealed Secrets.
5. `02-platform`.
6. ArgoCD disponible.
7. Raíz y cada hija `Synced/Healthy`.
8. Controladores y las 3 políticas en `Enforce`.
9. Workloads y Rollout del gateway `Healthy`.
10. Endpoint: 4 rutas responden 2xx.

Todas las esperas son `kubectl wait`/`rollout status` o sondeos con límite de tiempo que muestran un diagnóstico si fallan; no hay pausas a ciegas. El log marca `RTO_INICIO`, `RTO_FIN` y `RTO_SEGUNDOS`.

**[PUNTO DE INTEGRACIÓN CON SECRETOS]** El otro diseño pide reinyectar la llave "entre la etapa del clúster y la de ArgoCD". Con dos etapas eso cae en el paso 4 de `bootstrap.sh`, que llama a `restore-sealed-secrets-key.sh`, así que Terraform no necesita un `local-exec`. Alineé las waves y los valores del controlador con su tabla. Si ese script no existe, el bootstrap falla con `PENDIENTE`. Con `P9_ALLOW_NEW_SEALED_KEY=1` se puede probar solo la infraestructura, pero la corrida queda marcada como no válida como evidencia.

**Logs de P8:** los **borré** de P9. Eran copias exactas de los de `P8/terraform/`, que siguen ahí y en el historial de git. Moverlos habría dejado un duplicado sin aportar nada.

## Validaciones

| Qué | Estado |
|---|---|
| `terraform fmt` + `validate` de las dos etapas (Terraform 1.16.4, azurerm 5.6, helm 3.3, kubernetes 3.2) | ✅ |
| Render de `argo-cd` y `argocd-apps` con los valores reales | ✅ Encontró un bug: un `:` en una descripción rompía el YAML de la siembra. Corregido. |
| `shellcheck`, prueba de las esperas con un `kubectl` simulado, guardas de los scripts, `audit` | ✅ |
| Clúster existente | Diseñado para que los dos planes salgan sin cambios y las esperas pasen de inmediato. ⏳ Sin verificar |
| Destruir el clúster sin tocar el backend | `./P9/scripts/destroy-cluster.sh --confirm aks-sa-p9` destruye solo `01-cluster` y comprueba que el backend sigue disponible. ⏳ Sin ejecutar |
| `bootstrap.sh plan` / `all`, reconstrucción cronometrada | ⏳ Requiere Azure |

## Qué falta y contradicciones

1. **El repo GitOps no tiene `apps/`.** Sin publicarlo, la raíz nunca queda `Healthy`. `publish-gitops.sh <clon>` prepara el diff, pero el push y el PR son cambios remotos que necesitan tu autorización. En ese mismo PR hay que borrar `argocd/application.yaml` de P8, que usa el mismo nombre `sa-platform`.
2. **El workflow `promote-to-gitops` de P8** sincroniza `P8/charts` hacia el repo GitOps y **sobrescribiría** la copia de P9. Hace falta un workflow para P9.
3. **Key Vault del diseño de secretos:** ese diseño lo escribe como recurso de Terraform, pero la capa persistente la crea `az` en `bootstrap.sh`. Hay que decidir si va ahí o en una tercera etapa `00-persistent`. En cualquier caso, asignar sus roles requiere Owner.
4. **El certificado de administrador de AKS queda en el estado de `02-platform`.** Es el precio de no exigir `kubelogin`; el estado es privado, remoto y versionado.
5. **Los discos de los PVC mueren con el clúster.** Los respaldos de Velero tienen que ir a la capa persistente.

**Estado de git:** `git mv`/`git rm` dejaron cambios preparados en el índice; no hice commits. Aparecieron dos archivos vacíos creados por otra sesión, `docs/diseno-dia-cero.md` y `docs/decisiones-pendientes.md`, y no los toqué.

El detalle completo está en [docs/terraform-dia-cero.md](terraform-dia-cero.md). Lo siguiente, con tu autorización, es `./P9/scripts/bootstrap.sh plan` contra tu suscripción.