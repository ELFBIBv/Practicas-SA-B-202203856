Universidad San Carlos de Guatemala Facultad de ingeniería. Ingeniería en ciencias y sistemas

## Práctica:

## Continuidad operativa y recuperación ante desastres


PONDERACIÓN: 3.75 pts

Tiempo estimado: 14 hrs

Índice

No se encontraron entradas de tabla de contenido.


## 1. MARCO FORMATIVO

## 1.1. Valor

| Nombre del valor | ¿Cómo se aplica en tu laboratorio? |
| --- | --- |
| Responsabilidad ante la pérdida | El estudiante deberá asumir que el fallo total es inevitable y no excepcional, diseñando el sistema para que la recuperación sea un procedimiento ensayado y medido, y no una improvisación bajo presión que dependa del conocimiento de una sola persona. |

## 1.2. Competencia(s)

Con la elaboración de esta práctica usted adquirirá las siguientes competencias:


- Competencia General: Evaluar la continuidad operativa de un sistema distribuido, distinguiendo entre lo que puede reconstruirse automáticamente y lo que se pierde de forma irreversible ante un desastre.

- Competencia Específica: Diseñar, implementar y ejecutar un plan de recuperación ante desastres para un ecosistema de microservicios en Kubernetes, midiendo el tiempo de recuperación y la pérdida de datos reales contra objetivos previamente declarados.

## 1.3. Habilidad(es) blandas a formar

La práctica le permitirá desarrollar las siguientes habilidades:

- Pensamiento preventivo: Identificar los puntos únicos de fallo antes de que ocurran, en lugar de reaccionar cuando el sistema ya no responde.

- Honestidad técnica: Reportar los tiempos y las pérdidas realmente medidos, aunque incumplan el objetivo declarado, en lugar de ajustar el objetivo al resultado.

- Comunicación bajo presión: Redactar procedimientos que una persona ajena al sistema pueda ejecutar durante un incidente, sin acceso al autor.

## 2. Resultado del Aprendizaje

## 2.1. Objetivo SMART

| Específico (¿Qué?) | Medible (¿Cuánto?) | Alcanzable (¿Cómo?) | Realista (¿Para qué?) | A Tiempo (¿Cuándo?) |
| --- | --- | --- | --- | --- |
| Implementar y demostrar la capacidad de recuperación ante desastres del ecosistema | Ejecutar 1 reconstrucción completa desde cero, 1 restauración de datos verificada | Utilizando Terraform con estado remoto, el patrón app- of-apps de ArgoCD, | Adquirir criterio para operar sistemas donde la pérdida de datos o de disponibilidad | Antes del XX de noviembre de 2026 a las 23:59 hrs, entregando el repositorio vía |


| Específico (¿Qué?) | Medible (¿Cuánto?) | Alcanzable (¿Cómo?) | Realista (¿Para qué?) | A Tiempo (¿Cuándo?) |
| --- | --- | --- | --- | --- |
| de microservicios construido en las prácticas anteriores. | y 1 prueba de pérdida de nodo, midiendo el RTO y el RPO reales. | respaldos con Velero y continuidad de secretos. | tiene consecuencias irreversibles. | UEDI. |

## 3. Enunciado de la Práctica.

## 3.1 Descripción del problema a resolver

El sistema entregado en la Práctica 8 se despliega de forma controlada y segura, pero nunca ha sido sometido a una pérdida real. Al revisarlo con criterio de continuidad aparecen tres debilidades:

- Los datos de las bases de datos viven en volúmenes que nadie respalda: si se pierden, no existe forma de recuperarlos.

- El estado de Terraform reside en la máquina del estudiante, de modo que la infraestructura solo puede reconstruirla una persona desde un único equipo.

- Los secretos están cifrados en el repositorio, pero la llave que los descifra vive únicamente dentro del clúster: si el clúster se pierde, el repositorio queda lleno de contenido ilegible.

Se le solicita convertir el sistema en uno recuperable. Deberá declarar un objetivo de tiempo de recuperación (RTO) y un objetivo de punto de recuperación (RPO), implementar los mecanismos necesarios para alcanzarlos y, sobre todo, demostrarlos destruyendo el entorno y reconstruyéndolo con el cronómetro corriendo.

