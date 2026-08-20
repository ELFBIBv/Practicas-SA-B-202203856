# Diagramas Entidad-Relación (ER)

Diseño de las bases de datos para cada uno de los microservicios que requieren persistencia. En una arquitectura de microservicios, las bases de datos están desacopladas y gestionadas de forma independiente por cada servicio.

## Base de Datos: Auth Service (PostgreSQL)

```mermaid
erDiagram
    USER {
        int id PK
        string email
        string password_hash
        string role
        datetime created_at
    }
```

## Base de Datos: Catalog Service (MongoDB)

```mermaid
erDiagram
    PRODUCT {
        string _id PK
        string name
        string description
        float price
        int stock
    }
```

## Base de Datos: Orders Service (PostgreSQL)

```mermaid
erDiagram
    ORDER {
        int id PK
        int user_id "Referencia lógica a USER.id (Auth)"
        float total
        string status
        datetime created_at
    }
    ORDER_ITEM {
        int id PK
        int order_id FK
        string product_id "Referencia lógica a PRODUCT._id (Catalog)"
        int quantity
        float unit_price
    }
    
    ORDER ||--|{ ORDER_ITEM : "contiene"
```
