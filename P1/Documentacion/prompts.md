# Prompt 1:
```
Haremos una arquitectura de tipo Cliente-Servidor, en la que el servidor será un Backend que tendrá endpoints un tanto sencillos y manejará una base de datos simple (SQLite), el cliente en este caso seran solamente peticiones realizadas por archivos http para dejar documentadas las peticiones.

- El servidor estará hecho en Go.
- Las peticiones HTTP serán con el formato de la libreria REST Client de humao.
- La base de datos será en SQLite ya que no manejaremos mucha informacion.
- Todo será de manera local manejando Docker y Docker compose donde las peticiones se harán desde mi maquina principal.

de momento no quiero que hagas nada pero hazme saber si tienes alguna duda
```

Ahora que ya tiene cargadas las instrucciones de lo que vamos a hacer y me confirmo que todo está claro, pasemos a la implementacion.

# Prompt 2:
```
Entendido, ahora que todo está claro entonces procedamos, procura utilizar cleancode y buenas practicas, se realizara documentacion de todo, primero centremonos en la estructura del backend (librerias, carpetas, main,conexion con la db, etc), en la siguiente instruccion te indicare que quiero
```

# Prompt 3:
```
Para empezar ahora que ya tenemos toda la estructura de lo que viene siendo la comunicacion con una base da datos simple la cual no tendrá mucha complejidad (gestionará solicitudes operativas), entonces
ahora que ya todo funciona lo que necesitamos es lo siguiente:
cada solicitud tendrá lo siguiente
- id (entero o UUID)
- titulo (string)
- area_solicitante (string)
- prioridad (Entero 1-5)
- costo_estimado (decimal)
- estado (string) [registrada,en_proceso,finalizada]

un ejemplo de entrada JSON
{
  "titulo": "Adquisicion de nuevo servidor",
  "area_solicitante": "Infraestructura TI",
  "prioridad": 1,
  "costo_estimado": 2500.00,
  "estado": "registrada"
}

El sistema deberá soportar las siguientes operaciones mínimas sobre las solicitudes
operativas:
● Obtener la información de todas las solicitudes operativas.
● Registrar una nueva solicitud operativa.
● Actualizar completamente la información de una solicitud existente.
● Eliminar una solicitud operativa.
● Actualizar exclusivamente el estado de una solicitud operativa, sin modificar el
resto de sus atributos.
Cada endpoint debe cumplir con los principios SOLID y con las buenas prácticas de diseño
REST.

```


