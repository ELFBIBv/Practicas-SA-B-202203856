import { Pool } from 'pg';
import dotenv from 'dotenv';

dotenv.config();

export const pool = new Pool({
  user: process.env.POSTGRES_USER || 'admin',
  host: 'localhost',
  database: process.env.POSTGRES_DB || 'practica2',
  password: process.env.POSTGRES_PASSWORD || 'password123',
  port: parseInt(process.env.POSTGRES_PORT || '5432'),
});

export const initDb = async () => {
  const query = `
    CREATE TABLE IF NOT EXISTS users (
      id SERIAL PRIMARY KEY,
      carnet VARCHAR(50) UNIQUE NOT NULL,
      nombres_encrypted TEXT NOT NULL,
      apellidos_encrypted TEXT NOT NULL,
      password_hash TEXT NOT NULL,
      rol VARCHAR(20) DEFAULT 'Cliente',
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );
  `;
  try {
    await pool.query(query);
    console.log("Database initialized and 'users' table ensured.");
  } catch (err) {
    console.error("Error initializing database:", err);
  }
};
