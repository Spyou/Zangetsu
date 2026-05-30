import { test } from 'node:test';
import assert from 'node:assert/strict';
import './host.mjs';

test('sha256Hex matches the AllAnime key vector', async () => {
  assert.equal(await globalThis.sha256Hex('Xot36i3lK3:v1'),
    'a254aa27c410f297bd04ba33a0c0df7ff4e706bf3ae27271c6703f84e750f552');
});

test('aesCtrDecrypt decrypts the known CTR vector', async () => {
  const out = await globalThis.aesCtrDecrypt({
    keyHex: '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f',
    counterHex: 'aabbccddeeff00112233445566778899',
    dataB64: '3t9fAEwGPNSaDqg4RX6JzX8rIZ/1Vpw=',
  });
  assert.equal(out, 'hello-watch_app-aes-ctr');
});

test('base64ToBytes + bytesToHex round-trip', () => {
  assert.equal(globalThis.bytesToHex(globalThis.base64ToBytes('AAEC')), '000102');
});
