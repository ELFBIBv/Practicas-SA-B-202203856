# Pasos hechos - Práctica 7 (CI/CD)

Este documento explica, paso a paso y en orden, todo lo que se hizo para armar el pipeline de CI/CD, y por qué se tomó cada decisión. Está pensado para que puedas entender el "por qué" detrás de cada archivo, no solo copiar y pegar.

## 0. Conceptos base antes de empezar

- **CI (Integración Continua):** cada vez que alguien sube código, un robot (en este caso GitHub Actions) lo compila y le corre pruebas automáticamente. El objetivo es detectar errores en minutos, no cuando ya está en producción.
- **CD (Entrega/Despliegue Continuo):** una vez que el código pasó CI, se empaqueta (en nuestro caso, en imágenes Docker) y opcionalmente se despliega solo, sin que una persona tenga que meterse manualmente a un servidor.
- **Pipeline:** es simplemente la cadena de pasos (build → test → dockerizar → desplegar) que se ejecuta automáticamente. En GitHub Actions, un pipeline se define en un archivo YAML dentro de `.github/workflows/`.
- **Runner:** la máquina virtual (gratuita, de GitHub) donde corren los pasos del pipeline. No es tu computadora ni Azure; es un contenedor temporal que GitHub crea y destruye por cada ejecución.
- **Registry de contenedores:** un lugar donde se guardan las imágenes Docker ya construidas, para que después Kubernetes (u otro sistema) las pueda descargar. Usamos GHCR (GitHub Container Registry) porque ya lo usaba la Práctica 6 y no requiere crear cuentas ni secrets nuevos.

## 1. Revisar qué ya existía (P5 y P6) y respetar el límite entre prácticas

Antes de escribir nada, se revisó:

- **P5**: el código fuente de los 5 microservicios (`api-gateway` en Nginx, `auth-service` en Node/TypeScript, `catalog-service` y `order-service` en Python/FastAPI, `notification-service` en Go) más 2 cronjobs en Python. Cada uno ya tenía su propio `Dockerfile`.
- **P6**: el chart de Helm (`charts/sa-platform`) usado para desplegar todo eso en un clúster de Azure Kubernetes Service (AKS), y el `README.md` con el procedimiento manual que se siguió para crear el clúster, instalar el chart y probarlo. Importante: **P6 nunca modificó `/P5`**, solo reutilizó las imágenes ya publicadas en GHCR.
- Se confirmó que el código de los microservicios **no tenía ninguna prueba automatizada**: solo archivos `.http` para probar manualmente con un cliente REST. Esto era importante porque la Práctica 7 exige "ejecución de pruebas automáticas" como una de las 4 etapas obligatorias del pipeline, así que había que escribir pruebas de verdad, no solo simularlas.
- Se detectó que la carpeta `P7/` ya tenía una copia idéntica del chart de Helm de P6 (`P7/charts/sa-platform`), del script de smoke test y de un `docs/EVIDENCIAS.md`.

**Corrección importante durante el desarrollo:** en un primer intento, las pruebas y los ajustes de configuración se escribieron directamente dentro de `/P5`, razonando que P5/P6/P7 eran "la misma app" en distintas etapas. Esto estaba mal: cada práctica es una entrega independiente y autocontenida, igual a como P6 nunca tocó `/P5`. La corrección fue: revertir todos los cambios en `/P5` (quedó exactamente como estaba), copiar el código de los microservicios hacia `/P7` (`P7/api-gateway`, `P7/auth`, `P7/catalog`, `P7/orders`, `P7/notifications`, `P7/cronjobs`), y aplicar ahí todas las pruebas, `Dockerfile`s de referencia y el workflow. Así, `/P7` queda con todo lo necesario para calificar esta práctica por sí sola, tal como pide la rúbrica de organización de repositorio, y `/P5` sigue siendo exclusivamente la entrega de la Práctica 5.

## 2. Decidir el registro de imágenes: GHCR y no DockerHub

Se eligió **GitHub Container Registry (GHCR)** en vez de DockerHub por estas razones concretas:

