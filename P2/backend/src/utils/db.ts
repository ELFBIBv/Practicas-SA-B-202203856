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
