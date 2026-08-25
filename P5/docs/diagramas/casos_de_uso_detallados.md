# Detalle de Casos de Uso por Microservicio

A continuación se presenta la redacción detallada de los casos de uso para CADA UNA de las funcionalidades de los microservicios del sistema, coincidiendo exactamente con los diagramas (1 a 1).

## 1. Módulo: Auth Service

### RF-01: Gestión de Identidad y Acceso

| Campo | Detalle |
|---|---|
| **ID** | RF-01 |
| **Descripción** | El sistema debe permitir a los usuarios registrarse, iniciar sesión y validar sus credenciales mediante tokens (JWT) para acceder de forma segura a los demás microservicios. |
| **Prioridad** | Alta |
| **Stakeholders** | Usuarios Finales, Administradores |

**Criterios de Aceptación**
- CA-1: Las contraseñas deben ser almacenadas de forma encriptada (hash).
- CA-2: Los tokens generados (JWT) deben tener un tiempo de expiración definido.

---

#### CU-AUTH-001: Registro de Cuenta

| Campo | Detalle |
|---|---|
| **ID** | CU-AUTH-001 |
| **Actor Principal** | Usuario / Cliente |
| **Actores Secundarios** | Notifications Service |

**Precondiciones**
1. El usuario proporciona datos válidos y completos (correo, contraseña, nombre).

**Postcondiciones**
1. Se crea la cuenta del usuario en Auth.
2. Se emite evento de notificación.

**Flujo Principal**

| Paso | Descripción |
|---|---|
| 1 | El usuario ingresa sus datos (correo, nombre, contraseña). |
| 2 | El sistema verifica que el formato del correo sea válido y no exista previamente. |
| 3 | El sistema encripta la contraseña usando bcrypt. |
| 4 | El sistema guarda el nuevo usuario. |
| 5 | El sistema envía mensaje al Notifications Service para despacho de correo. |
| 6 | El sistema devuelve una respuesta de éxito al usuario. |

**Flujos Alternativos**
| ID | Condición | Acción |
|---|---|---|
| FA-AUTH-001-1 | Correo existente | Retorna error HTTP 409 indicando que la cuenta ya existe. |

---

#### CU-AUTH-002: Inicio de Sesión

| Campo | Detalle |
|---|---|
| **ID** | CU-AUTH-002 |
| **Actor Principal** | Usuario / Cliente |

**Precondiciones**
1. El usuario tiene una cuenta registrada válida.

**Postcondiciones**
1. Se genera un token de acceso (JWT).

**Flujo Principal**

| Paso | Descripción |
|---|---|
| 1 | El usuario ingresa correo y contraseña. |
| 2 | El sistema busca al usuario por correo. |
| 3 | El sistema verifica que la contraseña coincida con el hash. |
| 4 | El sistema genera el Token (JWT). |
| 5 | El sistema retorna el Token al usuario. |

**Flujos Alternativos**
| ID | Condición | Acción |
|---|---|---|
| FA-AUTH-002-1 | Credenciales incorrectas | Retorna error 401 (No autorizado). |

---

#### CU-AUTH-003: Validación de Cuenta (Token)

| Campo | Detalle |
|---|---|
| **ID** | CU-AUTH-003 |
| **Actor Principal** | Sistema (API Gateway/Microservicio) |

**Precondiciones**
1. Petición HTTP incluye un Token en la cabecera.

**Postcondiciones**
1. Se autoriza la solicitud.

**Flujo Principal**

| Paso | Descripción |
|---|---|
| 1 | El sistema extrae el Token de la petición. |
| 2 | El Auth Service verifica la firma secreta del Token. |
| 3 | Se valida que el Token no esté expirado. |
| 4 | Se permite continuar el flujo. |

**Flujos Alternativos**
| ID | Condición | Acción |
|---|---|---|
| FA-AUTH-003-1 | Token inválido/expirado | Retorna error 401 y deniega el acceso. |

---

## 2. Módulo: Orders Service

### RF-02: Procesamiento y Registro de Pedidos

| Campo | Detalle |
|---|---|
| **ID** | RF-02 |
| **Descripción** | Permite registrar y confirmar pedidos, validando identidad y stock. |
| **Prioridad** | Alta |
| **Stakeholders** | Usuarios, Logística |

---

#### CU-ORD-001: Registro de Transacción (Crear Pedido)

| Campo | Detalle |
|---|---|
| **ID** | CU-ORD-001 |
| **Actor Principal** | Usuario / Cliente |
| **Actores Secundarios** | Auth Service, Catalog Service, Notifications Service |

**Precondiciones**
1. Usuario autenticado y lista de productos provista.

**Postcondiciones**
1. Transacción registrada y notificación enviada.

**Flujo Principal**

| Paso | Descripción |
|---|---|
| 1 | Sistema recibe solicitud con Token e items. |
| 2 | Verifica autenticación con Auth Service. |
| 3 | Ejecuta CU-ORD-003 (Validar Productos) consultando Catalog. |
| 4 | Calcula total. |
| 5 | Registra el nuevo pedido en BD Orders. |
| 6 | Emite evento a Notifications Service. |
| 7 | Retorna número de confirmación. |

**Flujos Alternativos**
| ID | Condición | Acción |
|---|---|---|
| FA-ORD-001-1 | Stock Insuficiente | Aborta y notifica qué producto falta. |

---

#### CU-ORD-002: Visualizar Historial de Pedidos

