FROM golang:1.21-alpine
WORKDIR /app

# Desactivamos CGO para obtener un binario estático que corra perfecto en alpine
ENV CGO_ENABLED=0

COPY . .

# Inicializamos el módulo de Go localmente en caso de que no exista
RUN go mod init notification-service || true

# Compilamos la aplicación
RUN go build -o main .

EXPOSE 8080

CMD ["./main"]
