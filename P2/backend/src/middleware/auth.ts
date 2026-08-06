import { Request, Response, NextFunction } from 'express';
import { verifyToken, decodeTokenUnsafe, generateToken, setAuthCookie, TokenPayload } from '../utils/jwt';
import { checkAuthorization } from '../services/authClient';

const JWT_GRACE_PERIOD_SEC = parseInt(process.env.JWT_GRACE_PERIOD_SEC || '300'); // default 5 mins

export const requireAuth = async (req: Request, res: Response, next: NextFunction) => {
    const token = req.cookies?.jwt;
    
    if (!token) {
        res.status(401).json({ message: "No token provided, please log in" });
        return;
    }

    const { payload, expired } = verifyToken(token);
    let finalPayload = payload;
    
    if (expired) {
        const decoded = decodeTokenUnsafe(token) as any;
        if (decoded && decoded.exp) {
            const now = Math.floor(Date.now() / 1000);
            if (now - decoded.exp < JWT_GRACE_PERIOD_SEC) {
                // Renew token
                const newPayload: TokenPayload = { id: decoded.id, rol: decoded.rol };
                const newToken = generateToken(newPayload);
                setAuthCookie(res, newToken);
                finalPayload = newPayload;
            }
        }
    }
    
    if (!finalPayload) {
        res.status(401).json({ message: "Invalid or expired token" });
        return;
    }

    // Attach payload to request
    (req as any).user = finalPayload;

    const route = req.path;

    // Check authorization with microservice
    try {
        const isAllowed = await checkAuthorization(finalPayload.rol, route);
        if (isAllowed) {
            next();
        } else {
            res.status(403).json({ message: "Access denied by authorization service" });
        }
    } catch (error) {
        res.status(500).json({ message: "Internal server error during authorization check" });
    }
};
