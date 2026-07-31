package repository

import (
	"database/sql"
	"errors"
	"backend/internal/models"
)

type SolicitudRepository interface {
	GetAll() ([]models.SolicitudOperativa, error)
	Create(solicitud *models.SolicitudOperativa) error
	Update(solicitud *models.SolicitudOperativa) error
	Delete(id int) error
	UpdateStatus(id int, estado string) error
	GetByID(id int) (*models.SolicitudOperativa, error)
}

type solicitudRepository struct {
	db *sql.DB
}

func NewSolicitudRepository(db *sql.DB) SolicitudRepository {
	return &solicitudRepository{db: db}
}

func (r *solicitudRepository) GetAll() ([]models.SolicitudOperativa, error) {
	rows, err := r.db.Query(`SELECT id, titulo, area_solicitante, prioridad, costo_estimado, estado FROM solicitudes_operativas`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var solicitudes []models.SolicitudOperativa
	for rows.Next() {
		var s models.SolicitudOperativa
		if err := rows.Scan(&s.ID, &s.Titulo, &s.AreaSolicitante, &s.Prioridad, &s.CostoEstimado, &s.Estado); err != nil {
			return nil, err
		}
		solicitudes = append(solicitudes, s)
	}
	return solicitudes, nil
}

func (r *solicitudRepository) Create(s *models.SolicitudOperativa) error {
	query := `INSERT INTO solicitudes_operativas (titulo, area_solicitante, prioridad, costo_estimado, estado) VALUES (?, ?, ?, ?, ?)`
	result, err := r.db.Exec(query, s.Titulo, s.AreaSolicitante, s.Prioridad, s.CostoEstimado, s.Estado)
	if err != nil {
		return err
	}
	id, err := result.LastInsertId()
	if err != nil {
		return err
	}
	s.ID = int(id)
	return nil
}

func (r *solicitudRepository) Update(s *models.SolicitudOperativa) error {
	query := `UPDATE solicitudes_operativas SET titulo = ?, area_solicitante = ?, prioridad = ?, costo_estimado = ?, estado = ? WHERE id = ?`
	res, err := r.db.Exec(query, s.Titulo, s.AreaSolicitante, s.Prioridad, s.CostoEstimado, s.Estado, s.ID)
	if err != nil {
		return err
	}
	rowsAffected, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if rowsAffected == 0 {
		return errors.New("solicitud no encontrada")
	}
	return nil
}

func (r *solicitudRepository) Delete(id int) error {
	query := `DELETE FROM solicitudes_operativas WHERE id = ?`
	res, err := r.db.Exec(query, id)
	if err != nil {
		return err
	}
	rowsAffected, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if rowsAffected == 0 {
		return errors.New("solicitud no encontrada")
	}
	return nil
}

func (r *solicitudRepository) UpdateStatus(id int, estado string) error {
	query := `UPDATE solicitudes_operativas SET estado = ? WHERE id = ?`
	res, err := r.db.Exec(query, estado, id)
	if err != nil {
		return err
	}
	rowsAffected, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if rowsAffected == 0 {
		return errors.New("solicitud no encontrada")
	}
	return nil
}

func (r *solicitudRepository) GetByID(id int) (*models.SolicitudOperativa, error) {
	query := `SELECT id, titulo, area_solicitante, prioridad, costo_estimado, estado FROM solicitudes_operativas WHERE id = ?`
	row := r.db.QueryRow(query, id)

	var s models.SolicitudOperativa
	if err := row.Scan(&s.ID, &s.Titulo, &s.AreaSolicitante, &s.Prioridad, &s.CostoEstimado, &s.Estado); err != nil {
		if err == sql.ErrNoRows {
			return nil, errors.New("solicitud no encontrada")
		}
		return nil, err
	}
	return &s, nil
}
