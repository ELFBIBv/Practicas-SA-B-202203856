# Plan de Implementación: CRUD de Solicitudes Operativas

Este plan detalla los pasos para implementar las operaciones solicitadas para la entidad **Solicitud Operativa**, siguiendo las buenas prácticas de diseño REST y los principios SOLID (específicamente responsabilidad única e inyección de dependencias) mediante una arquitectura en capas.

## Propósito

Añadir el soporte para la gestión completa (CRUD) y actualización parcial del estado de las solicitudes operativas en el backend escrito en Go, utilizando la base de datos SQLite y el framework de enrutamiento `go-chi`.

## User Review Required

> [!IMPORTANT]
> Se crearán nuevas carpetas en el directorio `internal` para mantener la separación de responsabilidades: `models`, `repository`, y `services`.
> Revisa el diseño propuesto y, si estás de acuerdo, confírmalo para proceder con la ejecución.

## Proposed Changes

### Database Layer
Modificaremos la inicialización de la base de datos para crear la nueva tabla requerida.

#### [MODIFY] database.go
Actualizaremos `internal/database/database.go` para incluir el comando SQL de creación de la tabla `solicitudes_operativas` con las columnas requeridas (`id`, `titulo`, `area_solicitante`, `prioridad`, `costo_estimado`, `estado`).

---

### Domain Layer (Models)
Definiremos la estructura de los datos que fluirá a través de las capas.

#### [NEW] internal/models/solicitud.go
Creación del modelo `SolicitudOperativa` con los campos solicitados y sus correspondientes tags JSON para la serialización.

---

### Data Access Layer (Repositories)
Encapsularemos el acceso a la base de datos para separar esta lógica del resto de la aplicación (Repository Pattern).

#### [NEW] internal/repository/solicitud_repository.go
Se creará la interfaz `SolicitudRepository` y su implementación `solicitudRepository` que contendrá los métodos:
- `GetAll()`
- `Create(solicitud)`
- `Update(solicitud)`
- `Delete(id)`
- `UpdateStatus(id, estado)`

---

### Business Logic Layer (Services)
Se encargará de aplicar cualquier regla de negocio o validación, aislando a los controladores/handlers de la lógica de datos directa.

#### [NEW] internal/services/solicitud_service.go
Se creará la interfaz `SolicitudService` y su implementación. Dependerá de `SolicitudRepository` por medio de inyección de dependencias. Se implementarán las validaciones necesarias (por ejemplo, validación de estados permitidos: `registrada`, `en_proceso`, `finalizada`).

---

### Presentation Layer (Handlers / Controllers)
Manejará las peticiones HTTP y formateará las respuestas según REST.

#### [NEW] internal/handlers/solicitud_handler.go
Crearemos un struct `SolicitudHandler` con los siguientes endpoints:
- `GET /solicitudes`: Obtener todas las solicitudes.
- `POST /solicitudes`: Registrar una nueva.
- `PUT /solicitudes/{id}`: Actualizarla completamente.
- `DELETE /solicitudes/{id}`: Eliminar una solicitud.
- `PATCH /solicitudes/{id}/estado`: Actualizar solo el estado.

---

### Application Entrypoint
Conectaremos todo mediante inyección de dependencias y registro de las nuevas rutas.

#### [MODIFY] main.go
Actualizaremos `cmd/api/main.go` para:
1. Instanciar `SolicitudRepository`.
2. Instanciar `SolicitudService` pasándole el repositorio.
3. Instanciar `SolicitudHandler` pasándole el servicio.
4. Registrar las nuevas rutas bajo el router de `chi`.

## Verification Plan

### Automated Tests
- Al finalizar, podemos levantar la API usando un comando de `go run` para revisar el funcionamiento de la compilación.

### Manual Verification
- Te pediré que pruebes cada endpoint empleando herramientas como `curl`, Postman o Thunder Client con los payloads de ejemplo para verificar que respondan adecuadamente con los códigos HTTP REST correspondientes (200 OK, 201 Created, 204 No Content, 400 Bad Request, 404 Not Found, etc.).


----- mi observacion
crea una carpeta llamada pruebas_unitarias y colocar un archivo .http realizando pruebas para cada endpoints de manera exhaustiva
-----