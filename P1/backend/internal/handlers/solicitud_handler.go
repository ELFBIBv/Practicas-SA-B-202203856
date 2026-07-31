package handlers

import (
	"encoding/json"
	"net/http"
	"strconv"

	"backend/internal/models"
	"backend/internal/services"
	"github.com/go-chi/chi/v5"
)

type SolicitudHandler struct {
	service services.SolicitudService
}

func NewSolicitudHandler(service services.SolicitudService) *SolicitudHandler {
	return &SolicitudHandler{service: service}
}

// GetAll obtiene todas las solicitudes
func (h *SolicitudHandler) GetAll(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	solicitudes, err := h.service.GetAll()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	if solicitudes == nil {
		solicitudes = []models.SolicitudOperativa{}
	}

	json.NewEncoder(w).Encode(solicitudes)
}

// Create registra una nueva solicitud
func (h *SolicitudHandler) Create(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	var s models.SolicitudOperativa
	if err := json.NewDecoder(r.Body).Decode(&s); err != nil {
		http.Error(w, "Error decodificando el body", http.StatusBadRequest)
		return
	}

	if err := h.service.Create(&s); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(s)
}

// Update actualiza completamente una solicitud existente
func (h *SolicitudHandler) Update(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	idStr := chi.URLParam(r, "id")
	id, err := strconv.Atoi(idStr)
	if err != nil {
		http.Error(w, "ID inválido", http.StatusBadRequest)
		return
	}

	var s models.SolicitudOperativa
	if err := json.NewDecoder(r.Body).Decode(&s); err != nil {
		http.Error(w, "Error decodificando el body", http.StatusBadRequest)
		return
	}

	if err := h.service.Update(id, &s); err != nil {
		if err.Error() == "solicitud no encontrada" {
			http.Error(w, err.Error(), http.StatusNotFound)
			return
		}
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	// Recuperar el actualizado para retornarlo (opcional, pero buena práctica)
	s.ID = id
	json.NewEncoder(w).Encode(s)
}

// Delete elimina una solicitud
func (h *SolicitudHandler) Delete(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	idStr := chi.URLParam(r, "id")
	id, err := strconv.Atoi(idStr)
	if err != nil {
		http.Error(w, "ID inválido", http.StatusBadRequest)
		return
	}

	if err := h.service.Delete(id); err != nil {
		if err.Error() == "solicitud no encontrada" {
			http.Error(w, err.Error(), http.StatusNotFound)
			return
		}
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

// UpdateStatus actualiza exclusivamente el estado de una solicitud
func (h *SolicitudHandler) UpdateStatus(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	idStr := chi.URLParam(r, "id")
	id, err := strconv.Atoi(idStr)
	if err != nil {
		http.Error(w, "ID inválido", http.StatusBadRequest)
		return
	}

	var input struct {
		Estado string `json:"estado"`
	}
	if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
		http.Error(w, "Error decodificando el body", http.StatusBadRequest)
		return
	}

	if err := h.service.UpdateStatus(id, input.Estado); err != nil {
		if err.Error() == "solicitud no encontrada" {
			http.Error(w, err.Error(), http.StatusNotFound)
			return
		}
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	// Devolver un mensaje de éxito simple
	json.NewEncoder(w).Encode(map[string]string{"message": "estado actualizado correctamente"})
}
