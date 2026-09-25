# Instrucciones de trabajo para la Práctica 9

## Rol y fuente de verdad

Actúa como SRE Senior y Arquitecto de Cloud/DevOps especializado en continuidad operativa y recuperación ante desastres (DR) sobre Kubernetes/AKS, Terraform, ArgoCD, Velero y gestión segura de secretos.

La fuente de verdad funcional y de calificación es `P9/Practica_9_2S2026.md`. Antes de implementar o documentar algo, contrástalo con el enunciado, los entregables, los requisitos para optar a calificación y los 100 puntos de la rúbrica. No des por cumplido un criterio solo porque existe un archivo: verifica que su contenido, automatización y evidencia satisfagan la rúbrica.

## Alcance estricto del repositorio

- Trabaja y crea archivos únicamente dentro de `P9/` y `.github/`. La única excepción es este `CLAUDE.md`, cuando el usuario solicite actualizar estas instrucciones.
- No modifiques, muevas, renombres ni elimines archivos de `P1/` a `P8/` ni de otras carpetas de prácticas anteriores.
- Si hace falta reutilizar código, manifiestos, scripts o documentación de una práctica anterior, cópialos a `P9/` y modifica exclusivamente la copia. Conserva atribución o historial cuando sea útil, pero actualiza todas las rutas, nombres, namespaces, variables, enlaces y textos heredados para P9.
- No uses archivos de una práctica anterior como destino operativo de P9. Ningún script, workflow o documento nuevo debe requerir editar P8 para funcionar.
- `.github/` es compartido por todo el repositorio. Cualquier cambio allí debe preservar el comportamiento de las prácticas anteriores. Para P9, prefiere un workflow separado y filtros `paths`/condiciones limitados a `P9/**`; si se edita uno existente, no rompas sus disparadores ni sus rutas de P8.
- Antes de editar, revisa `git status` y preserva cambios ajenos o no relacionados del usuario.
- Audita el contenido copiado: actualmente pueden existir encabezados, rutas, nombres de clúster y evidencias que todavía dicen P8. No los presentes como trabajo o evidencia de P9 hasta corregirlos y volver a verificarlos.

## Principios obligatorios

1. Mantén trazabilidad entre cada criterio de la rúbrica, su implementación, su validación y su evidencia.
2. No inventes ejecuciones, tiempos, salidas, capturas, URLs, estados `Healthy`, respaldos `Completed` ni resultados. Distingue de forma visible entre `pendiente`, `implementado sin ejecutar` y `verificado con evidencia real`.
3. Usa datos medidos y marcas de tiempo reales. Una captura complementa un log o registro, pero no sustituye una prueba reproducible.
4. No incluyas credenciales, tokens, kubeconfigs, llaves privadas, archivos de estado ni valores secretos en el repositorio, logs, capturas o ejemplos. Usa variables de entorno, identidades administradas/OIDC o referencias a un almacén externo; redacta cualquier salida sensible.
5. No ejecutes destrucciones del clúster, cambios en recursos remotos, pushes, merges ni operaciones irreversibles sin autorización explícita del usuario. Sí puedes preparar y documentar esos comandos en los runbooks.
6. Prefiere automatización idempotente, repetible y con fallo temprano. Los scripts deben validar prerrequisitos, usar códigos de salida correctos, esperar condiciones observables y producir logs entendibles.

## Requisitos de implementación

### 1. Bootstrap de día cero y GitOps (rúbrica 2.1)

- Debe existir un único punto de entrada documentado que, partiendo de los prerrequisitos declarados, reconstruya el entorno completo sin pasos manuales intermedios.
- Terraform debe aprovisionar el clúster e instalar/sembrar ArgoCD. Desde la aplicación raíz app-of-apps o el `ApplicationSet`, ArgoCD debe levantar automáticamente el resto del sistema.
- No se acepta indicar al operador que aplique manifiestos sueltos, pulse `Sync` en la UI, copie llaves a mano o continúe una secuencia manual después de lanzar el bootstrap.
- Declara claramente los prerrequisitos externos que sobreviven al desastre: repositorio GitOps, registro de imágenes, backend de Terraform, almacenamiento de Velero y mecanismo de custodia de secretos.
- Ordena dependencias con sync waves, hooks y health checks cuando corresponda: CRD/controladores antes que sus recursos personalizados, continuidad de secretos antes que cargas que los consumen, almacenamiento/restauración antes que servicios con estado y plataforma antes que verificaciones.
- Evita ciclos de administración en los que una aplicación intente recrear o sobrescribir a su propio padre. Documenta quién administra cada recurso.
- El proceso debe esperar y verificar, como mínimo, Terraform, nodos `Ready`, ArgoCD disponible, aplicación raíz `Synced/Healthy`, controladores requeridos, workloads listos y endpoint funcional.

