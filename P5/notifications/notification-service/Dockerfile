FROM golang:1.21-alpine AS builder
WORKDIR /app
ENV CGO_ENABLED=0
COPY . .
RUN go mod init notification-service || true
RUN go build -o main .

FROM alpine:latest
WORKDIR /app
COPY --from=builder /app/main .
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser
EXPOSE 8080
CMD ["./main"]
