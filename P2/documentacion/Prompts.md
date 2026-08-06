segun el enunciado [Practica_2_2S2026.md] generame un plan de estudio, proponme una propuesta de como lo solucionarias y lo implementarias, tambien detallame las herramientas que es posible utilizar y cuales no, por cierto vamos a utilizar docker para la base de detos

Respuesta: [1er_prompt.mc]

aclaraciones:

``` aclaraciones:
 El texto menciona que se recomienda AES pero supondré que es error textual asi que utilicemos bcrypt (solo para informacion sensible que no debe de poder recuperarse) 
 Vamos a utiliar Typescript
 Para el Frontend vamos a utilizar React Vite para framework

 El plan de estudio me parece perfecto pero será un plan de implementacion, donde cada uno de los dias que mencionas será una rama con sus respectivos commits

 ahora generame otro plan de implementacion con las correcciones
```

luego de realizar esas aclaraciones le pedí que reformulará el plan de implementacion.

Respuesta: [2do_prompt.mc]

aclaraciones:

``` aclaraciones:
Como es que funcionaria el microservicio? detallame el tipo de implementacion que podemos hacer, el por que de ese metodo y explicame como funcionaria ya que soy nuevo en ese concepto.
```

Respuesta: [3er_prompt.mc]

aclaraciones:

``` aclaraciones:
Como es que funcionaria el microservicio? detallame el tipo de implementacion que podemos hacer, el por que de ese metodo y explicame como funcionaria ya que soy nuevo en ese concepto.
```

luego de eso quise intentar darle rienda suelta a la IA para que hiciera todos los cambios incluyendo los de subir ramas, commits, hacer merges, etc. 

- Deficiencia 1: vi que las tablas las creaba cuando se encendia el backend lo cual era una muy mala practica, lo mejor es tener un archivo .sql con las tablas para poder ejecutarlo cuando se desee.

- Deficiencia 2: tambien vi que hacia los merge sin el --no-ff y eso creaba un historial de commits que no era el mejor, lo mejor es hacer merge con --no-ff para mantener un historial visual.

- Deficiencia 3: Subio la carpeta de node_modules del backend (esta como no es un framework no contenia un .gitignore con esa instruccion especifica como en vite al inciairlo, aun asi se puede corregir).

- Deficiencia 4: El backend no lo intento ejecutar asi que cuando intenté ejecutarlo tuve varios errores de dependencias, errores de una libreria que necesitaba ejecutar scripts (pnpm las bloquea por defecto, asi que se le debia de permitir).

