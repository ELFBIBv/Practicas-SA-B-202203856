# Plan de Implementación y Estudio: Práctica 2

Este documento detalla la propuesta técnica, el plan de estudio y las herramientas a utilizar para resolver la Práctica 2, incorporando el uso de Docker para la base de datos.

## User Review Required

> [!IMPORTANT]
> **Encriptación de Contraseñas vs Hashing**
> El enunciado indica textualmente que "nombres, correos, contraseñas, etc." deben almacenarse **encriptadas con AES**. En la industria, las contraseñas se almacenan mediante funciones de hash (como *bcrypt* o *argon2*), no encriptadas de forma reversible con AES. Sin embargo, para cumplir con la rúbrica estrictamente, utilizaremos AES para todo. Por favor, confirma si prefieres apegarte estrictamente al enunciado (AES para todo) o utilizar buenas prácticas para contraseñas (Hash) y AES para el resto de datos sensibles.

> [!TIP]
> **Stack Tecnológico Propuesto**
> - **Frontend:** React (usando Vite) o Vanilla JS/HTML/CSS según tus preferencias (con un diseño moderno y estético).
> - **Backend Principal:** Node.js con Express (TypeScript recomendado).
> - **Microservicio de Autorización:** Node.js con Express (TypeScript).
> - **Base de Datos:** PostgreSQL en contenedor Docker.

## Open Questions

1. **Lenguaje preferido:** La propuesta se basa en JavaScript/TypeScript (Node.js). ¿Estás de acuerdo o prefieres usar Python (FastAPI/Flask)?
2. **Frontend:** ¿Prefieres utilizar un framework moderno como React (Vite) o prefieres hacerlo con Vanilla JS y HTML/CSS puro?

---

## 1. Plan de Estudio Sugerido

Para abordar la práctica de manera ordenada, te sugiero el siguiente plan de estudio:

1. **Día 1: Fundamentos de Seguridad**
   - Repasar conceptos de **JWT (JSON Web Tokens)**: estructura, firma y ciclo de vida.
   - Comprender cómo funcionan las **Cookies HTTP-only** y por qué evitan ataques XSS.
   - Estudiar el **Algoritmo de encriptación AES**: cifrado simétrico, llaves y vectores de inicialización (IV).

2. **Día 2: Microservicios y Patrones de Resiliencia**
   - Entender la arquitectura de microservicios: desacoplamiento de autenticación y autorización.
   - Estudiar el patrón de **Polling/Retry loop con Backoff exponencial**: cómo implementarlo al hacer peticiones HTTP (por ejemplo, usando `axios-retry`).

3. **Día 3: Entorno y Contenedores**
   - Aprender a levantar una base de datos **PostgreSQL utilizando Docker y Docker Compose**.
   - Conectar Node.js/Python a la base de datos dockerizada.

---

## 2. Propuesta de Solución e Implementación

La solución se dividirá en tres componentes principales:

### 2.1 Base de Datos (Docker)
Levantaremos un contenedor de **PostgreSQL** usando un archivo `docker-compose.yml`. Tendremos una tabla de usuarios que almacenará: `id`, `nombre` (AES), `correo` (AES), `password` (AES) y `rol` (Admin/Cliente).

### 2.2 Microservicio de Autorización (Puerto 4000)
Un servicio independiente (Node.js) que:
- Reciba peticiones POST con el token JWT (o los datos decodificados) y la ruta a la que se intenta acceder.
- Valide el rol (Admin/Cliente).
- Retorne `200 OK` (Permitido) o `403 Forbidden` (Denegado).

### 2.3 Backend Principal (Puerto 3000)
- **Registro:** Recibe datos, los encripta con AES y guarda en BD.
- **Login:** Compara credenciales (desencriptando o encriptando la entrada). Si es exitoso, genera JWT. Configura el JWT en una cookie `HTTP-only`.
- **Renovación:** Middleware que verifica si el JWT está próximo a expirar (dentro del tiempo de gracia en variables de entorno) y, de ser así, inyecta una nueva cookie HTTP-only con el token renovado.
- **Rutas Protegidas:**
  - `Ruta 1`: Accesible solo para Admin.
  - `Ruta 2`: Accesible para Admin y Cliente.
  - El backend intercepta estas peticiones, extrae el JWT de la cookie y hace una petición interna al **Microservicio de Autorización** implementando un ciclo de reintentos con backoff (si el microservicio falla o tarda en responder).

### 2.4 Frontend
- Interfaz moderna para Registro y Login.
- Página de confirmación tras login exitoso.
- Peticiones al backend configuradas con `credentials: 'include'` para que el navegador envíe automáticamente la cookie HTTP-only en cada request.

---

## 3. Herramientas Permitidas y No Permitidas

### 🟢 Herramientas Permitidas / Recomendadas
- **Docker & Docker Compose:** Para la base de datos (PostgreSQL o MySQL).
- **Node.js + Express / Python + FastAPI:** Para crear los servidores REST y el microservicio de autorización.
- **Librerías JWT:** `jsonwebtoken` (Node.js) o `PyJWT` (Python).
- **Librerías de Encriptación:** El módulo nativo `crypto` de Node.js o `cryptography` en Python para AES.
- **Cookies-parser:** Para leer cookies HTTP-only en el backend.
- **Axios + axios-retry:** Para manejar la comunicación con el microservicio de autorización y aplicar el retry-loop con backoff fácilmente.
- **Frontend libre:** React, Vue, HTML/CSS/JS Vainilla.

### 🔴 Herramientas NO Permitidas (Restricciones del Enunciado)
- **Almacenamiento Local de JWT:** Queda estrictamente prohibido usar `localStorage`, `sessionStorage` o dejar el token visible en el Frontend. **Debe ser HTTP-only.**
- **Módulo de Autorización acoplado:** No puedes validar los roles directamente en el mismo código del backend principal. Debe hacerse mediante una petición a un servicio independiente.
- **Falta de Reintentos:** No puedes hacer una sola petición al servicio de autorización. Si este falla, tu código debe reintentar.
- **Datos en Texto Plano:** Guardar correos, nombres o contraseñas sin aplicar AES está prohibido y penalizado en la rúbrica.
- **Tiempos estáticos (Hardcoded):** El tiempo de expiración y el tiempo de gracia del JWT **NO** pueden estar quemados en el código. Deben venir de variables de entorno (`.env`).
