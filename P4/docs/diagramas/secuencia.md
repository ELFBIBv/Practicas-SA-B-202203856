# Diagrama de Secuencia (Creación de Pedido)

Este diagrama ejemplifica el flujo de información cuando un usuario realiza una compra, interactuando con los distintos microservicios a través del Gateway.

```mermaid
sequenceDiagram
    actor Client
    participant API Gateway
    participant OrderService
    participant CatalogService
    participant NotificationService
    participant DB_Orders
    
    Client->>API Gateway: POST /api/orders (Crear Pedido GraphQL)
    API Gateway->>OrderService: Enruta petición
    
    %% Valida productos y obtiene precio oficial
    OrderService->>CatalogService: HTTP POST /graphql (Query producto y stock)
    CatalogService-->>OrderService: Retorna datos y precio oficial

    %% Descuenta stock
    OrderService->>CatalogService: HTTP POST /graphql (Mutation descontar stock)
    CatalogService-->>OrderService: OK (Stock actualizado)
    
    %% Guarda en BD
    OrderService->>DB_Orders: Inserta Order y OrderItems (Transacción)
    DB_Orders-->>OrderService: Confirmado
    
    %% Notifica
    OrderService->>NotificationService: POST /api/notifications (Evento Pedido Creado)
    NotificationService-->>OrderService: 200 OK (Notificación enviada)
    
    OrderService-->>API Gateway: Pedido Confirmado (201 Created)
    API Gateway-->>Client: Responde con ID del pedido
```