1. P6 ya publicaba ahí sus imágenes (`ghcr.io/elfbibv/sa-*`), así que mantener el mismo registro evita crear cuentas o secrets nuevos.
2. GHCR se autentica con el `GITHUB_TOKEN` que GitHub genera automáticamente en cada ejecución del workflow. No hay que crear ni guardar ninguna contraseña para que el paso de *build + push* funcione.
3. Como no vamos a hacer deploy todavía, esto significa que **hoy mismo se puede probar el pipeline completo de CI (build, test, dockerización y push) sin configurar nada extra en GitHub**, más allá de quizás un ajuste de permisos (ver sección 6).

## 3. Diseñar las pruebas automáticas por servicio

Esta fue la parte que más análisis requirió, porque cada servicio usa un lenguaje distinto y depende de una base de datos distinta. La decisión general fue: **usar bases de datos reales dentro del propio job de GitHub Actions** (llamados "service containers"), en lugar de solo simular todo con mocks. Esto es más representativo de un pipeline real y detecta errores que un mock no vería (por ejemplo, un `CREATE TABLE` mal escrito).

| Servicio | Qué se agregó | Por qué así |
| --- | --- | --- |
| `auth-service` | `security.test.ts` y `jwt.test.ts`, usando el test runner integrado de Node (`node:test`) | Las funciones de cifrado AES, hash de contraseñas y JWT son puras (no tocan la base de datos), así que se pueden probar sin levantar nada extra. |
| `catalog-service` | `tests/test_main.py` con `pytest` + `TestClient` de FastAPI | Se prueba contra un contenedor real de `mongo:6` porque el cliente de Mongo se crea al importar el módulo (`client = MongoClient(...)`), lo cual hace que "mockear" la base de datos sea más complicado que simplemente darle una real y efímera. |
| `order-service` | `tests/test_main.py` | Se usa un contenedor real de `mysql:8.0` para el INSERT/SELECT de órdenes, pero se simulan (con `monkeypatch`) las dos únicas dependencias externas de red: la llamada HTTP a `catalog-service` y la publicación en NATS. No tenía sentido levantar esos dos servicios solo para esta prueba. |
| `notification-service` | `main_test.go` | El código original definía los handlers HTTP como funciones anónimas dentro de `main()`, lo cual los hace imposibles de probar por separado. Se hizo un **refactor mínimo**: se sacaron `healthHandler` y `rootHandler` como funciones con nombre a nivel de paquete, sin cambiar su comportamiento. Así se pueden probar con `httptest` sin necesitar un servidor real. |
| `cron1` | `tests/test_main.py` | Corre el script real contra un `mysql:8.0` de verdad y verifica que el registro se insertó. |
| `cron2` | `tests/test_main.py` | Igual que cron1 contra MySQL real, pero simula la conexión a NATS (con `AsyncMock`) porque levantar JetStream con un stream configurado no aportaba nada a esta prueba puntual. |
| `api-gateway` | Nada (no tiene lógica propia) | Es solo un `nginx.conf` estático; su única validación posible es que la imagen construya, lo cual ya cubre la etapa de dockerización. |

Detalles técnicos que costó resolver:

- **`pytest.ini` con `pythonpath = .`:** al poner las pruebas dentro de una carpeta `tests/` sin `__init__.py`, pytest no agregaba automáticamente el directorio del servicio (donde vive `main.py`) al `sys.path`, y las pruebas fallaban con `ModuleNotFoundError: No module named 'main'`. Se agregó un `pytest.ini` en cada servicio Python con `pythonpath = .` para resolverlo.
- **`requirements-dev.txt` separado de `requirements.txt`:** las dependencias de prueba (`pytest`, `httpx`, `pytest-asyncio`) no deben terminar dentro de la imagen Docker de producción, así que se creó un archivo aparte que se instala solo en el job de CI, nunca en el `Dockerfile`.
- **`.dockerignore` por servicio:** se agregó para excluir la carpeta `tests/` y `requirements-dev.txt` de las imágenes finales, manteniéndolas igual de livianas que antes.
- **`tsconfig.json` de `auth-service`:** se agregó `**/*.test.ts` a la lista de `exclude` para que `tsc` (el compilador de TypeScript que arma la imagen de producción) no intente compilar los archivos de prueba.

