# Traspaso de sesión — Práctica 9 (2026-10-17)

Para continuar en otro equipo o en otro chat sin contexto previo. Las reglas de trabajo están en [`CLAUDE.md`](../../CLAUDE.md), en la raíz del repo; la fuente de verdad es [`Practica_9_2S2026.md`](../Practica_9_2S2026.md).

## Estado al cerrar

| Qué | Estado |
| --- | --- |
| Repo de código (público) | `ELFBIBv/Practicas-SA-B-202203856`, rama `main` (`verificar_p9.sh` la clona) |
| Repo GitOps (público) | `ELFBIBv/Practicas-SA-B-202203856-gitops`, `main` en `3fe7952`; idéntico a lo que publica `P9/` |
| Clúster AKS | Destruido el 2026-10-17 a las 05:58 UTC y **reconstruido** el mismo día a las 16:18-16:41 UTC desde el equipo nuevo (E4 del informe, 22 min 55 s, sin intervención). Si sigue encendido, apáguelo al terminar (ver abajo) |
| Capa persistente (no se destruye) | RG `rg-p9-tfstate`: backend `stp9tfc01f715c2e19` (contenedor `tfstate`), respaldos `stp9veloc01f715c2e19` (contenedor `velero-backups`), Key Vault `kv-sa-p9-202203856` (secreto `sealed-secrets-keyring`) |
| Respaldo que restaurará el próximo bootstrap | El último `Completed` del Schedule al momento de destruir: `kubectl -n velero get backups --sort-by=.status.startTimestamp` antes del `destroy-cluster` |
| `verificar_p9.sh` contra el clúster | **58/60, sin requisitos eliminatorios incumplidos** ([reporte de E4](../evidencia/verificacion/verificar_p9-20261017T164100Z.txt)). Los −2 son de 2.5: MySQL, MongoDB y NATS tienen 1 réplica (punto único de fallo documentado; no se corrige) |
| Pruebas en AKS | Hechas y documentadas: [informe](informe-dr.md), [tabla 4.1 del README](../README.md), [`evidencia/`](../evidencia/) |
| Pendientes de entrega | Video (guion en [`guion-video.md`](guion-video.md)). El repositorio de código se hizo público el 2026-10-17, tras revisar el historial: sin credenciales vivas |
| Calificación | Presencial, en la máquina del autor |

## Prerrequisitos del equipo nuevo

Versiones usadas: terraform 1.16.3, kubectl 1.36.4, helm 3.21.4, yq 4.54.1 (mikefarah), jq 1.8.2, velero 1.18.2, kubeseal 0.40.0, az 2.90.0, gh ≥ 2.45, rsync ≥ 3.2.3, git, curl, openssl, gunzip; shellcheck 0.11 es opcional. En el equipo nuevo se instalaron sin `sudo` en `~/.local/bin`, verificando el checksum oficial de cada binario (procedimiento en el runbook, R-0.1). Registre también el repo de Helm de NATS, que necesita `verify-sealed-secrets-offline.sh`: `helm repo add nats https://nats-io.github.io/k8s/helm/charts/`.

```bash
az login                      # cuenta con la suscripción "Azure for Students"
az account show --query name -o tsv
gh auth login                 # para abrir PR; el repo de código es público
git clone https://github.com/ELFBIBv/Practicas-SA-B-202203856.git
cd Practicas-SA-B-202203856
```

La cuenta de `az` necesita Owner, o Contributor + User Access Administrator, sobre la suscripción, y el rol `Key Vault Secrets Officer` en `kv-sa-p9-202203856`; el custodio actual lo tiene. `bootstrap.sh` deriva los object IDs de la sesión de `az`. No hace falta `.tfvars`.

## Día de la calificación

```bash
# 1. ~1 h antes: levantar todo (≈23 min medidos en E4). Restaura los datos del último respaldo.
make -C P9 bootstrap

# 2. Si el bootstrap termina en error, revisar el log y repetir solo la verificación:
./P9/scripts/bootstrap.sh verify          # 12 etapas, termina con los 4 endpoints OK

# 3. Script de calificación. Usa el contexto de kubectl ACTIVO: el bootstrap
#    escribe un kubeconfig propio y no toca ~/.kube/config.
export KUBECONFIG=$HOME/.kube/p9-aks-sa-p9.config
cd P9/scripts && ./verificar_p9.sh        # esperado: 58/60; lee p9.conf (versionado)

# 4. Al terminar la calificación, apagar (irreversible; los respaldos sobreviven):
make -C P9 destroy-cluster CONFIRM=aks-sa-p9
```

