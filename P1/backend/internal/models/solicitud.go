package models

type SolicitudOperativa struct {
	ID              int     `json:"id"`
	Titulo          string  `json:"titulo"`
	AreaSolicitante string  `json:"area_solicitante"`
	Prioridad       int     `json:"prioridad"`
	CostoEstimado   float64 `json:"costo_estimado"`
	Estado          string  `json:"estado"`
}