## 3.2 Alcance de la práctica

El estudiante deberá cumplir con las siguientes actividades:


- Bootstrap de día cero: la reconstrucción completa debe iniciarse desde un único punto de entrada. Terraform provisiona el clúster e instala ArgoCD, y a partir de ahí el patrón app-of-apps o un ApplicationSet levanta el resto del sistema. No se admite ningún paso manual intermedio.

- Estado remoto de Terraform: el estado debe residir en un backend remoto con bloqueo. No se acepta el archivo de estado local ni versionado en el repositorio.

- Respaldos programados con Velero: con calendario definido, política de retención declarada, inclusión de volúmenes persistentes y almacenamiento fuera del clúster que se respalda.

- Servicio con estado: al menos un microservicio con base de datos y volumen persistente, con datos verificables que permitan comprobar que la restauración recuperó contenido real y no un volumen vacío.

- Continuidad de los secretos: respaldo y restauración de la llave de Sealed Secrets, o bien migración a External Secrets con un proveedor externo al clúster. Debe demostrarse que los secretos siguen siendo descifrables tras la reconstrucción.

- Resiliencia ante pérdida de nodo: PodDisruptionBudget, reglas de anti-afinidad y número de réplicas suficientes para que el servicio siga respondiendo durante el drenaje de un nodo.

- Prueba de recuperación cronometrada: destrucción y reconstrucción completa del entorno, con marcas de tiempo que permitan calcular el RTO real.

- Prueba de restauración de datos: eliminación de datos existentes y su recuperación desde el respaldo, verificando el contenido restaurado y calculando el RPO real.

- RTO y RPO declarados: objetivos definidos y justificados antes de las pruebas, contrastados después contra los tiempos medidos. Una diferencia entre lo declarado y lo medido no penaliza si se analiza con honestidad.

- Runbook de recuperación: procedimiento ejecutable por un tercero que no conozca el sistema, sin acceso al autor.

- Conservación del flujo de la Práctica 8: GitOps, entrega progresiva y políticas de admisión deben seguir operando tras la reconstrucción.


## 3.3 Requerimientos técnicos

El estudiante deberá utilizar o integrar las siguientes herramientas y tecnologías:

- Terraform con backend remoto y bloqueo de estado.

- ArgoCD con patrón app-of-apps o ApplicationSet.

- Velero para respaldo y restauración.

- Almacenamiento de objetos externo al clúster para los respaldos.

- Sealed Secrets o External Secrets.

- PodDisruptionBudget, anti-afinidad y probes de Kubernetes.

- Base de datos con volumen persistente.

- El ecosistema de microservicios y el flujo GitOps de la Práctica 8.

## 4. Entregables

| Tipo | Descripción |
| --- | --- |
|   | Repositorio de código Carpeta /P9 con Terraform, scripts de bootstrap, pruebas y documentación. |
| Repositorio GitOps | Manifiestos actualizados, incluyendo el app-of-apps y los recursos de resiliencia. |
|   | README de entrega Ubicado en /P9, con la tabla de enlaces obligatoria de la sección |


| Tipo | Descripción |
| --- | --- |
|   | 4.1. |
| Bootstrap | Punto de entrada único documentado, con evidencia de su ejecución completa. |
| Configuración de respaldos | Schedule de Velero, política de retención y destino de almacenamiento. |
| Evidencia de reconstrucción | Registro con marcas de tiempo del entorno destruido y reconstruido. |
| Evidencia de restauración | Datos eliminados y recuperados, con verificación del contenido. |
| Evidencia de pérdida de nodo | Drenaje de un nodo con el servicio respondiendo durante el proceso. |
| Informe de la prueba de DR | RTO y RPO declarados frente a los medidos, según la plantilla de la sección 4.2. |
| Runbook de recuperación | Procedimiento paso a paso ejecutable por un tercero. |
|   | Diagrama del bootstrap Orden de reconstrucción y dependencias entre componentes. |