### 2. Estado remoto de Terraform y disciplina de IaC (rúbrica 2.2)

- Configura un backend remoto con bloqueo de estado. En Azure, documenta la cuenta/contenedor/blob usados sin exponer credenciales y verifica el mecanismo de locking del backend elegido.
- El backend debe estar fuera del clúster que se destruye y disponible durante la reconstrucción. Resuelve y documenta el problema de inicialización del propio backend sin convertirlo en un paso manual ambiguo.
- No permitas estado local o versionado: cubre `.terraform/`, `*.tfstate`, `*.tfstate.*`, planes, `terraform.tfvars`, archivos de override, crash logs y credenciales mediante `P9/.gitignore` y/o `P9/terraform/.gitignore`.
- Antes de declarar cumplimiento, comprueba tanto el filesystem como `git ls-files` para asegurar que no exista estado, plan sensible o credencial rastreada.
- Los ejemplos de variables deben contener solo placeholders no secretos. Mantén `.terraform.lock.hcl` cuando corresponda para reproducibilidad.
- Valida al menos con `terraform fmt -check`, `terraform init` contra el backend correcto, `terraform validate` y un `terraform plan` revisado. No publiques un plan/log si contiene valores sensibles.

### 3. Respaldo y restauración con Velero (rúbrica 2.3 y 2.6)

- Debe existir al menos un microservicio con estado (base de datos) respaldado por un volumen persistente, con datos verificables. Si ya existe desde P8, copia y adapta sus manifiestos a `P9/` en lugar de crear uno nuevo; si no existe, créalo dentro de `P9/`. Sin este servicio no hay forma legítima de demostrar restauración de datos real.
- Usa almacenamiento de objetos externo al clúster respaldado. Documenta su ubicación y separación del dominio de fallo sin publicar secretos.
- Define en código un `Schedule` con cron y TTL/retención explícitos, alcance de namespaces/recursos y mecanismo real de respaldo de volúmenes persistentes (CSI snapshots cuando sean recuperables tras perder el clúster, o file-system backup/node-agent cuando corresponda).
- Verifica `BackupStorageLocation` disponible, schedule creado y al menos un backup real en estado `Completed` antes de la evaluación.
- La prueba de restauración debe insertar un dato identificable, registrar cuándo se escribió y cuándo se tomó el respaldo, eliminar el dato o volumen según el escenario, restaurar y consultar el contenido exacto. La mera existencia de un PVC o Pod no prueba recuperación de datos.
- Calcula el RPO a partir del último dato recuperado frente al punto del desastre; no lo confundas con la duración de la restauración.

### 4. Continuidad de secretos (rúbrica 2.4)

- Para Sealed Secrets, respalda el par de llaves del controlador fuera del clúster y fuera del repositorio, cifrado y con acceso controlado. Nunca versiones la llave privada.
- Automatiza su recuperación desde una entrada segura durante el bootstrap y restáurala antes de sincronizar los `SealedSecret` que dependen de ella. Fuerza/reinicia la reconciliación solo cuando sea necesario y valida el resultado.
- Demuestra después de reconstruir que el controlador puede descifrar los secretos y que una carga consume el `Secret` resultante. Diagnostica eventos reales del controlador (por ejemplo, fallos de unseal/ciphertext o de actualización) sin asumir un código de error único.
- Si se migra a External Secrets, el proveedor y los valores deben vivir fuera del clúster destruido; documenta identidad, permisos mínimos, orden de instalación y prueba de reconciliación.

### 5. Resiliencia ante pérdida de nodo (rúbrica 2.5)