- `verificar_p9.sh` es el script del curso: sha256 `b51fa0fb9c3eaef6…`. **No modificarlo**: el auxiliar compara el hash.
- Costo con el clúster arriba: ≈USD 0.55/h (2 × `Standard_DS2_v2` + 1 × `Standard_D2s_v4`). Nunca dejarlo encendido sin necesidad. Para ahorrar sin la prueba de nodo: `export TF_VAR_spare_node_count=0` antes del bootstrap.

## Problemas conocidos y qué hacer

| Síntoma | Causa | Acción |
| --- | --- | --- |
| La ola 0 no cierra; los ReplicaSet de `sa-p5` dan `FailedCreate` con `verify-signature … DENIED` | El token de GHCR sellado en `ghcr-secret` venció (el actual se creó el 2026-10-17 con `read:packages`) | Runbook R-7: token *classic* nuevo de `ELFBIBv` → `./P9/scripts/rotate-ghcr-secret.sh` en una terminal propia, para que el token no pase por el chat → `publish-gitops.sh` + PR y merge en GitOps → anotar los ReplicaSet |
| `400 BadRequest … VM size … not allowed` | Azure for Students restringe tamaños en `chilecentral` | Usar uno permitido; el mensaje de error trae la lista. La cuota de DSv2 (4 vCPU) la usan los 2 nodos del sistema |
| `p9-root` `OutOfSync` permanente | Un campo con valor por defecto en una Application (ya corregido con `directory.recurse`) | Comparar `spec` de Git y del clúster de la hija marcada |
| Drenaje: 2 de 5 réplicas del gateway `Pending` | `DoNotSchedule` del gateway + CPU justa | Documentado (informe, PUF 3); se resuelven con el `uncordon` |
| `ci-cd.yml` en rojo | CVE-2026-90711 en `proxy-addr` de `P8/auth/auth-service` | Fuera de alcance: está en `P8/` |

## Cómo se publica un cambio

- Todo cambio va en `P9/` (o `.github/`, con filtro `paths: P9/**`); nunca en `P1/`–`P8/`.
- Lo que lee ArgoCD (`gitops/`, `charts/sa-platform/`, `kyverno/policies/`) se copia al repo GitOps con `./P9/scripts/publish-gitops.sh <clon-del-repo-gitops>`, en una rama, con PR y merge. `P9/` y el repo GitOps deben quedar idénticos.
- En el repo de código: commit en `feature/Practica9`, PR a `main`, esperar `p9-validate` (4 jobs) y merge, porque `verificar_p9.sh` clona `main`.
- Preferencias del autor: **no hacer commit, push ni merge sin que lo pida explícitamente**; sin líneas de atribución en commits ni PR; cambios mínimos a `verificar_p9.sh`; prioridad en que `verificar_p9.sh` funcione, no en seguir el enunciado al pie de la letra.

## Dónde está cada cosa

| Tema | Ruta |
| --- | --- |
| Entrega y tabla 4.1 | [`P9/README.md`](../README.md) |
| Runbook, informe, diagrama, preguntas | [`runbook-recuperacion.md`](runbook-recuperacion.md), [`informe-dr.md`](informe-dr.md), [`diagrama-bootstrap.md`](diagrama-bootstrap.md), [`preguntas-teoricas.md`](preguntas-teoricas.md) |
| Evidencia de la sesión en AKS | [`evidencia/reconstruccion/cronologia-20261017.md`](../evidencia/reconstruccion/cronologia-20261017.md) y carpetas hermanas |
| Punto de entrada y librerías | [`scripts/bootstrap.sh`](../scripts/bootstrap.sh), [`scripts/lib/`](../scripts/lib/) |
| Pruebas de DR | `make -C P9 dr-restore-test`, `make -C P9 dr-node-test`, `make -C P9 dr-rebuild-test CONFIRM=aks-sa-p9` (esta destruye y reconstruye) |
| Terraform | [`terraform/`](../terraform/): `00-persistent`, `01-cluster` (incluye el node pool `spare`), `02-platform` |
