"""Account-bound addon sync; configured URLs are encrypted before database writes."""

import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
from urllib.request import Request, build_opener, ProxyHandler

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from klipy_proxy import KlipyProxy, _NoRedirect, _Problem

MAX_BYTES = 1024 * 1024
FORMAT = 'stremio-server-v1'


class StremioProxy:
    def __init__(self, key, verifier, exchange=None):
        if len(key) != 32:
            raise ValueError('Addon encryption key must be 32 bytes')
        self.cipher = AESGCM(key)
        self.verifier = verifier
        self.exchange = exchange or self._exchange

    def seal(self, owner, configuration):
        nonce = os.urandom(12)
        raw = json.dumps(configuration, separators=(',', ':')).encode()
        if len(raw) > MAX_BYTES:
            raise _Problem(413, 'Addon configuration is too large')
        encrypted = self.cipher.encrypt(nonce, raw, f'{FORMAT}|{owner}'.encode())
        return {'format': FORMAT, 'nonce': base64.b64encode(nonce).decode(),
                'ciphertext': base64.b64encode(encrypted).decode()}

    def open(self, owner, envelope):
        try:
            if envelope['format'] != FORMAT:
                raise ValueError()
            nonce = base64.b64decode(envelope['nonce'], validate=True)
            encrypted = base64.b64decode(envelope['ciphertext'], validate=True)
            if len(nonce) != 12 or len(encrypted) > MAX_BYTES + 16:
                raise ValueError()
            value = json.loads(self.cipher.decrypt(nonce, encrypted, f'{FORMAT}|{owner}'.encode()))
            if not isinstance(value, dict):
                raise ValueError()
            return value
        except Exception:
            raise _Problem(400, 'Addon backup cannot be opened by this account') from None

    def handle(self, method, target, authorization, body):
        try:
            if method != 'POST' or target not in (
                '/stremio/v1/seal', '/stremio/v1/open', '/stremio/v1/configuration'
            ):
                raise _Problem(404, 'Not found')
            owner = self.verifier._verify_user(authorization)
            if not self.verifier._allow_user(owner):
                raise _Problem(429, 'Try again later')
            if len(body) > MAX_BYTES * 2:
                raise _Problem(413, 'Request is too large')
            try:
                data = json.loads(body)
                if not isinstance(data, dict):
                    raise ValueError()
            except (ValueError, UnicodeDecodeError):
                raise _Problem(400, 'Invalid request') from None
            if target.endswith('/open'):
                if set(data) != {'envelope'}:
                    raise _Problem(400, 'Invalid request')
                return KlipyProxy._json(200, {'configuration': self.open(owner, data['envelope'])})
            if target.endswith('/seal'):
                if set(data) != {'configuration'} or not isinstance(data['configuration'], dict):
                    raise _Problem(400, 'Invalid request')
                return KlipyProxy._json(200, self.seal(owner, data['configuration']))
            expected = data.get('expectedVersion')
            if data and (set(data) != {'expectedVersion', 'configuration'} or
                         type(expected) is not int or not 0 <= expected < 2**53 or
                         not isinstance(data['configuration'], dict)):
                raise _Problem(400, 'Invalid request')
            payload = self.seal(owner, data['configuration']) if data else None
            result = self.exchange(authorization, expected, payload)
            configuration = self.open(owner, result['payload']) if result.get('payload') else None
            return KlipyProxy._json(200, {'version': result['version'],
                'accepted': result['accepted'], 'configuration': configuration})
        except _Problem as error:
            message = 'Sign in to sync addons' if error.status == 401 else error.message
            return KlipyProxy._json(error.status, {'error': message})
        except Exception:
            return KlipyProxy._json(503, {'error': 'Addon sync is temporarily unavailable'})

    @staticmethod
    def _exchange(authorization, expected, payload):
        request = Request('http://127.0.0.1:3000/rpc/stremio_configuration',
            data=json.dumps({'p_expected_version': expected, 'p_payload': payload}).encode(),
            headers={'Authorization': authorization, 'Content-Type': 'application/json'}, method='POST')
        with build_opener(ProxyHandler({}), _NoRedirect()).open(request, timeout=10) as response:
            raw = response.read(MAX_BYTES * 2 + 1)
            if len(raw) > MAX_BYTES * 2:
                raise ValueError('Response exceeds limit')
            return json.loads(raw)


class Handler(BaseHTTPRequestHandler):
    server_version = 'AniAura'
    sys_version = ''

    def do_POST(self):
        self.connection.settimeout(15)
        try:
            lengths = self.headers.get_all('Content-Length', [])
            authorizations = self.headers.get_all('Authorization', [])
            if len(lengths) != 1 or len(authorizations) > 1 or self.headers.get('Transfer-Encoding'):
                raise ValueError()
            length = int(lengths[0])
            if not 0 <= length <= MAX_BYTES * 2:
                raise ValueError()
            body = self.rfile.read(length)
            if len(body) != length:
                raise ValueError()
            status, headers, payload = self.server.proxy.handle('POST', self.path, authorizations[0] if authorizations else None, body)
        except Exception:
            self.close_connection = True
            status, headers, payload = KlipyProxy._json(400, {'error': 'Invalid request'})
        self.send_response(status)
        for key, value in headers.items():
            self.send_header(key, value)
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, format_string, *args):
        pass


def serve():
    credential = Path(os.environ['CREDENTIALS_DIRECTORY']) / 'stremio_key'
    key = base64.b64decode(credential.read_text().strip(), validate=True)
    verifier = KlipyProxy('', os.environ['SUPABASE_ISSUER'],
                         os.environ.get('SUPABASE_JWKS_PATH', '/etc/AniAura-sync/jwks.json'),
                         additional_issuer=os.environ.get('VPS_AUTH_ISSUER'))
    server = ThreadingHTTPServer(('127.0.0.1', 3111), Handler)
    server.daemon_threads = True
    server.proxy = StremioProxy(key, verifier)
    server.serve_forever()


if __name__ == '__main__':
    serve()