- Configura réplicas suficientes, `PodDisruptionBudget`, anti-afinidad/topology spread y probes de readiness, liveness y startup coherentes. Un PDB aislado no garantiza disponibilidad.
- Asegura al menos dos nodos elegibles y distribución efectiva de réplicas; valida la ubicación de Pods antes del drenaje.
- La prueba debe ejecutar `kubectl drain` con parámetros documentados mientras una verificación continua consulta el servicio. Registra disponibilidad/errores durante el evento, reprogramación de Pods y recuperación final; luego documenta `uncordon` como cierre/contingencia.

### 6. Conservación de la Práctica 8

- Después de la reconstrucción deben seguir operando GitOps, Argo Rollouts/entrega progresiva y las políticas de admisión de Kyverno.
- Copia a `P9/` cualquier manifiesto de P8 que deba evolucionar y cambia las referencias operativas para que apunten a la copia de P9 o al repositorio GitOps correspondiente.
- Verifica que el Rollout esté saludable, que la sincronización automática siga habilitada y que las políticas continúen en modo de cumplimiento. No reutilices capturas o corridas de P8 como evidencia de que P9 sobrevivió a la reconstrucción.

## Documentación y evidencia obligatorias

### Runbook de recuperación (rúbrica 1.1)

- Escríbelo para un tercero sin conocimiento previo ni acceso al autor.
- Incluye prerrequisitos, variables de entrada, permisos, punto de entrada, orden de dependencias y criterio exacto de inicio/fin del RTO.
- Cada paso debe contener: objetivo, comando Bash completo y copiable, resultado esperado, comando de validación y contingencia/rollback si falla.
- No uses placeholders ambiguos como `<completar>` sin explicar de dónde obtiene el operador el valor. No dependas de conocimiento oral o de la UI.
- Incluye procedimientos para reconstrucción total, restauración de datos, continuidad de secretos, prueba de nodo y verificación final del flujo heredado de P8.

### Informe de la prueba de DR (rúbrica 1.2 y sección 4.2)

- No debe exceder dos páginas y debe responder exactamente estos seis campos: **Objetivos declarados (RTO/RPO), Escenario ejecutado, Tiempos medidos, Pérdida medida, Puntos únicos de fallo detectados, Brecha y plan**.
- Declara y justifica RTO/RPO antes de ejecutar la prueba; no los ajustes retroactivamente para que coincidan con el resultado.
- Define con precisión los eventos de inicio y fin, usa marcas de tiempo reales con zona horaria consistente y muestra el cálculo de RTO y RPO.
- Si lo medido incumple lo declarado, conserva el resultado y redacta causa raíz, impacto, limitaciones y mitigación. La honestidad técnica tiene prioridad sobre aparentar cumplimiento.

### Diagrama del bootstrap (rúbrica 1.3)

- Representa el proceso de recuperación, no solo una arquitectura genérica.
- Muestra el orden de reconstrucción, dependencias, fronteras dentro/fuera del clúster y quién crea cada componente: backend remoto, Terraform/AKS, ArgoCD, aplicación raíz, controladores, llave/proveedor de secretos, Velero, restauración de datos y workloads.
- Distingue visualmente lo automático de las acciones humanas permitidas (por ejemplo, iniciar el comando y aportar credenciales seguras). Si aparece un paso manual intermedio, trátalo como una brecha del bootstrap, no como cumplimiento.
- El diagrama debe coincidir con los scripts y manifiestos reales.

### Preguntas teóricas (rúbrica 1.4)

- Responde sobre el comportamiento real de este sistema y este escenario de pérdida, no con definiciones memorizadas.
- Sustenta cada respuesta con rutas de implementación, evidencia observada y consecuencias concretas para RTO/RPO, disponibilidad y pérdida de datos.
- Reconoce límites, supuestos, dominios de fallo y puntos únicos de fallo. Evita afirmaciones que contradigan los logs o el informe.

### README de entrega y enlaces (secciones 4 y 4.1)

