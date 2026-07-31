# Práctica 1 - API REST de Solicitudes Operativas

Este proyecto implementa una API REST para gestionar solicitudes operativas de una academia ficticia. El backend está desarrollado en **Go** y aplica una arquitectura limpia separando el código en capas (Handlers, Services y Repository).

---

## Aplicación de los Principios SOLID

A continuación explico los 5 principios SOLID y se muestra cómo se aplicaron en la estructura de este proyecto, para empezar

S - Simple
O - Open/Closed
L - Liskov
I - Interface Segregation
D - Dependency Inversion

### 1. S - Single Responsibility Principle (Principio de Responsabilidad Única)
**Explicación:** Una clase o módulo debe tener una, y solo una, razón para cambiar. Esto significa que cada componente de nuestro código debe dedicarse exclusivamente a realizar una única tarea.

**Aplicación en el código:**
En el proyecto, hemos separado las responsabilidades en distintas capas. Por ejemplo, el archivo `solicitud_handler.go` se encarga **exclusivamente** de manejar las peticiones y respuestas HTTP, mientras que delega la lógica de negocio al servicio.

**Fragmento de código (`backend/internal/handlers/solicitud_handler.go`):**
```go
// Create registra una nueva solicitud
func (h *SolicitudHandler) Create(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	var s models.SolicitudOperativa
	
    // Única responsabilidad del handler: Decodificar el JSON de la petición HTTP
	if err := json.NewDecoder(r.Body).Decode(&s); err != nil {
		http.Error(w, "Error decodificando el body", http.StatusBadRequest)
		return
	}

    // Delega la validación y lógica de negocio a la capa de servicio
	if err := h.service.Create(&s); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

    // Única responsabilidad del handler: Retornar la respuesta HTTP adecuada
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(s)
}
```

Un ejemplo de como no se deberia de hacer es una anidacion exagerada de if/else o switch, ya que eso violaria el principio de responsabilidad unica, tambien se puede dar el caso de que un handler tenga logica de negocio, lo cual no deberia de hacer.

### 2. O - Open/Closed Principle (Principio de Abierto/Cerrado)
**Explicación:** El código debe estar abierto para su expansion, pero cerrado para su modificación. Esto significa que deberiamos de poder agregar nuevas funcionalidades sin tener que alterar el código que ya funciona.

**Aplicación en el código:**
El `SolicitudHandler` no depende de una estructura (struct) concreta del servicio, sino de la **interfaz** `SolicitudService`. De esta manera, si el día de mañana queremos implementar un servicio diferente (por ejemplo, un servicio que envíe notificaciones por correo al crear una solicitud), simplemente creamos un nuevo struct que cumpla con la interfaz y se lo inyectamos al handler, sin tener que modificar ninguna línea de código de `SolicitudHandler`.

**Fragmento de código (`backend/internal/handlers/solicitud_handler.go`):**
```go
type SolicitudHandler struct {
    // Depende de la abstracción (interfaz), permitiendo extender el comportamiento
    // inyectando diferentes implementaciones sin modificar esta estructura.
	service services.SolicitudService
}

func NewSolicitudHandler(service services.SolicitudService) *SolicitudHandler {
	return &SolicitudHandler{service: service}
}
```

### 3. L - Liskov Substitution Principle (Principio de Sustitución de Liskov)
**Explicación:** Las clases derivadas (o implementaciones de interfaces) deben poder sustituir a sus clases base sin alterar el correcto funcionamiento del programa. Las implementaciones deben cumplir con el contrato que promete la interfaz.

**Aplicación en el código:**
El struct `solicitudRepository` implementa todos los métodos definidos por la interfaz `repository.SolicitudRepository`. Cualquier función en la capa de servicios que requiera dicha interfaz, puede utilizar nuestro `solicitudRepository` sin que la lógica del sistema falle o actúe de manera inesperada.

**Fragmento de código (`backend/internal/repository/solicitud_repository.go`):**
```go
// Contrato base
type SolicitudRepository interface {
	GetAll() ([]models.SolicitudOperativa, error)
	Create(solicitud *models.SolicitudOperativa) error
	// ...otros métodos
}

// Implementación concreta que puede sustituir a la interfaz sin problemas
type solicitudRepository struct {
	db *sql.DB
}

// Retorna la implementación concreta pero la hace pasar por la interfaz
func NewSolicitudRepository(db *sql.DB) SolicitudRepository {
	return &solicitudRepository{db: db}
}
```

### 4. I - Interface Segregation Principle (Principio de Segregación de Interfaces)
**Explicación:** Es preferible contar con muchas interfaces específicas diseñadas para clientes concretos, en lugar de una interfaz de propósito general. Un cliente no debería verse forzado a depender de métodos que no utiliza.

**Aplicación en el código:**
Las interfaces en el proyecto, como `SolicitudService`, exponen única y exclusivamente las operaciones CRUD requeridas por el controlador para manejar las "Solicitudes Operativas". No se obliga al Handler a depender de métodos que no utilizará (por ejemplo, funciones de conexión a la base de datos o lógica de otro dominio).

**Fragmento de código (`backend/internal/services/solicitud_service.go`):**
```go
// La interfaz es pequeña, específica y contiene únicamente lo necesario 
// para manejar solicitudes.
type SolicitudService interface {
	GetAll() ([]models.SolicitudOperativa, error)
	Create(solicitud *models.SolicitudOperativa) error
	Update(id int, solicitud *models.SolicitudOperativa) error
	Delete(id int) error
	UpdateStatus(id int, estado string) error
	GetByID(id int) (*models.SolicitudOperativa, error)
}
```

### 5. D - Dependency Inversion Principle (Principio de Inversión de Dependencias)
**Explicación:** Los módulos de alto nivel (como los servicios de negocio) no deben depender de los módulos de bajo nivel (como la base de datos). Ambos deben depender de abstracciones (interfaces).

**Aplicación en el código:**
Nuestra lógica de negocio (`solicitudService`) no instancia directamente una conexión a la base de datos SQL, ni depende del módulo de bajo nivel `solicitudRepository` de forma concreta. En su lugar, depende de la interfaz `SolicitudRepository`. Esto permite que el servicio no sepa (ni le importe) si los datos vienen de PostgreSQL, de SQLite o de un archivo en memoria.

**Fragmento de código (`backend/internal/services/solicitud_service.go`):**
```go
type solicitudService struct {
    // El servicio (alto nivel) depende de una abstracción (interfaz), 
    // no de la base de datos o de un struct concreto (bajo nivel).
	repo repository.SolicitudRepository
}

func NewSolicitudService(repo repository.SolicitudRepository) SolicitudService {
	return &solicitudService{repo: repo}
}
```
