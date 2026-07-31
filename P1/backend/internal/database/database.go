package database

import (
	"database/sql"
	"log"

	_ "modernc.org/sqlite"
)

func InitDB(dbName string) *sql.DB {
	db, err := sql.Open("sqlite", dbName)
	if err != nil {
		log.Fatalf("Error abriendo la base de datos: %v", err)
	}

	// Verificar la conexión
	if err := db.Ping(); err != nil {
		log.Fatalf("Error conectando a la base de datos: %v", err)
	}

	log.Println("Conexión exitosa a SQLite")

	// Crear la tabla de solicitudes operativas si no existe
	createTableSQL := `CREATE TABLE IF NOT EXISTS solicitudes_operativas (
		"id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,		
		"titulo" TEXT NOT NULL,
		"area_solicitante" TEXT NOT NULL,
		"prioridad" INTEGER NOT NULL,
		"costo_estimado" REAL NOT NULL,
		"estado" TEXT NOT NULL
	  );`
	_, err = db.Exec(createTableSQL)
	if err != nil {
		log.Fatalf("Error creando la tabla solicitudes_operativas: %v", err)
	}

	return db
}
