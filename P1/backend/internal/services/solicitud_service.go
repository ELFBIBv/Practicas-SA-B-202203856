package services

import (
	"backend/internal/models"
	"backend/internal/repository"
	"errors"
)

type SolicitudService interface {
	GetAll() ([]models.SolicitudOperativa, error)
	Create(solicitud *models.SolicitudOperativa) error
	Update(id int, solicitud *models.SolicitudOperativa) error
	Delete(id int) error
	UpdateStatus(id int, estado string) error
	GetByID(id int) (*models.SolicitudOperativa, error)
}

type solicitudService struct {
	repo repository.SolicitudRepository
}

func NewSolicitudService(repo repository.SolicitudRepository) SolicitudService {
	return &solicitudService{repo: repo}
}

func (s *solicitudService) GetAll() ([]models.SolicitudOperativa, error) {
	return s.repo.GetAll()
}

func (s *solicitudService) GetByID(id int) (*models.SolicitudOperativa, error) {
	return s.repo.GetByID(id)
}

func (s *solicitudService) Create(solicitud *models.SolicitudOperativa) error {
	if err := s.validate(solicitud); err != nil {
		return err
	}
	// Estado inicial por defecto si no viene uno o si es invalido
	if solicitud.Estado != "registrada" && solicitud.Estado != "en_proceso" && solicitud.Estado != "finalizada" {
		solicitud.Estado = "registrada"
	}

	return s.repo.Create(solicitud)
}

func (s *solicitudService) Update(id int, solicitud *models.SolicitudOperativa) error {
	if err := s.validate(solicitud); err != nil {
		return err
	}
	if err := s.validateStatus(solicitud.Estado); err != nil {
		return err
	}
	solicitud.ID = id
	return s.repo.Update(solicitud)
}

func (s *solicitudService) Delete(id int) error {
	return s.repo.Delete(id)
}

func (s *solicitudService) UpdateStatus(id int, estado string) error {
	if err := s.validateStatus(estado); err != nil {
		return err
	}
	return s.repo.UpdateStatus(id, estado)
}

func (s *solicitudService) validate(solicitud *models.SolicitudOperativa) error {
	if solicitud.Titulo == "" {
		return errors.New("el título es obligatorio")
	}
	if solicitud.AreaSolicitante == "" {
		return errors.New("el área solicitante es obligatoria")
	}
	if solicitud.Prioridad < 1 || solicitud.Prioridad > 5 {
		return errors.New("la prioridad debe estar entre 1 y 5")
	}
	if solicitud.CostoEstimado < 0 {
		return errors.New("el costo estimado no puede ser negativo")
	}
	return nil
}

func (s *solicitudService) validateStatus(estado string) error {
	if estado != "registrada" && estado != "en_proceso" && estado != "finalizada" {
		return errors.New("estado inválido. Debe ser: 'registrada', 'en_proceso' o 'finalizada'")
	}
	return nil
}
