import CryptoJS from 'crypto-js';
import bcrypt from 'bcrypt';
import dotenv from 'dotenv';

dotenv.config();

const AES_SECRET = process.env.AES_SECRET_KEY || 'default_secret';

export const encryptAES = (data: string): string => {
    return CryptoJS.AES.encrypt(data, AES_SECRET).toString();
};

export const decryptAES = (cipherText: string): string => {
    const bytes = CryptoJS.AES.decrypt(cipherText, AES_SECRET);
    return bytes.toString(CryptoJS.enc.Utf8);
};

export const hashPassword = async (password: string): Promise<string> => {
    const saltRounds = 10;
    return await bcrypt.hash(password, saltRounds);
};

export const comparePassword = async (password: string, hash: string): Promise<boolean> => {
    return await bcrypt.compare(password, hash);
};
