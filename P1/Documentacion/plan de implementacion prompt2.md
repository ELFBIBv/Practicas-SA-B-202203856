# Plan de Implementación: Estructura del Backend (Go + SQLite)

A continuación te presento la propuesta para la arquitectura y las herramientas que usaremos en el backend. Está pensada para mantener *Clean Code* y buenas prácticas, separando responsabilidades pero sin sobrecomplicar el proyecto.

## Librerías Propuestas

1. **Enrutador (Framework HTTP):** 
   - `github.com/go-chi/chi/v5`: Es muy ligero, 100% compatible con la librería estándar `net/http` de Go y excelente para crear APIs limpias. (Alternativa: *Gin* o *Fiber* si prefieres algo más opinionado).
2. **Base de Datos (SQLite):** 
   - Driver CGO-Free: `modernc.org/sqlite`. La ventaja de este driver es que **no requiere CGO** (no necesitas compilar C en tu máquina ni en Docker), lo que hará la imagen de Docker mucho más simple y ligera.
   - ORM / Query Builder: Podemos usar simplemente la librería estándar `database/sql` para mantenerlo simple y aprender bien cómo funciona por debajo, o usar un query builder ligero. Sugiero usar solo la estándar ya que mencionaste que los endpoints y la DB serán sencillos.

## Estructura de Directorios

Usaremos un enfoque simplificado del *Standard Go Project Layout*:

```text
/backend/
├── cmd/
│   └── api/
│       └── main.go         # Punto de entrada. Solo inicializa DB, config y arranca el servidor.
├── internal/
│   ├── config/             # Manejo de variables de entorno (puerto, nombre de DB, etc.)
│   ├── database/           # Conexión a SQLite y migraciones iniciales.
│   ├── models/             # Estructuras/Entidades ( structs ) de la aplicación.
│   ├── repository/         # Lógica de acceso a la base de datos (consultas SQL).
│   └── handlers/           # Controladores para los endpoints HTTP (reciben request, llaman a repository, envían response).
├── go.mod
└── go.sum
```

### Flujo de datos (*Clean Code*)
`Petición HTTP` -> `Handler` (Valida datos) -> `Repository` (Consulta SQLite) -> `Handler` (Formatea y devuelve JSON).

## Próximos pasos
1. Crear el archivo `go.mod` inicial.
2. Crear la estructura de carpetas propuesta.
3. Escribir un `main.go` base y un controlador simple (`GET /ping`) para asegurar que el servidor levanta correctamente.
4. Escribir el gestor de la conexión de la base de datos.
