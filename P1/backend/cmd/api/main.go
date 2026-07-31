package main

import (
	"backend/internal/config"
	"backend/internal/database"
	"backend/internal/handlers"
	"backend/internal/repository"
	"backend/internal/services"
	"log"
	"net/http"
	"fmt"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
)

func main() {
	// Cargar configuración
	cfg := config.LoadConfig()

	// Inicializar base de datos
	db := database.InitDB(cfg.DBName)
	defer db.Close()

	// Inicializar capas
	solicitudRepo := repository.NewSolicitudRepository(db)
	solicitudService := services.NewSolicitudService(solicitudRepo)
	solicitudHandler := handlers.NewSolicitudHandler(solicitudService)

	// Inicializar router
	r := chi.NewRouter()

	// Middlewares básicos
	r.Use(middleware.Logger)
	r.Use(middleware.Recoverer)

	// Definir rutas
	r.Get("/ping", handlers.HealthCheck)
	
	r.Route("/solicitudes", func(r chi.Router) {
		r.Get("/", solicitudHandler.GetAll)
		r.Post("/", solicitudHandler.Create)
		r.Put("/{id}", solicitudHandler.Update)
		r.Delete("/{id}", solicitudHandler.Delete)
		r.Patch("/{id}/estado", solicitudHandler.UpdateStatus)
	})

	// Iniciar servidor
	serverAddr := fmt.Sprintf(":%s", cfg.Port)
	log.Printf("Iniciando servidor en el puerto %s...", cfg.Port)
	if err := http.ListenAndServe(serverAddr, r); err != nil {
		log.Fatalf("Error iniciando el servidor: %v", err)
	}
}
