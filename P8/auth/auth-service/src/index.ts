import express from 'express';
import cors from 'cors';
import cookieParser from 'cookie-parser';
import dotenv from 'dotenv';
import { pool } from './utils/db';
import { encryptAES, decryptAES, hashPassword, comparePassword } from './utils/security';
import { generateToken, setAuthCookie, verifyToken, clearAuthCookie } from './utils/jwt';

dotenv.config();

const app = express();
const PORT = process.env.PORT || 4000;

app.use(cors({
    origin: true,
    credentials: true
}));
app.use(express.json());
app.use(cookieParser());


app.post('/register', async (req, res) => {
    try {
        const { carnet, nombres, apellidos, correo, password } = req.body;
        if (!carnet || !nombres || !apellidos || !correo || !password) {
            res.status(400).json({ message: "All fields are required" });
            return;
        }

        const nombresEncrypted = encryptAES(nombres);
        const apellidosEncrypted = encryptAES(apellidos);
        const correoEncrypted = encryptAES(correo);

        // Flag to toggle between AES and Bcrypt for passwords
        const useAES = process.env.USE_AES_FOR_PASSWORD === 'true';
        const passwordHash = useAES ? encryptAES(password) : await hashPassword(password);

        // El registro público SIEMPRE crea Cliente. Antes el body podía
        // mandar "rol": "Admin" y el endpoint lo aceptaba sin ninguna
        // verificación de que quien llamaba ya fuera administrador —
        // cualquiera podía autoasignarse Admin al registrarse. No existe
        // (todavía) un flujo de alta de administradores por API; si hace
        // falta uno, debe exigir que quien lo invoque ya esté autenticado
        // como Admin, nunca aceptar el rol desde el propio registro público.
        const rol = 'Cliente';
        
        const query = `
            INSERT INTO users (carnet, nombres_encrypted, apellidos_encrypted, correo_encrypted, password_hash, rol)
            VALUES (?, ?, ?, ?, ?, ?);
        `;
        const values = [carnet, nombresEncrypted, apellidosEncrypted, correoEncrypted, passwordHash, rol];
        
        const [result] = await pool.query<any>(query, values);
        
        res.status(201).json({ message: "User registered successfully", user: { id: result.insertId, carnet, rol } });
    } catch (error: any) {
        if (error.code === 'ER_DUP_ENTRY') {
            res.status(409).json({ message: "Carnet already registered" });
            return;
        }
        res.status(500).json({ message: "Error registering user", error: error.message });
    }
});

app.post('/login', async (req, res) => {
    try {
        const { carnet, password } = req.body;
        if (!carnet || !password) {
            res.status(400).json({ message: "Carnet and password required" });
            return;
        }
        
        const query = `SELECT * FROM users WHERE carnet = ?`;
        const [result] = await pool.query<any[]>(query, [carnet]);
        
        if (result.length === 0) {
            res.status(401).json({ message: "Invalid credentials" });
            return;
        }
        
        const user = result[0];
        const useAES = process.env.USE_AES_FOR_PASSWORD === 'true';
        
        let isValid = false;
        if (useAES) {
            try {
                isValid = decryptAES(user.password_hash) === password;
            } catch (e) {
                isValid = false;
            }
        } else {
            isValid = await comparePassword(password, user.password_hash);
        }
        
        if (!isValid) {
            res.status(401).json({ message: "Invalid credentials" });
            return;
        }
        
        const token = generateToken({ id: user.id, rol: user.rol });
        setAuthCookie(res, token);
        
        const nombresDecrypted = decryptAES(user.nombres_encrypted);
        const correoDecrypted = decryptAES(user.correo_encrypted);
        
        res.status(200).json({ message: `Welcome ${nombresDecrypted}`, rol: user.rol, correo: correoDecrypted, token: token });
    } catch (error: any) {
        res.status(500).json({ message: "Error logging in", error: error.message });
    }
});

app.post('/logout', (req, res) => {
    clearAuthCookie(res);
    res.json({ message: "Logged out successfully" });
});

// Endpoint para que otros microservicios validen si un token es correcto
app.post('/validate', (req, res) => {
    // El token puede venir en el body, en una cookie, o en el header Authorization
    const token = req.body.token || req.cookies?.jwt || req.headers.authorization?.split(' ')[1];
    
    if (!token) {
        res.status(401).json({ valid: false, message: "No token provided" });
        return;
    }

    const { payload, expired } = verifyToken(token);
    
    if (expired || !payload) {
        res.status(401).json({ valid: false, message: "Invalid or expired token" });
        return;
    }

    res.status(200).json({ valid: true, user: payload });
    return;
});

app.get('/health', (req, res) => {
    res.json({ status: 'Auth Service is running' });
});

app.get('/', (req, res) => {
    res.json({ status: 'OK' });
});

app.listen(PORT, () => {
    console.log(`Auth Service is running on http://localhost:${PORT}`);
});