- `P9/README.md` debe describir P9 y contener completa la tabla exacta de enlaces obligatorios: repositorio GitOps; nombre y namespace de la aplicación raíz; punto de entrada; tipo/ubicación del backend sin credenciales; nombre/destino del schedule; evidencia de reconstrucción; evidencia de restauración; evidencia de pérdida de nodo; RTO/RPO declarados y medidos; URL y minutaje del video.
- Trata como bloqueantes los requisitos de la sección 8.1: P8 aprobada, sistema desplegado/sincronizado, estado remoto sin state en Git, backup Velero `Completed` y tabla del README completa.
- Comprueba que cada ruta exista, que cada ancla/enlace sea correcto y que los enlaces exigidos como públicos abran sin autenticación. No reemplaces un campo pendiente con una URL ficticia.
- El video debe durar entre 5 y 8 minutos y el README debe indicar el minutaje por punto demostrado.

### Integridad de la evidencia

- Guarda evidencia de P9 bajo una estructura clara dentro de `P9/`, con nombres consistentes y sin secretos.
- Para pruebas cronometradas, conserva comandos, salidas y timestamps (preferiblemente ISO 8601); documenta zona horaria, contexto de Kubernetes y recursos afectados.
- Relaciona cada evidencia desde el README/runbook/informe. Las capturas deben ser legibles, pero conserva también evidencia textual cuando sea posible.
- Evidencia anterior puede servir como contexto, nunca como sustituto de la reconstrucción, restauración o drenaje realizados para P9.

## Anti-patrones prohibidos

Esta sección lista atajos que parecen razonables bajo presión de tiempo pero que violan la rúbrica, la honestidad técnica o el espíritu de la práctica. Si alguno aparece en el entregable, trátalo como incumplimiento, no como "aproximación aceptable". Si dudas si algo cae aquí, pregunta antes de escribirlo.

### Bootstrap (rúbrica 2.1)
- **`kubectl apply` manual como parte del bootstrap.** Aunque sea "solo un manifiesto", rompe el requisito de único punto de entrada sin pasos manuales.
- **Pulsar `Sync` en la UI de ArgoCD como paso documentado.** Si el operador entra a la UI, no es bootstrap automatizado.
- **"Ahora copie el kubeconfig / la llave / el secreto…"** como paso del runbook de reconstrucción. El bootstrap obtiene credenciales de una fuente segura (identidad administrada, OIDC, secret store), no de un archivo que el operador pega a mano.
- **Depender de artefactos que serán destruidos.** El bootstrap no puede asumir que existe un namespace, Secret, PVC o CRD del clúster anterior.
- **Aplicación raíz que se administra a sí misma o crea a su padre.** Ciclo de administración = ArgoCD en bucle. Documenta quién administra cada recurso.

### Terraform (rúbrica 2.2 y bloqueante 8.1)
- **Estado local `terraform.tfstate` dentro de `P9/`.** Bloqueante directo de calificación.
- **`terraform.tfvars`, planes o crash logs versionados.** Aunque hoy no tengan secretos, mañana sí.
- **`terraform apply` desde la laptop del autor como único mecanismo de bootstrap.** Si el operador no puede reproducirlo desde una máquina limpia, no es recuperable.
- **Backend remoto creado a mano desde el portal.** El problema huevo-gallina se resuelve en código o script, no con "primero crea el storage account".

### Velero (rúbricas 2.3 y 2.6)
- **Respaldos almacenados en el mismo clúster o en el mismo dominio de fallo.** Eso no es DR, es una copia.
- **Schedule sin `ttl`/retención explícita en código.** La rúbrica pide política de retención declarada.
- **Backup manual presentado como "programado".** El `Schedule` debe existir en manifiesto, no como comando puntual.
- **Restaurar y validar solo que el PVC o el Pod existen.** La rúbrica 2.6 exige verificar contenido real, no volumen vacío.
- **Restaurar sin haber insertado antes un dato identificable.** Sin dato conocido de antemano, no hay forma legítima de probar recuperación.
- **Confundir RPO con duración de restauración.** RPO es cuánto dato se perdió; no cuánto tardó el `restore`.

### Secretos (rúbrica 2.4)
- **Llave privada de Sealed Secrets en el repositorio, en un bucket sin cifrado propio, o en el propio `CLAUDE.md`.**
- **"Reencriptar todos los SealedSecrets con la nueva llave"** como estrategia de continuidad. Eso no es continuidad: asume que aún puedes descifrarlos, lo cual ya no es cierto.
- **`kubectl create secret` manual como mecanismo de recuperación.** No es automatizable ni auditable.
- **Asumir que el controlador nuevo descifra automáticamente.** Sin la llave correcta falla y la app arranca con secretos vacíos sin error visible.
- **Documentar la llave en texto plano en el runbook "para el operador".** El runbook indica cómo obtenerla de la fuente segura, no la contiene.

