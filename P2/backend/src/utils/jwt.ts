import jwt from 'jsonwebtoken';
import { Response } from 'express';
import dotenv from 'dotenv';
import ms from 'ms';

dotenv.config();

const JWT_SECRET = process.env.JWT_SECRET || 'supersecret123';
const JWT_EXPIRES_IN = process.env.JWT_EXPIRES_IN || '1h';
const JWT_GRACE_PERIOD_SEC = parseInt(process.env.JWT_GRACE_PERIOD_SEC || '300');

export interface TokenPayload {
    id: number;
    rol: string;
}

export const generateToken = (payload: TokenPayload): string => {
    return jwt.sign(payload, JWT_SECRET, { expiresIn: JWT_EXPIRES_IN as any });
};

export const verifyToken = (token: string): { payload: TokenPayload | null, expired: boolean } => {
    try {
        const decoded = jwt.verify(token, JWT_SECRET) as TokenPayload;
        return { payload: decoded, expired: false };
    } catch (e: any) {
        if (e.name === 'TokenExpiredError') {
            return { payload: null, expired: true };
        }
        return { payload: null, expired: false };
    }
};

export const decodeTokenUnsafe = (token: string): any => {
    return jwt.decode(token);
};

export const setAuthCookie = (res: Response, token: string) => {
    res.cookie('jwt', token, {
        // Al establecer httpOnly en true, evitamos ataques XSS porque
        // el Javascript del navegador (Frontend) NO podrá leer esta cookie.
        // El navegador se encargará de enviarla automáticamente en cada petición.
        httpOnly: true,
        secure: process.env.NODE_ENV === 'production',
        sameSite: 'strict',
        maxAge: Number(ms(JWT_EXPIRES_IN as any)) + (JWT_GRACE_PERIOD_SEC * 1000) // tiempo de vida del JWT + gracia
    });
};

export const clearAuthCookie = (res: Response) => {
    res.clearCookie('jwt');
};
