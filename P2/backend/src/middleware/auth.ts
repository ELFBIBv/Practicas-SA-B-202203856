import { Request, Response, NextFunction } from 'express';
import { verifyToken } from '../utils/jwt';
import { checkAuthorization } from '../services/authClient';

export const requireAuth = async (req: Request, res: Response, next: NextFunction) => {
    const token = req.cookies?.jwt;
    
    if (!token) {
        res.status(401).json({ message: "No token provided, please log in" });
        return;
    }

    const payload = verifyToken(token);
    
    if (!payload) {
        res.status(401).json({ message: "Invalid or expired token" });
        return;
    }

    // Attach payload to request
    (req as any).user = payload;

    const route = req.path;

    // Check authorization with microservice
    try {
        const isAllowed = await checkAuthorization(payload.rol, route);
        if (isAllowed) {
            next();
        } else {
            res.status(403).json({ message: "Access denied by authorization service" });
        }
    } catch (error) {
        res.status(500).json({ message: "Internal server error during authorization check" });
    }
};