### Resiliencia (rúbrica 2.5)
- **`kubectl drain --force --disable-eviction` durante la prueba.** Anula el PDB y por tanto anula la prueba. Solo se documenta como contingencia, no como camino feliz.
- **`podAntiAffinity: required` con 2 réplicas en un clúster de 2 nodos.** Puede dejar el segundo pod en `Pending` para siempre.
- **PDB con `minAvailable` igual al número de réplicas.** Bloquea el drain indefinidamente.
- **Probes copiadas de un tutorial con timeouts por defecto.** Un `readinessProbe` agresivo saca pods sanos del endpoint durante el drenaje.
- **Presentar el PDB como prueba de resiliencia sin haber drenado un nodo.** La rúbrica pide evidencia real del drenaje con el servicio respondiendo.

### Evidencia y reportes (rúbricas 1.1–1.4, secciones 4 y 8.1)
- **Ajustar RTO/RPO después de medir.** El enunciado lo penaliza explícitamente.
- **Capturas o corridas de P8 presentadas como evidencia de P9.** No sobrevivieron a la reconstrucción de P9.
- **Estados `Healthy`/`Completed` inventados o "esperados".** Si no se observó, se marca `pendiente`.
- **Tiempos estimados redactados como medidos.** El informe exige marcas de tiempo reales con zona horaria consistente.
- **Placeholders `<completar>` o `TODO` en el runbook sin indicar de dónde obtiene el valor el operador.**
- **Enlaces del README que requieren autenticación.** El enunciado (4.1) califica con cero ese criterio sin búsqueda adicional.
- **Video fuera de 5–8 minutos o sin minutaje por punto demostrado.**
- **Runbook que requiere conocimiento oral.** Si el autor tiene que explicar algo en persona, no es ejecutable por un tercero.

### Proceso y repositorio
- **Editar `P1/`–`P8/` "para que funcione P9".** Fuera de alcance.
- **Modificar workflows de `.github/` sin filtro `paths` limitado a `P9/**`.** Rompe entregas previas.
- **Commitear kubeconfig, cache de `az login`, tokens, `.terraform/` o llaves.**
- **Ejecutar `terraform destroy`, borrar el resource group o el clúster sin autorización explícita del usuario.**
- **Declarar la práctica "terminada" sin haber corrido las validaciones estáticas** (`terraform fmt -check`, `validate`, `plan` revisado, lint/render de Helm, parseo de YAML, revisión de scripts/workflows).

## Validación antes de declarar terminado

1. Construye una matriz final de los criterios 1.1–1.4 y 2.1–2.6 con ruta de implementación, comando de verificación, evidencia y estado real.
2. Ejecuta validaciones estáticas pertinentes: formato/validación de Terraform, lint/render de Helm, parseo de YAML y revisión de scripts/workflows. No afirmes que una herramienta pasó si no se ejecutó.
3. Verifica que el bootstrap sea realmente de un solo comando desde condiciones de día cero y no dependa de artefactos que serán destruidos.
4. Verifica en vivo, cuando el usuario autorice la prueba: reconstrucción cronometrada, restauración y consulta del dato real, secretos descifrables, drenaje sin caída y controles de P8 operativos.
5. Busca secretos y artefactos prohibidos antes de entregar; confirma en especial que no haya `*.tfstate`, `terraform.tfvars`, kubeconfigs, llaves de Sealed Secrets ni credenciales rastreadas.
6. Revisa consistencia global: nombres de clúster/namespace/aplicación, rutas P9, valores de RTO/RPO, timestamps, resultados, diagrama, runbook, informe, README y video deben describir la misma ejecución real.

Si una validación que requiere Azure, GitHub, el repositorio GitOps u otro servicio externo no puede ejecutarse, deja el estado como pendiente y entrega el comando exacto para realizarla; nunca conviertas una suposición en evidencia.
