import mysql from 'mysql2/promise';
import dotenv from 'dotenv';

dotenv.config();

export const pool = mysql.createPool({
  user: process.env.DB_USER || 'user',
  host: process.env.DB_HOST || 'localhost',
  database: process.env.DB_NAME || 'auth_db',
  password: process.env.DB_PASSWORD || 'password123',
  port: parseInt(process.env.DB_PORT || '3306', 10),
  waitForConnections: true,
  connectionLimit: 10,
  queueLimit: 0
});
