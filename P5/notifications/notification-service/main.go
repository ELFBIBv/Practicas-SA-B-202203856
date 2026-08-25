package main

import (
    "encoding/json"
    "fmt"
    "net/http"
    "os"
)

type NotificationReq struct {
    Event   string `json:"event"`
    OrderID int    `json:"order_id"`
}

func notificationsHandler(w http.ResponseWriter, r *http.Request) {
    if r.Method != http.MethodPost {
        http.Error(w, "Método no permitido", http.StatusMethodNotAllowed)
        return
    }

    var req NotificationReq
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        http.Error(w, err.Error(), http.StatusBadRequest)
        return
    }

    // Mockeamos el envío de la notificación imprimiendo en la consola del contenedor
    fmt.Printf("[NOTIFICACION]: Evento recibido '%s' para el Pedido #%d\n", req.Event, req.OrderID)
    
    w.Header().Set("Content-Type", "application/json")
    w.WriteHeader(http.StatusOK)
    json.NewEncoder(w).Encode(map[string]string{"status": "Notification Sent"})
}

func main() {
    port := os.Getenv("PORT")
    if port == "" {
        port = "8080"
    }

    http.HandleFunc("/api/notifications", notificationsHandler)
    http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
        w.WriteHeader(http.StatusOK)
        w.Write([]byte(`{"status": "Notification Service is running"}`))
    })

    fmt.Printf("Notification Service running on port %s\n", port)
    if err := http.ListenAndServe(":"+port, nil); err != nil {
        fmt.Printf("Error starting server: %s\n", err)
    }
}