| Tipo | Descripción |
| --- | --- |
| Video demostrativo | De 5 a 8 minutos, con minutaje indicado en el README. |

## 4.1 Tabla de enlaces obligatoria

El README de la carpeta /P9 deberá incluir la siguiente tabla completamente llena. Un enlace ausente, roto o que requiera autenticación se calificará con cero en el criterio correspondiente, sin búsqueda adicional dentro del repositorio.

| Ítem | Enlace o dato requerido |
| --- | --- |
| Repositorio GitOps | URL pública |
|   | Aplicación raíz en ArgoCD Nombre exacto de la aplicación app-of-apps y namespace |
| Punto de entrada del bootstrap | Ruta exacta del comando o script dentro del repositorio |
| Backend remoto de Terraform | Tipo y ubicación, sin credenciales |
| Schedule de Velero | Nombre del schedule y destino de los respaldos |
| Reconstrucción cronometrada | Ruta del registro con marcas de tiempo |


| Ítem | Enlace o dato requerido |
| --- | --- |
| Restauración de datos | Ruta de la evidencia de verificación |
| Prueba de pérdida de nodo Ruta de la evidencia |   |
| RTO y RPO declarados | Valores objetivo y valores medidos |
| Video demostrativo | URL y minutaje por punto demostrado |

## 4.2 Plantilla del informe de la prueba de DR

El informe no deberá exceder dos páginas y deberá responder exactamente estos seis campos:

- Objetivos declarados: RTO y RPO comprometidos, con su justificación.

- Escenario ejecutado: qué se destruyó exactamente y en qué orden.

- Tiempos medidos: RTO real, con las marcas de tiempo que lo respaldan.

- Pérdida medida: RPO real, indicando qué datos no se recuperaron y por qué.

- Puntos únicos de fallo detectados: lo que la prueba reveló que no estaba cubierto.

- Brecha y plan: diferencia entre lo declarado y lo medido, y qué haría para cerrarla.

## 5. Material de apoyo

- Documentación oficial de Velero: https://velero.io/docs/


- Patrón app-of-apps de ArgoCD: https://argo-cd.readthedocs.io

- ApplicationSet de ArgoCD: https://argocd-applicationset.readthedocs.io

- Backends remotos de Terraform: https://developer.hashicorp.com/terraform/language/backend

- Disruptions y PodDisruptionBudget: https://kubernetes.io/docs/concepts/workloads/pods/disruptions/

- External Secrets Operator: https://external-secrets.io

- Capítulo de gestión de incidentes del libro Site Reliability Engineering de Google.

## 6. Recursos y herramientas a utilizar

- Infraestructura como código: Terraform con backend remoto.

- Entrega continua: ArgoCD con app-of-apps o ApplicationSet, Argo Rollouts.

- Respaldo y recuperación: Velero y almacenamiento de objetos externo.

- Gestión de secretos: Sealed Secrets o External Secrets.

- Orquestación: K8s (Kubernetes), PodDisruptionBudget y anti-afinidad.

- Persistencia: Base de datos con volumen persistente y StorageClass.

- Versionamiento y automatización: GitHub y GitHub Actions.


## 7. Cronograma

| Tipo | Fecha Inicio | Fecha Fin |
| --- | --- | --- |
| Asignación de Práctica | 17/11/2026 | 17/11/2026 |
| Elaboración | 17/11/2026 | 24/11/2026 |
| Calificación | 26/11/2026 | 26/11/2026 |

## 8. Rúbrica de Calificación

## 8.1 Requisitos para optar a la calificación

Antes de la evaluación de la práctica, los estudiantes deben cumplir con los requisitos que se indiquen en esta sección.

| Tema | Descripción | Cumple (Sí/No) |
| --- | --- | --- |
| Práctica 8 | Contar con el desarrollo de la Práctica 8 previamente calificado. |   |
| Sistema operativo | El sistema se encuentra desplegado y sincronizado al iniciar la calificación. |   |
| Estado remoto | El estado de Terraform reside en un backend remoto; no existe archivo de estado en el repositorio. |   |


