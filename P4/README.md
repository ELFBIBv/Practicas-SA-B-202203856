# Práctica 4 - Arquitectura de Microservicios (E-commerce)

Este repositorio contiene la implementación de un sistema de comercio electrónico basado en microservicios, integrado por contenedores Docker y expuesto a través de un API Gateway (Nginx).

## Cómo Ejecutar el Proyecto

Para levantar todo el ecosistema de microservicios, asegúrate de tener Docker instalado y ejecuta el siguiente comando en la raíz de la carpeta `P4`:

```bash
docker-compose up --build
```
Esto levantará el API Gateway y todos los microservicios en sus respectivos contenedores.

## Documentación y Diagramas

Los diagramas técnicos para comprender la estructura del sistema se encuentran en la carpeta `docs/diagramas/`:
- [Diagrama de Arquitectura](./docs/diagramas/arquitectura.md)
- [Diagrama Entidad-Relación (ER)](./docs/diagramas/er.md)
- [Diagrama de Secuencia](./docs/diagramas/secuencia.md)
- [Diagrama de Despliegue](./docs/diagramas/despliegue.md)
- [Diagrama de Casos de Uso](./docs/diagramas/casos_de_uso.md)
- [Casos de Uso Detallados (Tablas)](./docs/diagramas/casos_de_uso_detallados.md)

## Principios SOLID

### 1. Single Responsibility Principle (SRP)
**Principio de Responsabilidad Única:** Establece que un módulo, clase o archivo debe tener una única responsabilidad o razón para cambiar.
**Evidencia en el código:** En el `auth-service`, las responsabilidades están separadas. El archivo principal `index.ts` maneja las rutas de Express, mientras que funciones específicas como la seguridad y los tokens están delegadas a módulos utilitarios (`utils/security.ts`, `utils/jwt.ts`).
*Archivo:* `auth/auth-service/src/index.ts`
```typescript
// Se delegan responsabilidades criptográficas y de tokens a otros archivos.
import { encryptAES, decryptAES, hashPassword, comparePassword } from './utils/security';
import { generateToken, setAuthCookie, verifyToken, clearAuthCookie } from './utils/jwt';
```

### 2. Open/Closed Principle (OCP)
**Principio de Abierto/Cerrado:** El software debe estar abierto a la extensión pero cerrado a la modificación. Podemos agregar nuevas funcionalidades sin alterar el código central.
**Evidencia en el código:** En `catalog-service` y `order-service`, la configuración de GraphQL utilizando `strawberry` permite extender la API agregando nuevas mutaciones o queries a las clases `Query` y `Mutation` sin tener que modificar el enrutador principal de FastAPI ni la configuración de inicialización.
*Archivo:* `catalog/catalog-service/main.py`
```python
@strawberry.type
class Query:
    @strawberry.field
    def products(self) -> list[Product]: ...

# El esquema se extiende al agregar más métodos a Query/Mutation, 
# sin modificar el core de FastAPI.
schema = strawberry.Schema(query=Query, mutation=Mutation)
graphql_app = GraphQLRouter(schema)
```

### 3. Liskov Substitution Principle (LSP)
**Principio de Sustitución de Liskov:** Las implementaciones intercambiables deben poder reemplazar a su comportamiento base sin alterar el programa.
**Evidencia en el código:** En el `auth-service`, la lógica de registro puede utilizar indistintamente encriptación AES o hashing con Bcrypt dependiendo de una variable de entorno. El flujo principal del programa no se rompe al sustituir una implementación criptográfica por otra, ya que ambas devuelven una cadena válida que se almacena en la base de datos.
*Archivo:* `auth/auth-service/src/index.ts`
```typescript
// La función puede utilizar cualquier implementación (AES o Bcrypt) 
// sin romper el registro de usuario de Liskov.
const useAES = process.env.USE_AES_FOR_PASSWORD === 'true';
const passwordHash = useAES ? encryptAES(password) : await hashPassword(password);
```

### 4. Interface Segregation Principle (ISP)
**Principio de Segregación de Interfaces:** Los clientes no deben verse obligados a depender de interfaces o métodos que no utilizan. Es mejor tener estructuras pequeñas y específicas.
**Evidencia en el código:** En el `notification-service` (Go), en lugar de requerir que el servicio reciba todo el objeto completo del "Pedido" (con campos de usuario, total, fecha, etc.), se define una estructura `NotificationReq` minimalista y segregada que contiene únicamente los campos estrictamente necesarios para su función.
*Archivo:* `notifications/notification-service/main.go`
```go
// Estructura pequeña y específica, en lugar de un gran objeto Order.
type NotificationReq struct {
    Event   string `json:"event"`
    OrderID int    `json:"order_id"`
}
```

### 5. Dependency Inversion Principle (DIP)
**Principio de Inversión de Dependencias:** Los módulos de alto nivel no deben depender de los módulos de bajo nivel; ambos deben depender de abstracciones (ej. variables de entorno).
**Evidencia en el código:** A lo largo de todos los microservicios (por ejemplo, `catalog-service`), las conexiones a las bases de datos no están "quemadas" (hardcoded) en la lógica de alto nivel. En su lugar, se inyectan como variables de entorno, lo que permite cambiar el origen de los datos sin modificar el código fuente.
*Archivo:* `catalog/catalog-service/main.py`
```python
# La dependencia de conexión se inyecta desde el entorno, abstrayendo el código 
# de la conexión específica o de la infraestructura subyacente.
MONGO_URI = os.getenv("MONGO_URI", "mongodb://localhost:27017/catalog_db")
client = MongoClient(MONGO_URI)
```
