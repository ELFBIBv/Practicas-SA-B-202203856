FROM golang:1.22-alpine AS builder

WORKDIR /app

# Instalar dependencias
COPY go.mod ./
# Si se tuviera un go.sum, se copiaría también
# COPY go.sum ./
RUN go mod download

# Copiar el código fuente
COPY . .

# Descargar dependencias y generar go.sum a partir del código fuente
RUN go mod tidy

# Compilar la aplicación
RUN go build -o main ./cmd/api/main.go

# Etapa final
FROM alpine:latest

WORKDIR /root/

# Copiar el ejecutable desde la etapa de compilación
COPY --from=builder /app/main .

EXPOSE 8080

CMD ["./main"]
