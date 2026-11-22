import json
from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
import tempfile
from threading import Thread
import time
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

import jwt
from cryptography.hazmat.primitives.asymmetric import ec

from klipy_proxy import KlipyProxy, _Handler


ISSUER = "https://eogwzrlfoercfwcfwlmv.supabase.co/auth/v1"


class KlipyProxyTest(unittest.TestCase):
    def setUp(self):
        self.key = ec.generate_private_key(ec.SECP256R1())
        public_jwk = json.loads(jwt.algorithms.ECAlgorithm.to_jwk(self.key.public_key()))
        public_jwk.update({"kid": "test-key", "alg": "ES256", "key_ops": ["verify"]})
        self.jwks_dir = tempfile.TemporaryDirectory()
        self.jwks_path = Path(self.jwks_dir.name) / "jwks.json"
        self.jwks_path.write_text(json.dumps({"keys": [public_jwk]}))
        self.upstream_calls = []
        self.upstream_response = b'{"result":true,"data":{"data":[]}}'
        self.proxy = KlipyProxy(
            api_key="server-only-test-key",
            issuer=ISSUER,
            jwks_path=self.jwks_path,
            upstream=self._upstream,
        )

    def tearDown(self):
        self.jwks_dir.cleanup()

    def _token(self, **overrides):
        claims = {
            "iss": ISSUER,
            "aud": "authenticated",
            "sub": "4712fc75-74e1-4559-bd1c-bd983f5d4063",
            "role": "authenticated",
            "is_anonymous": False,
            "iat": int(time.time()) - 60,
            "exp": int(time.time()) + 3600,
        }
        claims.update(overrides)
        return jwt.encode(claims, self.key, algorithm="ES256", headers={"kid": "test-key"})

    def _upstream(self, url, method, body):
        self.upstream_calls.append((url, method, body))
        if "upstream-error" in url:
            raise RuntimeError(url)
        return 200, self.upstream_response

    def test_upstream_uses_AniAura_user_agent(self):
        with patch("klipy_proxy.build_opener") as build_opener:
            response = build_opener.return_value.open.return_value.__enter__.return_value
            response.status = 200
            response.read.return_value = b'{"result":true}'

            status, body = KlipyProxy._fetch_upstream(
                "https://api.klipy.com/api/v1/key/gifs/search", "GET", None
            )

        request = build_opener.return_value.open.call_args.args[0]
        self.assertEqual(request.get_header("User-agent"), "AniAura (+https://AniAura.online)")
        self.assertEqual(status, 200)
        self.assertEqual(body, b'{"result":true}')

    def test_search_requires_verified_user_and_keeps_provider_response(self):
        response = b'{"result":true,"media":"https://static.klipy.com/a.gif"}'
        self.upstream_response = response

        status, headers, body = self.proxy.handle(
            "GET",
            "/klipy/v1/gifs/search?q=cat%20dance",
            f"Bearer {self._token()}",
            b"",
        )

        self.assertEqual(status, 200)
        self.assertEqual(body, response)
        self.assertEqual(headers["Cache-Control"], "no-store")
        url, method, body = self.upstream_calls[-1]
        self.assertEqual(method, "GET")
        self.assertEqual(urlsplit(url).path, "/api/v1/server-only-test-key/gifs/search")
        self.assertEqual(parse_qs(urlsplit(url).query), {
            "q": ["cat dance"],
            "page": ["1"],
            "per_page": ["24"],
            "content_filter": ["high"],
            "format_filter": ["gif"],
        })
        self.assertIsNone(body)

    def test_missing_invalid_anonymous_and_wrong_role_tokens_are_rejected(self):
        tokens = [
            None,
            "Bearer invalid",
            f"Bearer {self._token(is_anonymous=True)}",
            f'Bearer {self._token(role="anon")}',
        ]
        for authorization in tokens:
            with self.subTest(authorization=authorization is not None):
                status, _, _ = self.proxy.handle(
                    "GET", "/klipy/v1/gifs/search?q=cat", authorization, b""
                )
                self.assertEqual(status, 401)
        self.assertEqual(self.upstream_calls, [])

    def test_issuer_audience_expiration_and_signature_are_verified(self):
        other_key = ec.generate_private_key(ec.SECP256R1())
        bad_signature = jwt.encode(
            {
                "iss": ISSUER,
                "aud": "authenticated",
                "sub": "4712fc75-74e1-4559-bd1c-bd983f5d4063",
                "role": "authenticated",
                "iat": int(time.time()) - 60,
                "exp": int(time.time()) + 3600,
            },
            other_key,
            algorithm="ES256",
            headers={"kid": "test-key"},
        )
        tokens = [
            self._token(iss="https://attacker.example/auth/v1"),
            self._token(aud="anon"),
            self._token(exp=int(time.time()) - 1),
            bad_signature,
        ]
        for token in tokens:
            with self.subTest(token=token[:12]):
                status, _, _ = self.proxy.handle(
                    "GET", "/klipy/v1/gifs/search?q=cat", f"Bearer {token}", b""
                )
                self.assertEqual(status, 401)
        self.assertEqual(self.upstream_calls, [])

    def test_only_fixed_routes_and_inputs_are_forwarded(self):
        token = f"Bearer {self._token()}"
        bad_requests = [
            ("GET", "/klipy/v1/arbitrary?url=https://example.com", b""),
            ("GET", "/klipy/v1/gifs/search?q=cat&api_key=other", b""),
            ("GET", "/klipy/v1/gifs/items?slugs=../private", b""),
            ("POST", "/klipy/v1/gifs/search?q=cat", b""),
        ]
        for method, target, body in bad_requests:
            with self.subTest(target=target, method=method):
                status, _, _ = self.proxy.handle(method, target, token, body)
                self.assertIn(status, (400, 404, 405))
        self.assertEqual(self.upstream_calls, [])

    def test_share_forwards_only_query_and_upstream_failure_hides_key(self):
        token = f"Bearer {self._token()}"
        status, _, _ = self.proxy.handle(
            "POST",
            "/klipy/v1/gifs/share/one-piece-zoro",
            token,
            b'{"q":"zoro"}',
        )
        self.assertEqual(status, 200)
        url, method, body = self.upstream_calls[-1]
        self.assertEqual(urlsplit(url).path, "/api/v1/server-only-test-key/gifs/share/one-piece-zoro")
        self.assertEqual(method, "POST")
        self.assertEqual(json.loads(body), {"q": "zoro"})

        self.proxy.upstream = self._upstream
        status, _, error = self.proxy.handle(
            "GET",
            "/klipy/v1/gifs/search?q=upstream-error",
            token,
            b"",
        )
        self.assertEqual(status, 502)
        self.assertNotIn(b"server-only-test-key", error)

    def test_user_request_limit_stops_upstream_calls(self):
        token = f"Bearer {self._token()}"
        for _ in range(120):
            status, _, _ = self.proxy.handle(
                "GET", "/klipy/v1/gifs/search?q=cat", token, b""
            )
            self.assertEqual(status, 200)
        status, _, _ = self.proxy.handle(
            "GET", "/klipy/v1/gifs/search?q=cat", token, b""
        )
        self.assertEqual(status, 429)
        self.assertEqual(len(self.upstream_calls), 120)

    def test_http_handler_rejects_oversized_request_body(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
        server.proxy = self.proxy
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        connection = HTTPConnection("127.0.0.1", server.server_address[1], timeout=2)
        try:
            connection.request(
                "POST",
                "/klipy/v1/gifs/share/one-piece-zoro",
                body=b"x" * 1025,
                headers={"Content-Type": "application/json"},
            )
            response = connection.getresponse()
            self.assertEqual(response.status, 413)
            response.read()
        finally:
            connection.close()
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_additional_authority_requires_its_own_bound_public_key(self):
        vps = "https://sb.AniAura.online/auth/v1"
        other = ec.generate_private_key(ec.SECP256R1())
        vps_jwk = json.loads(jwt.algorithms.ECAlgorithm.to_jwk(other.public_key()))
        vps_jwk.update(kid="vps-key", alg="ES256", issuer=vps)
        cloud_jwk = json.loads(self.jwks_path.read_text())["keys"][0]
        cloud_jwk["issuer"] = ISSUER
        self.jwks_path.write_text(json.dumps({"keys": [cloud_jwk, vps_jwk]}))
        self.proxy = KlipyProxy("test", ISSUER, self.jwks_path,
                                upstream=self._upstream, additional_issuer=vps)
        claims = jwt.decode(self._token(), options={"verify_signature": False})
        good = jwt.encode({**claims, "iss": vps}, other, algorithm="ES256", headers={"kid": "vps-key"})
        bad = [self._token(iss=vps), jwt.encode(claims, other, algorithm="ES256", headers={"kid": "vps-key"}),
               jwt.encode({**claims, "iss": "https://unknown.invalid/auth/v1"}, other, algorithm="ES256", headers={"kid": "vps-key"})]
        for token, expected in [(self._token(), 200), (good, 200), *[(x, 401) for x in bad]]:
            with self.subTest(expected=expected):
                status, _, _ = self.proxy.handle("GET", "/klipy/v1/gifs/search?q=cat", "Bearer " + token, b"")
                self.assertEqual(status, expected)
        self.assertEqual(len(self.upstream_calls), 2)

    def test_additional_authority_is_not_implicitly_trusted(self):
        vps = "https://sb.AniAura.online/auth/v1"
        jwk = json.loads(self.jwks_path.read_text())["keys"][0]
        jwk["issuer"] = vps
        self.jwks_path.write_text(json.dumps({"keys": [jwk]}))
        status, _, _ = self.proxy.handle("GET", "/klipy/v1/gifs/search?q=cat", "Bearer " + self._token(iss=vps), b"")
        self.assertEqual(status, 401)


if __name__ == "__main__":
    unittest.main()
