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

	// Crear tablas básicas si no existen (solo ejemplo de prueba)
	createTableSQL := `CREATE TABLE IF NOT EXISTS test (
		"id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,		
		"name" TEXT
	  );`
	_, err = db.Exec(createTableSQL)
	if err != nil {
		log.Fatalf("Error creando la tabla inicial: %v", err)
	}

	return db
}