## 4. Validar todo localmente antes de confiar en GitHub Actions

En vez de subir el pipeline a ciegas y esperar a ver si fallaba en GitHub, se validó cada pieza en esta misma máquina, sobre el código ya copiado en `/P7`, usando exactamente las mismas herramientas que usará la CI:

1. Se instaló y corrió `pnpm run build` + `pnpm run test` para `P7/auth/auth-service` → **4 pruebas pasaron**.
2. Se corrió `go vet` + `go test` para `P7/notifications/notification-service` → **3 pruebas pasaron**.
3. Se levantaron contenedores Docker reales de `mysql:8.0` y `mongo:6` en esta máquina (los mismos "service containers" que usará GitHub Actions), se aplicó el esquema SQL de `P7/orders/orders-db/init.sql`, y se corrieron las pruebas de `catalog-service`, `order-service`, `cron1` y `cron2` contra esas bases de datos reales → **8 pruebas pasaron en total**.
4. Se destruyeron esos contenedores de prueba al terminar (no quedó nada corriendo en tu máquina), y se repitió toda esta validación después de mover el código de `/P5` a `/P7` para confirmar que seguía funcionando igual.

Esto da bastante confianza de que, cuando hagas push, el workflow de GitHub va a pasar en verde a la primera, porque ya se probó con el mismo motor de bases de datos y las mismas versiones de dependencias que usará la CI.

## 5. Escribir el workflow de GitHub Actions

El archivo [`/.github/workflows/ci-cd.yml`](../.github/workflows/ci-cd.yml) tiene 4 grupos de jobs:

1. **6 jobs de prueba** (uno por servicio, descritos arriba), que corren en paralelo.
2. **1 job de build + push** (`build-and-push`), que solo arranca si los 6 anteriores pasaron (`needs:`), y usa una matriz para repetir el mismo proceso con las 7 imágenes (incluyendo `api-gateway`, que no tiene job de prueba propio).
3. **1 job de despliegue** (`deploy-to-aks`), que tiene una condición (`if:`) que lo mantiene inactivo salvo que se dispare manualmente el workflow con la casilla `deploy` marcada.

Decisiones de diseño relevantes:

- **`concurrency`**: si haces dos pushes seguidos a la misma rama, GitHub cancela la ejecución vieja en vez de dejarlas correr ambas y desperdiciar minutos.
- **Etiquetado de imágenes (`docker/metadata-action`)**: cada imagen se etiqueta con el nombre de la rama y el hash corto del commit siempre, con `latest` solo si el push fue a la rama principal, y con la versión semántica solo si el push fue un tag `vX.Y.Z`. Así nunca se pisa por accidente la imagen `v1.0.0` que ya está funcionando en el `values-azure.yaml` de P6.
- **`push: false` en Pull Requests**: en un PR solo se *construye* la imagen (para detectar un `Dockerfile` roto) pero no se publica nada. Publicar imágenes de código que todavía no fue aprobado no tiene sentido.
- **El job de deploy nunca corre solo:** se requiere `workflow_dispatch` (un clic manual en la pestaña Actions) **y** el checkbox `deploy=true`. Ni un `push` normal ni un Pull Request lo disparan. Esto fue a propósito, siguiendo la instrucción de no gastar créditos de Azure todavía.
- **Por qué el deploy usa un PAT (`GHCR_PAT`) y no el `GITHUB_TOKEN`:** el `GITHUB_TOKEN` que usa el job de build/push es válido solo mientras dura esa ejecución del workflow. Si se usara ese mismo token para crear el `imagePullSecret` dentro del clúster de Kubernetes, el secret dejaría de funcionar en cuanto el workflow terminara, y el clúster no podría volver a descargar la imagen (por ejemplo, si un pod se reinicia horas después). Por eso, para ese paso específico, se necesita un Personal Access Token de larga duración, igual al que ya usaste manualmente al configurar `ghcr-secret` en la Práctica 6.