| Campo | Detalle |
|---|---|
| **ID** | CU-ORD-002 |
| **Actor Principal** | Usuario / Cliente |

**Precondiciones**
1. Usuario autenticado (Token válido).

**Postcondiciones**
1. Retorna lista de pedidos anteriores.

**Flujo Principal**

| Paso | Descripción |
|---|---|
| 1 | Usuario solicita historial de sus órdenes. |
| 2 | Orders Service filtra la base de datos por el ID del usuario extraído del token. |
| 3 | Se ordenan por fecha de forma descendente. |
| 4 | Se devuelve el arreglo con el historial. |

---

#### CU-ORD-003: Validar Productos Disponibles

| Campo | Detalle |
|---|---|
| **ID** | CU-ORD-003 |
| **Actor Principal** | Sistema (Orders Service) |
| **Actores Secundarios** | Catalog Service |

**Precondiciones**
1. Se requiere procesar un carrito de compras.

**Postcondiciones**
1. Se confirma disponibilidad total.

**Flujo Principal**

| Paso | Descripción |
|---|---|
| 1 | Orders envía la lista de IDs de productos requeridos a Catalog. |
| 2 | Catalog verifica su base de datos. |
| 3 | Catalog responde indicando suficiencia o falta de stock. |
| 4 | Orders decide si puede continuar con la transacción. |

---

## 3. Módulo: Catalog Service

### RF-03: Gestión del Catálogo de Productos

| Campo | Detalle |
|---|---|
| **ID** | RF-03 |
| **Descripción** | Permite visualizar, buscar y consultar inventarios. |
| **Prioridad** | Media |

---

#### CU-CAT-001: Listar Productos

| Campo | Detalle |
|---|---|
| **ID** | CU-CAT-001 |
| **Actor Principal** | Usuario / Cliente |

**Precondiciones**
1. Ninguna.

**Flujo Principal**

| Paso | Descripción |
|---|---|
| 1 | Usuario solicita catálogo. |
| 2 | Sistema obtiene productos activos. |
| 3 | Sistema aplica paginación. |
| 4 | Retorna JSON con catálogo. |

---

#### CU-CAT-002: Buscar Productos

| Campo | Detalle |
|---|---|
| **ID** | CU-CAT-002 |
| **Actor Principal** | Usuario / Cliente |

**Precondiciones**
1. Ingreso de un término de búsqueda.

**Flujo Principal**

| Paso | Descripción |
|---|---|
| 1 | Usuario envía texto de búsqueda. |
| 2 | Sistema busca coincidencias en nombre/descripción. |
| 3 | Retorna lista filtrada. |

---

#### CU-CAT-003: Consultar Detalles de Producto

| Campo | Detalle |
|---|---|
| **ID** | CU-CAT-003 |
| **Actor Principal** | Usuario / Cliente |

**Precondiciones**
1. Conocer el ID del producto.

**Flujo Principal**

| Paso | Descripción |
|---|---|
| 1 | Usuario solicita detalle del producto `X`. |
| 2 | Sistema busca el producto por ID. |
| 3 | Retorna descripción completa, imágenes y precios. |

---

#### CU-CAT-004: Verificar Stock de Producto

| Campo | Detalle |
|---|---|
| **ID** | CU-CAT-004 |
| **Actor Principal** | Orders Service |

**Precondiciones**
1. Solicitud interna de Orders.

**Flujo Principal**

| Paso | Descripción |
|---|---|
| 1 | Orders envía IDs y cantidades deseadas. |
| 2 | Catalog comprueba la columna `stock` actual. |
| 3 | Devuelve booleano / reporte de los faltantes. |

---

## 4. Módulo: Notifications Service

### RF-04: Gestión de Alertas

| Campo | Detalle |
|---|---|
| **ID** | RF-04 |
| **Descripción** | Reacción asíncrona a eventos. |
| **Prioridad** | Media |

---

#### CU-NOT-001: Enviar Notificación de Registro

| Campo | Detalle |
|---|---|
| **ID** | CU-NOT-001 |
| **Actor Principal** | Auth Service |

**Precondiciones**
1. Un usuario fue creado exitosamente.

**Flujo Principal**

| Paso | Descripción |
|---|---|
| 1 | Recibe evento "Usuario Registrado" con el correo. |
| 2 | Carga plantilla "Bienvenida". |
| 3 | Conecta al SMTP y despacha correo. |
| 4 | Registra log como enviado. |

---

#### CU-NOT-002: Enviar Notificación de Pedido Creado

| Campo | Detalle |
|---|---|
| **ID** | CU-NOT-002 |
| **Actor Principal** | Orders Service |

**Precondiciones**
1. Un pedido fue creado exitosamente.

**Flujo Principal**

| Paso | Descripción |
|---|---|
| 1 | Recibe evento "Pedido Creado" con detalles y total. |
| 2 | Carga plantilla de "Factura/Comprobante". |
| 3 | Conecta al SMTP y despacha correo. |
| 4 | Registra log como enviado. |

---

#### CU-NOT-003: Revisar Estado de Notificaciones

| Campo | Detalle |
|---|---|
| **ID** | CU-NOT-003 |
| **Actor Principal** | Administrador del Sistema |

**Precondiciones**
1. Admin autenticado.

**Flujo Principal**

| Paso | Descripción |
|---|---|
| 1 | Admin entra al dashboard de logs de correo. |
| 2 | Sistema consulta tabla de logs de Notifications. |
| 3 | Retorna lista de envíos exitosos/fallidos para posible reintento. |
