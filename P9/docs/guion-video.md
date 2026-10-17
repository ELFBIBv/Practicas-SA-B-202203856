# Guion del video demostrativo — Práctica 9

Duración objetivo: **7 min** (el enunciado exige entre 5 y 8). Se graba con el clúster arriba. La reconstrucción completa tarda ≈23 min, así que no se graba entera: se muestra el log cronometrado y las verificaciones en vivo. Después de grabar, copie al README los minutos **reales** de cada tramo.

## Preparación (fuera de cámara)

```bash
make -C P9 bootstrap                                  # si el clúster está apagado (≈23 min)
export KUBECONFIG=$HOME/.kube/p9-aks-sa-p9.config
kubectl config current-context                        # aks-sa-p9
```

Tenga abiertos el [informe](informe-dr.md), el [diagrama](diagrama-bootstrap.md) y la [cronología de E4](../evidencia/reconstruccion/cronologia-20261017T161840Z.md). Antes de compartir la pantalla, cierre cualquier terminal con tokens o la salida de `az account show`.

## Tramos

| Minuto | Punto demostrado (rúbrica) | Qué mostrar | Comando |
| --- | --- | --- | --- |
| 0:00–0:30 | Presentación | Nombre, carnet, objetivo: reconstruir desde cero con un comando. RTO 45 min / RPO 15 min declarados el 2026-09-24 | — |
| 0:30–1:30 | 1.3 Diagrama, 2.1 Bootstrap | Diagrama: fronteras dentro/fuera del clúster y las 2 únicas acciones humanas (`az login` y lanzar el comando). Punto de entrada único | `sed -n 1,40p P9/scripts/bootstrap.sh` |
| 1:30–2:30 | 2.1 Reconstrucción cronometrada | Log de E4: `RTO_INICIO`, etapas, olas y `RTO_FIN`; 22 min 55 s, sin intervención | `grep -E 'RTO_\|STAGE\|OLA' P9/evidencia/reconstruccion/bootstrap-20261017T161840Z.log` |
| 2:30–3:15 | 2.2 Estado remoto | Backend `azurerm` con bloqueo y ningún state en Git | `make -C P9 audit` · `cat P9/evidencia/estado/verify-lock-20261017T054744Z.log` |
| 3:15–4:00 | 2.4 Secretos | Llave restaurada antes del controlador (huella `7DD46ABC19BE6499`) y SealedSecrets `Synced` | `kubectl get sealedsecret -A` · `grep restore-sskey P9/evidencia/reconstruccion/bootstrap-20261017T161840Z.log` |
| 4:00–5:00 | 2.3 Velero, 2.6 Restauración | Schedule con cron y TTL, BSL `Available`, backups `Completed`; dato M1 recuperado y M2 perdido | `kubectl -n velero get bsl,schedule,backups` · `grep -E 'M1\|M2\|RPO' P9/evidencia/restauracion/restauracion-20261017T035428Z.log` |
| 5:00–6:00 | 2.5 Pérdida de nodo | Drenaje con el servicio respondiendo el 100 % (corrida 3) | `tail -20 P9/evidencia/nodo/drenaje-20261017T054203Z.log` |
| 6:00–6:30 | Herencia de P8 | Applications `Synced/Healthy`, Rollout `Healthy`, políticas en `Enforce` | `kubectl -n argocd get applications` · `kubectl -n sa-p5 get rollout` · `kubectl get clusterpolicy` |
| 6:30–7:00 | 1.2 Informe | RTO/RPO declarados frente a medidos, incluidos los incumplimientos de E1 y su plan | Informe, §3, §4 y §6 |

## Al terminar

1. Suba el video a un servicio que no pida iniciar sesión para verlo (por ejemplo, YouTube como **no listado**).
2. Ábralo en una ventana privada para confirmar que no pide autenticación.
3. En `P9/README.md`, sustituya la fila «Video demostrativo» de la tabla 4.1 por la URL y los minutos reales de cada tramo.