## 6. Qué falta hacer del lado de GitHub (permisos)

No se necesita nada para probar Build + Test + Push a GHCR salvo, posiblemente, un ajuste de permisos si el push a GHCR falla:

- **Settings → Actions → General → Workflow permissions → "Read and write permissions".** Esto le da permiso al `GITHUB_TOKEN` para publicar paquetes. Si ya está en "Read and write" (o el workflow declara `permissions: packages: write`, que ya lo hace), no hay que tocar nada.

Para el despliegue (cuando decidas crear un clúster nuevo), hay que agregar los secrets y variables listados en la sección "Permisos y secrets necesarios" de `P7/README.md`. Ninguno de esos existe todavía, así que el job de deploy, si se dispara, fallará de forma controlada en el login de Azure (no hace nada destructivo).

## 7. Errores reales encontrados al ejecutar en GitHub (y cómo se diagnosticaron)

Validar en local con Docker (sección 4) le dio mucha confianza al pipeline, pero no es 100% idéntico al runner de GitHub Actions. Al hacer el primer push aparecieron dos problemas reales, cada uno con su propia causa:

### 7.1 `pnpm install` fallaba con "packages field missing or empty"

El job `test-auth-service` fallaba en el paso "Instalar dependencias". La causa: el workflow tenía fijada la versión `9` de pnpm (`pnpm/action-setup@v4` con `version: 9`), y esa versión valida de forma estricta el archivo `pnpm-workspace.yaml` que ya traía `auth-service` (copiado de P5), exigiendo un campo `packages:` que ese archivo no tiene (solo tiene `allowBuilds`, usado para aprobar la compilación nativa de `bcrypt`).

**Cómo se confirmó antes de tocar nada:** se reprodujo el error exacto en esta misma máquina fijando pnpm a la versión 9 (`corepack use pnpm@9`), y luego se confirmó que con `pnpm@12.3.4` el mismo `pnpm install --frozen-lockfile` corre sin problema, con el mismo `pnpm-workspace.yaml` intacto. Esto demostró que el archivo estaba bien y el problema era la versión fijada en el workflow.

**Fix:** cambiar `version: 9` por `version: 12.3.4` en el step `pnpm/action-setup@v4` de `auth-service`. Se verificó con `gh run list` / `gh run view` que, tras este cambio, los 6 jobs de prueba (incluido `auth-service`) pasaron en GitHub.

### 7.2 El push a GHCR fallaba con "denied: permission_denied: read_package"

Con las pruebas ya en verde, los 7 jobs de `build-and-push` construían la imagen correctamente pero fallaban al hacer push, con este error para las 7 imágenes por igual.

**Causa:** los paquetes `ghcr.io/elfbibv/sa-*` ya existían desde antes (se publicaron manualmente durante P5/P6, con un token personal, no desde un workflow de Actions). Cuando un paquete de GHCR se crea así, **no** queda conectado automáticamente al repositorio; el `GITHUB_TOKEN` de un workflow de ese repo no tiene permiso de escritura sobre él hasta que se conecta a mano. Si los paquetes no hubieran existido antes (por ejemplo, en un proyecto nuevo), el primer push del workflow los habría creado y vinculado automáticamente, sin este paso extra.

**Fix (manual, en GitHub, una sola vez por paquete):** en `https://github.com/users/ELFBIBv/packages/container/<paquete>/settings` → sección **"Manage Actions access"** → **Add Repository** → agregar `Practicas-SA-B-202203856` con rol **Write**. Se repite para los 7 paquetes.

**Lección general:** un pipeline "que se ve bien" en el YAML no garantiza que corra bien la primera vez contra servicios reales (un registry externo, permisos de una cuenta, etc.). Por eso conviene usar `gh run list` y `gh run view --json jobs` (o la pestaña Actions) para ver el resultado real de cada job, en vez de asumir que un fix ya alcanzó con solo leerlo.

## 8. Qué NO se hizo (a propósito)

