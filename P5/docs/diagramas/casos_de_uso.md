# Diagramas de Casos de Uso

A continuación se presenta el diagrama de casos de uso de **alto nivel** que ilustra el panorama general del sistema, seguido de las **descomposiciones** específicas para cada uno de los microservicios.

## Diagrama de Alto Nivel (Contexto General)

Este diagrama muestra cómo el usuario interactúa con los grandes módulos del sistema, tratando a cada microservicio como un caso de uso global.

```mermaid
flowchart LR
    User([Usuario / Cliente])
    
    subgraph Sistema Principal
        direction TB
        UC1((Gestión de \nAutenticación))
        UC2((Gestión de \nCatálogo))
        UC3((Gestión de \nPedidos))
        UC4((Recepción de \nNotificaciones))
    end
    
    User --> UC1
    User --> UC2
    User --> UC3
    User --> UC4
    
    UC1 -. "Genera alertas" .-> UC4
    UC3 -. "Genera comprobantes" .-> UC4
```

---

## Descomposición por Microservicio
## 1. Auth Service

El microservicio de autenticación se encarga de la gestión y validación de las cuentas de los usuarios.

```mermaid
flowchart LR
    User([Usuario / Cliente])
    Notif([Notifications Service])

    subgraph AuthService [Auth Service]
        direction TB
        UC1((Registro de \nCuenta))
        UC2((Inicio de \nSesión))
        UC3((Validación de \nCuenta - Token))
    end

    User --> UC1
    User --> UC2
    User --> UC3

    UC1 -. "Notifica registro exitoso" .-> Notif
```

## 2. Orders Service

El microservicio de pedidos (órdenes) maneja el registro de transacciones y el historial de compras.

```mermaid
flowchart LR
    User([Usuario / Cliente])
    Auth([Auth Service])
    Catalog([Catalog Service])
    Notif([Notifications Service])

    subgraph OrdersService [Orders Service]
        direction TB
        UC1((Registro de Transacción\nCrear Pedido))
        UC2((Visualizar Historial\nde Pedidos))
        UC3((Validar Productos\nDisponibles))
    end

    User --> UC1
    User --> UC2

    UC1 -. "<<include>>" .-> UC3
    UC1 -->|"Verifica Autenticación"| Auth
    UC3 -->|"Consulta stock y precios"| Catalog
    UC1 -. "Notifica pedido creado" .-> Notif
```

## 3. Catalog Service

El microservicio de catálogo maneja la visualización y búsqueda de productos.

```mermaid
flowchart LR
    User([Usuario / Cliente])
    Orders([Orders Service])

    subgraph CatalogService [Catalog Service]
        direction TB
        UC1((Listar \nProductos))
        UC2((Buscar \nProductos))
        UC3((Consultar Detalles \nde Producto))
        UC4((Verificar Stock \nde Producto))
    end

    User --> UC1
    User --> UC2
    User --> UC3
    Orders --> UC4
```

## 4. Notifications Service

El microservicio de notificaciones actúa de forma reactiva al recibir eventos de otros servicios.

```mermaid
flowchart LR
    Auth([Auth Service])
    Orders([Orders Service])
    Admin([Administrador del Sistema])

    subgraph NotificationsService [Notifications Service]
        direction TB
        UC1((Enviar Notificación \nde Registro))
        UC2((Enviar Notificación \nde Pedido Creado))
        UC3((Revisar Estado \nde Notificaciones))
    end

    Auth --> UC1
    Orders --> UC2
    Admin --> UC3
```
