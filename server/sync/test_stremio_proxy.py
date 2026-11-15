import json
import os
from pathlib import Path
import tempfile
import time
import unittest

import jwt
from cryptography.hazmat.primitives.asymmetric import ec
from klipy_proxy import KlipyProxy
from stremio_proxy import StremioProxy


class StremioProxyTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.key = ec.generate_private_key(ec.SECP256R1())
        jwk = json.loads(jwt.algorithms.ECAlgorithm.to_jwk(self.key.public_key()))
        jwk.update(kid='test', alg='ES256', key_ops=['verify'])
        path = Path(self.directory.name) / 'jwks.json'
        path.write_text(json.dumps({'keys': [jwk]}))
        self.verifier = KlipyProxy('', 'https://auth.test', path)
        self.rows = {}
        self.proxy = StremioProxy(os.urandom(32), self.verifier, self.exchange)
        self.owner = '4712fc75-74e1-4559-bd1c-bd983f5d4063'

    def tearDown(self):
        self.directory.cleanup()

    def exchange(self, authorization, expected, payload):
        uid = self.verifier._verify_user(authorization)
        row = self.rows.get(uid, {'version': 0, 'payload': None})
        accepted = expected is None or expected == row['version']
        if expected is not None and accepted:
            row = {'version': row['version'] + 1, 'payload': payload}
            self.rows[uid] = row
        return {**row, 'accepted': accepted}

    def request(self, route, body, owner=None, auth=True):
        token = jwt.encode({'iss': 'https://auth.test', 'aud': 'authenticated',
            'sub': owner or self.owner, 'role': 'authenticated', 'iat': int(time.time()),
            'exp': int(time.time()) + 60}, self.key, algorithm='ES256', headers={'kid': 'test'})
        status, headers, response = self.proxy.handle('POST', '/stremio/v1/' + route,
            'Bearer ' + token if auth else None, json.dumps(body).encode())
        self.assertEqual(headers['Cache-Control'], 'no-store')
        return status, json.loads(response)

    def test_sync_encrypts_storage_and_rejects_stale_writes(self):
        config = {'version': 1, 'installations': [{'url': 'https://addon.test/private-token'}]}
        status, saved = self.request('configuration', {'expectedVersion': 0, 'configuration': config})
        self.assertEqual(status, 200)
        self.assertTrue(saved['accepted'])
        self.assertNotIn('private-token', json.dumps(self.rows))
        _, fetched = self.request('configuration', {})
        self.assertEqual(fetched['configuration'], config)
        _, stale = self.request('configuration', {'expectedVersion': 0, 'configuration': {}})
        self.assertFalse(stale['accepted'])
        self.assertEqual(stale['configuration'], config)

    def test_cloud_backup_envelope_is_bound_to_the_account(self):
        status, sealed = self.request('seal', {'configuration': {'url': 'https://addon.test/secret'}})
        self.assertEqual(status, 200)
        self.assertNotIn('secret', json.dumps(sealed))
        _, opened = self.request('open', {'envelope': sealed})
        self.assertEqual(opened['configuration']['url'], 'https://addon.test/secret')
        status, _ = self.request('open', {'envelope': sealed}, owner='97f2c39d-2c2a-4767-85f8-730a48e9c955')
        self.assertEqual(status, 400)
        sealed['ciphertext'] = 'bad'
        self.assertEqual(self.request('open', {'envelope': sealed})[0], 400)

    def test_authentication_and_bounds(self):
        self.assertEqual(self.request('configuration', {}, auth=False)[0], 401)
        self.assertEqual(self.request('configuration', {'expectedVersion': -1, 'configuration': {}})[0], 400)
        self.assertEqual(self.request('seal', {'configuration': {'value': 'x' * (1024 * 1024)}})[0], 413)
        self.assertEqual(self.request('configuration', {'user_key': 'someone-else'})[0], 400)

    def test_failures_do_not_expose_payload_or_tokens(self):
        def fail(*args):
            raise RuntimeError('private-token')
        self.proxy.exchange = fail
        status, body = self.request('configuration', {})
        self.assertEqual(status, 503)
        self.assertNotIn('private-token', json.dumps(body))


if __name__ == '__main__':
    unittest.main()
