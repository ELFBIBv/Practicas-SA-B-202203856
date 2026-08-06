CREATE TABLE IF NOT EXISTS users (
  id SERIAL PRIMARY KEY,
  carnet VARCHAR(50) UNIQUE NOT NULL,
  nombres_encrypted TEXT NOT NULL,
  apellidos_encrypted TEXT NOT NULL,
  password_hash TEXT NOT NULL,
  rol VARCHAR(20) DEFAULT 'Cliente',
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