- No se creó ningún recurso en Azure.
- No se crearon los secrets de Azure (`AZURE_CREDENTIALS`, `GHCR_PAT`) ni las variables del clúster.
- No se tocó `P5/` ni `P6/` (quedaron intactas como entregas de esas prácticas).
- No se disparó el job de deploy (`deploy-to-aks`): sigue apagado hasta que exista un clúster nuevo.

## 9. Próximos pasos sugeridos (en orden)

1. Hacer commit y push de `feature/Practica7` — hecho.
2. Corregir el error de `pnpm` (sección 7.1) — hecho.
3. Aplicar el fix de permisos de GHCR (sección 7.2) en los 7 paquetes — hecho.
4. Confirmar que los 6 jobs de prueba y los 7 de `build-and-push` quedaran en verde — confirmado.
5. Tomar las capturas de pantalla que pide la rúbrica como "Evidencia de ejecución" y agregarlas a `P7/README.md` — hecho (incluye una verificación extra desde Azure Cloud Shell).
6. Crear el clúster de AKS nuevo (`rg-practica7`/`aks-sa-p7`), agregar los secrets/variables de Azure, y disparar el workflow manualmente con `deploy=true` — hecho, deploy verificado con los 16 pods corriendo.

## 10. Deploy efímero adicional con kind (sin nube)

Con el deploy a AKS ya funcionando, se agregó una etapa más al pipeline: un despliegue de prueba usando **kind** (Kubernetes IN Docker), que crea un clúster de Kubernetes real pero temporal *dentro del propio runner de GitHub Actions*.

**Por qué se agregó:** hasta ese punto, el único job que aplicaba el chart de Helm de verdad era `deploy-to-aks`, y ese es manual y depende de que exista un clúster de Azure (con costo). Eso significa que un cambio al chart (por ejemplo, un typo en un `deployment.yaml`) solo se hubiera detectado si alguien disparaba manualmente el deploy a AKS. Con `kind`, ese mismo chart se prueba **automáticamente en cada push o Pull Request**, gratis, sin ninguna nube ni credenciales, porque el clúster vive y muere dentro del mismo job.

**Corrección importante en el proceso:** el primer intento fue instalar `kind` y crear un clúster de prueba en la máquina local, para validar el enfoque antes de escribir el YAML — la misma disciplina de "probar antes de entregar" que se usó para las pruebas de Python/Node/Go. Pero eso no era lo que se pedía: la idea era que esta etapa corriera dentro de GitHub Actions, no en la computadora del estudiante. Se corrigió de inmediato: se eliminó el binario descargado (nunca se llegó a crear ningún clúster ni contenedor local) y el job se escribió y se valida directamente en el workflow de GitHub.

**Cómo funciona el job `deploy-kind`:**

1. Construye las 7 imágenes con `docker buildx build --load` (quedan solo en el Docker local del runner, no se publican a ningún registry).
2. Crea el clúster con la acción `helm/kind-action`, que además instala `kubectl` y lo destruye automáticamente al terminar el job.
3. Carga cada imagen al clúster con `kind load docker-image` — como el clúster corre en contenedores separados, no ve por sí solo las imágenes del Docker del runner; hay que "inyectárselas" explícitamente.
4. Instala el chart con `helm upgrade --install`, combinando `values.yaml` + `values-dev.yaml` (que ya traían configuración pensada para un entorno local: `storageClass: standard`, que además es exactamente el nombre de la StorageClass que trae `kind` por defecto) + un `values-kind.yaml` nuevo que baja las réplicas a 1 por servicio, para no saturar los recursos limitados del runner (2 vCPU / ~7GB RAM).
5. Verifica con `kubectl get pods/pvc/svc/cronjobs`, y si algo falla, imprime `kubectl describe` y los logs de los contenedores para facilitar el diagnóstico.

**Resultado:** ahora el pipeline tiene dos niveles de despliegue automatizado: uno **automático y gratuito** (kind, en cada push) que garantiza que el chart de Helm siempre es válido, y uno **manual y real** (AKS) para cuando se necesita demostrar el despliegue en la nube.
