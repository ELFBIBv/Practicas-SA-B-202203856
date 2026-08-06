# Plan de Implementación: Práctica 2

Este documento detalla la propuesta técnica y el plan de ejecución estructurado por ramas (branches) para resolver la Práctica 2, incorporando el uso de Docker, TypeScript, React + Vite y buenas prácticas de seguridad (bcrypt para contraseñas).

## User Review Required

> [!IMPORTANT]
> **Plan de Ejecución por Ramas**
> El plan de implementación ha sido reestructurado para que cada "día" o fase corresponda a una **rama de git** (branch) con sus respectivos commits. Una vez que apruebes este plan, iniciaremos con la creación de la estructura del proyecto en código y los commits de la primera rama.

## Proposed Changes / Propuesta Técnica

### Stack Tecnológico Confirmado
- **Frontend:** React + Vite (TypeScript).
- **Backend Principal:** Node.js con Express (TypeScript).
- **Microservicio de Autorización:** Node.js con Express (TypeScript).
- **Base de Datos:** PostgreSQL en contenedor Docker.
- **Seguridad:** 
  - **bcrypt:** Para el hashing irrecuperable de contraseñas (buena práctica de la industria).
  - **AES:** Para encriptación bidireccional de datos sensibles (nombres, correos), cumpliendo el enunciado.
  - **JWT en HTTP-only cookies:** Para el manejo de sesiones y autorización.

---

## Plan de Ejecución por Ramas (Branches)

Este plan de implementación divide el trabajo en 3 ramas principales, simulando los días de trabajo. Al finalizar cada rama, podremos hacer un merge a la rama principal.

### Rama 1: `feature/db-and-security` (Día 1)
**Objetivo:** Configurar el entorno base, la base de datos dockerizada y las utilidades de seguridad.
- **Commit 1:** `chore: setup postgresql database using docker-compose`
- **Commit 2:** `feat: setup nodejs typescript backend project`
- **Commit 3:** `feat: implement AES encryption and bcrypt hashing utilities`
- **Commit 4:** `feat: implement JWT generation and HTTP-only cookie configuration`

### Rama 2: `feature/auth-microservice` (Día 2)
**Objetivo:** Implementar el microservicio de autorización independiente y el patrón de resiliencia (Retry Loop) en el backend principal.
- **Commit 1:** `feat: setup authorization microservice project with typescript`
- **Commit 2:** `feat: implement role validation endpoints in auth microservice`
- **Commit 3:** `feat: implement retry-loop with backoff in main backend using axios-retry`
- **Commit 4:** `feat: integrate main backend protected routes with auth microservice`

### Rama 3: `feature/frontend-react-vite` (Día 3)
**Objetivo:** Desarrollar la interfaz de usuario con React y Vite, conectándola con el backend.
- **Commit 1:** `chore: setup react vite frontend project with typescript`
- **Commit 2:** `feat: create login and registration forms with modern UI`
- **Commit 3:** `feat: connect frontend with backend auth endpoints (include credentials)`
- **Commit 4:** `feat: create success confirmation page and protected route views`

---

## Herramientas a Utilizar

### 🟢 Herramientas y Librerías Permitidas
- **Docker & Docker Compose:** Para PostgreSQL.
- **Node.js, Express & TypeScript:** Base del backend principal y microservicio.
- **React + Vite:** Para el frontend.
- **Librerías de Seguridad:** `jsonwebtoken`, `bcrypt` (para contraseñas), `crypto` nativo de Node (para AES).
- **Comunicación HTTP:** `axios` y `axios-retry` para el patrón de resiliencia.
- **Manejo de Cookies:** `cookie-parser` en Express.

### 🔴 Herramientas NO Permitidas (Restricciones)
- **Local Storage / Session Storage:** Prohibido guardar el token JWT en el cliente, debe ir en cookie HTTP-only.
- **Validación de roles acoplada:** No se puede validar el rol en el backend principal; debe delegarse al microservicio.
- **Tiempos estáticos (Hardcoded):** El tiempo de expiración del JWT debe venir de variables de entorno (`.env`).