| Tema | Descripción | Cumple (Sí/No) |
| --- | --- | --- |
| Respaldo existente | Existe al menos un respaldo completado con Velero, verificable en el momento. |   |
| README de entrega | La tabla de enlaces obligatoria está completa y todos los enlaces son accesibles públicamente. |   |

## 8.2 Resumen de Puntuaciones

| Área | Puntos Totales (Base 100) | Puntos Obtenidos |
| --- | --- | --- |
| 1. Habilidades (40%) |   |   |
| Runbook de recuperación | 12 |   |
| Informe de la prueba de DR | 12 |   |
| Diagrama del bootstrap | 6 |   |
| Preguntas teóricas | 10 |   |
| Sub-Total Habilidades | 40 |   |


## Detalle de la Calificación

| No. | Criterio de evaluación Punteo | máximo | Satisfactorio (100% - 61%) | Necesita mejorar (60% - 0%) | Punteo Obtenido |
| --- | --- | --- | --- | --- | --- |
| 1 | Habilidades | 40 |   |   |   |
| 1.1 | Runbook de recuperación | 12 | Procedimiento ejecutable por un tercero, con comandos concretos, orden de dependencias y verificaciones en cada paso. | Descripción general del sistema en lugar de un procedimiento, o pasos que requieren conocimiento no documentado. |   |
| 1.2 | Informe de la prueba de DR | 12 | Presenta los seis campos con tiempos reales, identifica puntos únicos de fallo y analiza con honestidad la brecha entre lo declarado y lo medido. | Tiempos estimados en lugar de medidos, o ausencia de análisis de la brecha. |   |
| 1.3 | Diagrama del bootstrap 6 |   | Muestra el orden de reconstrucción y las dependencias entre componentes, distinguiendo lo automático de lo manual. | Diagrama de arquitectura genérico que no refleja el proceso de recuperación. |   |
| 1.4 | Preguntas teóricas | 10 | Analiza el comportamiento de su propio sistema ante | Respuestas memorizadas o contradictorias con la |   |


| No. | Criterio de evaluación Punteo | máximo | Satisfactorio (100% - 61%) | Necesita mejorar (60% - 0%) | Punteo Obtenido |
| --- | --- | --- | --- | --- | --- |
|   |   |   | escenarios de pérdida y reconoce sus límites. | evidencia entregada. |   |
| 2 | Conocimiento | 60 |   |   |   |
| 2.1 | Bootstrap automatizado 14 |   | Un único punto de entrada reconstruye el sistema completo: Terraform instala ArgoCD y el app-of-apps levanta el resto, sin pasos manuales. | La reconstrucción requiere intervención manual o el orden no está automatizado. |   |
| 2.2 | Estado remoto y disciplina de IaC | 8 | Estado en backend remoto con bloqueo, sin archivos de estado ni credenciales en el repositorio. | Estado local, versionado en el repositorio o sin bloqueo. |   |
| 2.3 | Respaldo y restauración con Velero | 14 | Respaldos programados, con retención, volúmenes incluidos y destino externo al clúster; la restauración se demuestra funcionando. | Respaldos manuales, sin volúmenes, almacenados en el mismo clúster o nunca restaurados. |   |
| 2.4 | Continuidad de los secretos | 8 | Los secretos siguen siendo descifrables tras la reconstrucción, con el | La llave no está respaldada o la recuperación de secretos no se demuestra. |   |


| No. | Criterio de evaluación Punteo | máximo | Satisfactorio (100% - 61%) | Necesita mejorar (60% - 0%) | Punteo Obtenido |
| --- | --- | --- | --- | --- | --- |
|   |   |   | mecanismo documentado y probado. |   |   |
| 2.5 | Resiliencia ante pérdida de nodo | 8 | PodDisruptionBudget, anti- afinidad y réplicas adecuadas; el servicio responde durante el drenaje de un nodo. | Sin PDB, sin anti-afinidad, o el servicio deja de responder durante la prueba. |   |
| 2.6 | Restauración de datos verificada | 8 | Los datos eliminados se recuperan y se verifica su contenido real, no solo la existencia del volumen. | Volumen restaurado vacío, sin verificación, o restauración no demostrada. |   |

Comentarios Generales
