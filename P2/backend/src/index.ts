import express from 'express';
import cors from 'cors';
import cookieParser from 'cookie-parser';
import dotenv from 'dotenv';

dotenv.config();

const app = express();
const PORT = process.env.PORT || 3000;

app.use(cors({
    origin: true,
    credentials: true
}));
app.use(express.json());
app.use(cookieParser());

import { requireAuth } from './middleware/auth';

app.get('/health', (req, res) => {
    res.json({ status: 'Main Backend is running' });
});

// Protected routes
app.get('/ruta1', requireAuth, (req, res) => {
    res.json({ message: 'Welcome to Ruta 1 (Admin only)' });
});

app.get('/ruta2', requireAuth, (req, res) => {
    res.json({ message: 'Welcome to Ruta 2 (Admin and Cliente)' });
});

app.listen(PORT, () => {
    console.log(`Backend server is running on http://localhost:${PORT}`);
});
