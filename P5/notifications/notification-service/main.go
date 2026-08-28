package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

type NotificationReq struct {
	Event   string `json:"event"`
	OrderID int    `json:"order_id"`
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	natsURL := os.Getenv("NATS_URL")
	if natsURL == "" {
		natsURL = "nats://sa-platform-nats:4222"
	}

	// Iniciar servidor HTTP para probes
	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"status": "Notification Service is running"}`))
	})
	
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"status": "OK"}`))
	})
	
	go func() {
		fmt.Printf("Notification Service running on port %s\n", port)
		if err := http.ListenAndServe(":"+port, nil); err != nil {
			log.Fatalf("Error starting server: %s\n", err)
		}
	}()

	// Conectar a NATS
	var nc *nats.Conn
	var err error
	for i := 0; i < 10; i++ {
		nc, err = nats.Connect(natsURL)
		if err == nil {
			break
		}
		fmt.Println("Esperando a NATS...")
		time.Sleep(2 * time.Second)
	}
	if err != nil {
		log.Fatalf("No se pudo conectar a NATS: %v", err)
	}
	defer nc.Close()

	js, err := jetstream.New(nc)
	if err != nil {
		log.Fatalf("Error al inicializar JetStream: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// Crear el Stream si no existe (para asegurar durabilidad)
	_, err = js.CreateStream(ctx, jetstream.StreamConfig{
		Name:     "ORDERS",
		Subjects: []string{"orders.*"},
	})
	if err != nil && err != jetstream.ErrStreamNameAlreadyInUse {
		fmt.Printf("Aviso al crear el stream: %v\n", err)
	}

	// Consumidor durable
	cons, err := js.CreateOrUpdateConsumer(ctx, "ORDERS", jetstream.ConsumerConfig{
		Durable:       "NotificationsConsumer",
		FilterSubject: "orders.created",
		AckPolicy:     jetstream.AckExplicitPolicy,
	})
	if err != nil {
		log.Fatalf("Error al crear consumidor: %v", err)
	}

	fmt.Println("Esperando mensajes de NATS (JetStream)...")

	// Consumir mensajes
	for {
		msgs, err := cons.Fetch(1, jetstream.FetchMaxWait(5*time.Second))
		if err != nil {
			// Timeout esperando mensajes, continuamos el loop
			continue
		}

		for msg := range msgs.Messages() {
			var req NotificationReq
			if err := json.Unmarshal(msg.Data(), &req); err != nil {
				fmt.Printf("Error decodificando mensaje: %v\n", err)
				msg.Ack()
				continue
			}

			// Simular procesamiento
			fmt.Printf("[NOTIFICACION ASINCRONA]: Evento '%s' procesado exitosamente para el Pedido #%d\n", req.Event, req.OrderID)

			// Confirmar el procesamiento correcto (Ack explícito)
			msg.Ack()
		}
	}
}
