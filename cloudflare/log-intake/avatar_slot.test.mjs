import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import worker from './src/index.js';

const jwksUrl =
  'https://eogwzrlfoercfwcfwlmv.supabase.co/auth/v1/.well-known/jwks.json';
const issuer = 'https://eogwzrlfoercfwcfwlmv.supabase.co/auth/v1';
const userId = '12000000-0000-4000-8000-000000000001';
const maxBytes = 256 * 1024;
const encoder = new TextEncoder();
const originalFetch = globalThis.fetch;
const keys = await crypto.subtle.generateKey(
  { name: 'ECDSA', namedCurve: 'P-256' },
  true,
  ['sign', 'verify'],
);
const publicJwk = await crypto.subtle.exportKey('jwk', keys.publicKey);
publicJwk.kid = 'avatar-test-key';
publicJwk.alg = 'ES256';

before(() => {
  globalThis.fetch = async (input, init) => {
    if (String(input) === jwksUrl) {
      return new Response(JSON.stringify({ keys: [publicJwk] }), {
        headers: { 'content-type': 'application/json' },
      });
    }
    return originalFetch(input, init);
  };
});

after(() => {
  globalThis.fetch = originalFetch;
});

function base64url(value) {
  return Buffer.from(value).toString('base64url');
}

async function token({ header = {}, claims = {} } = {}) {
  const tokenHeader = {
    alg: 'ES256',
    kid: publicJwk.kid,
    typ: 'JWT',
    ...header,
  };
  const payload = {
    iss: issuer,
    aud: 'authenticated',
    sub: userId,
    role: 'authenticated',
    exp: Math.floor(Date.now() / 1000) + 3600,
    ...claims,
  };
  const head = base64url(JSON.stringify(tokenHeader));
  const body = base64url(JSON.stringify(payload));
  const data = `${head}.${body}`;
  const signature = await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' },
    keys.privateKey,
    encoder.encode(data),
  );
  return `${data}.${base64url(signature)}`;
}

function environment() {
  const writes = [];
  return {
    writes,
    AVATAR_PUBLIC_BASE: 'https://avatars.example',
    AVATARS: {
      async put(...args) {
        writes.push(args);
      },
    },
  };
}

function requestFor(jwt, body, extraHeaders = {}, extra = {}) {
  return new Request('https://intake.example/v1/avatar-slot', {
    method: 'POST',
    headers: {
      authorization: `Bearer ${jwt}`,
      'content-type': 'image/jpeg',
      ...extraHeaders,
    },
    body,
    ...extra,
  });
}

function jpegBytes(length = 3) {
  const bytes = new Uint8Array(length);
  bytes.set([0xff, 0xd8, 0xff]);
  return bytes;
}

test('accepts a valid Supabase ES256 user token and stores a small image', async () => {
  const env = environment();
  const response = await worker.fetch(
    requestFor(await token(), jpegBytes()),
    env,
  );

  assert.equal(response.status, 200);
  assert.equal(env.writes.length, 1);
  assert.match(env.writes[0][0], new RegExp(`^avatars/${userId}/`));
  assert.equal(env.writes[0][1].byteLength, 3);
});

test('accepts a photo exactly at the 256 KiB limit', async () => {
  const env = environment();
  const response = await worker.fetch(
    requestFor(await token(), jpegBytes(maxBytes)),
    env,
  );

  assert.equal(response.status, 200);
  assert.equal(env.writes[0][1].byteLength, maxBytes);
});

for (const [type, bytes] of [
  ['image/png', new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])],
  ['image/webp', encoder.encode('RIFF\0\0\0\0WEBP')],
]) {
  test(`accepts matching ${type} data`, async () => {
    const env = environment();
    const response = await worker.fetch(
      requestFor(await token(), bytes, { 'content-type': type }),
      env,
    );

    assert.equal(response.status, 200);
    assert.equal(env.writes.length, 1);
  });
}

test('accepts an audience array containing authenticated', async () => {
  const env = environment();
  const response = await worker.fetch(
    requestFor(
      await token({ claims: { aud: ['authenticated', 'profile-api'] } }),
      jpegBytes(),
    ),
    env,
  );

  assert.equal(response.status, 200);
  assert.equal(env.writes.length, 1);
});

test('rejects declared image sizes above 256 KiB before writing to R2', async () => {
  const env = environment();
  const response = await worker.fetch(
    requestFor(await token(), new Uint8Array([1]), {
      'content-length': String(maxBytes + 1),
    }),
    env,
  );

  assert.equal(response.status, 413);
  assert.equal(env.writes.length, 0);
});

test('rejects an oversized streamed body even without a length header', async () => {
  const env = environment();
  const body = new ReadableStream({
    start(controller) {
      controller.enqueue(new Uint8Array(maxBytes));
      controller.enqueue(new Uint8Array(1));
      controller.close();
    },
  });
  const response = await worker.fetch(
    requestFor(await token(), body, {}, { duplex: 'half' }),
    env,
  );

  assert.equal(response.status, 413);
  assert.equal(env.writes.length, 0);
});

test('rejects non-image content types', async () => {
  const env = environment();
  const response = await worker.fetch(
    requestFor(await token(), new Uint8Array([1]), {
      'content-type': 'image/svg+xml',
    }),
    env,
  );

  assert.equal(response.status, 400);
  assert.equal(env.writes.length, 0);
});

test('rejects image bytes that do not match the declared image type', async () => {
  const env = environment();
  const response = await worker.fetch(
    requestFor(await token(), new Uint8Array([1, 2, 3])),
    env,
  );

  assert.equal(response.status, 400);
  assert.equal(env.writes.length, 0);
});

for (const [name, options] of [
  ['a non-ES256 header', { header: { alg: 'HS256' } }],
  ['a missing expiry', { claims: { exp: undefined } }],
  ['an expired token', { claims: { exp: Math.floor(Date.now() / 1000) - 1 } }],
  ['the wrong issuer', { claims: { iss: 'https://elsewhere.example/auth/v1' } }],
  ['the wrong audience', { claims: { aud: 'anon' } }],
  ['a future not-before time', { claims: { nbf: Math.floor(Date.now() / 1000) + 60 } }],
  ['a non-user role', { claims: { role: 'service_role' } }],
]) {
  test(`rejects ${name}`, async () => {
    const env = environment();
    const response = await worker.fetch(
      requestFor(await token(options), new Uint8Array([1])),
      env,
    );

    assert.equal(response.status, 401);
    assert.equal(env.writes.length, 0);
  });
}
