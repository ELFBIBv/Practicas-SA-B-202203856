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
    
    %% Valida productos
    OrderService->>CatalogService: HTTP POST /api/catalog (Query stock y precios)
    CatalogService-->>OrderService: Retorna datos del producto
    
    %% Guarda en BD
    OrderService->>DB_Orders: Inserta Order y OrderItems (Transacción)
    DB_Orders-->>OrderService: Confirmado
    
    %% Notifica
    OrderService->>NotificationService: POST /api/notifications (Evento Pedido Creado)
    NotificationService-->>OrderService: 200 OK (Notificación enviada)
    
    OrderService-->>API Gateway: Pedido Confirmado (201 Created)
    API Gateway-->>Client: Responde con ID del pedido
```
