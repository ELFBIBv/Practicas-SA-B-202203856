import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { encryptAES, decryptAES, hashPassword, comparePassword } from './security';

describe('security utils', () => {
    it('encrypts and decrypts AES round-trip', () => {
        const original = 'usuario de prueba';
        const cipher = encryptAES(original);

        assert.notEqual(cipher, original);
        assert.equal(decryptAES(cipher), original);
    });

    it('hashes a password and verifies it with bcrypt', async () => {
        const plain = 'ClaveSegura123';
        const hash = await hashPassword(plain);

        assert.notEqual(hash, plain);
        assert.equal(await comparePassword(plain, hash), true);
        assert.equal(await comparePassword('otraClave', hash), false);
    });
});
