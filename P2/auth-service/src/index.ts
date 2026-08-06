import express from 'express';
import cors from 'cors';
import dotenv from 'dotenv';

dotenv.config();

const app = express();
const PORT = process.env.PORT || 4000;

app.use(cors());
app.use(express.json());

// Routes to protect and their allowed roles
const routePermissions: Record<string, string[]> = {
    '/ruta1': ['Admin'],
    '/ruta2': ['Admin', 'Cliente']
};

app.post('/authorize', (req, res) => {
    const { rol, route } = req.body;

    if (!rol || !route) {
        return res.status(400).json({ allowed: false, message: "Missing rol or route in body" });
    }

    const allowedRoles = routePermissions[route];

    if (!allowedRoles) {
        // If route is not defined in permissions, deny by default
        return res.status(403).json({ allowed: false, message: "Route not protected or not found" });
    }

    if (allowedRoles.includes(rol)) {
        return res.status(200).json({ allowed: true, message: "Access granted" });
    } else {
        return res.status(403).json({ allowed: false, message: "Access denied" });
    }
});

app.listen(PORT, () => {
    console.log(`Authorization microservice running on http://localhost:${PORT}`);
});
