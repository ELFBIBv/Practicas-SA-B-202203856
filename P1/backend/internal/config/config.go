package config

import (
	"os"
)

type Config struct {
	Port    string
	DBName  string
}

func LoadConfig() Config {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	dbName := os.Getenv("DB_NAME")
	if dbName == "" {
		dbName = "database.sqlite"
	}

	return Config{
		Port:   port,
		DBName: dbName,
	}
}
