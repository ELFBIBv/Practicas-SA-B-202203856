import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { generateToken, verifyToken } from './jwt';

describe('jwt utils', () => {
    it('generates a token that verifies back to the same payload', () => {
        const token = generateToken({ id: 1, rol: 'Cliente' });
        const { payload, expired } = verifyToken(token);

        assert.equal(expired, false);
        assert.equal(payload?.id, 1);
        assert.equal(payload?.rol, 'Cliente');
    });

    it('rejects a tampered token', () => {
        const token = generateToken({ id: 2, rol: 'Admin' });
        const tampered = `${token.slice(0, -2)}xx`;
        const { payload, expired } = verifyToken(tampered);

        assert.equal(payload, null);
        assert.equal(expired, false);
    });
});
