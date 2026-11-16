#!/usr/bin/env python3
"""Authenticated, allowlisted KLIPY API proxy for Zangetsu."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import threading
import time
from urllib.error import HTTPError
from urllib.parse import parse_qsl, quote, urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener
import uuid

import jwt
from jwt import PyJWK


KLIPY_API = "https://api.klipy.com/api/v1/"
MAX_BODY_BYTES = 1024
MAX_RESPONSE_BYTES = 2 * 1024 * 1024
MAX_TOKEN_BYTES = 8192
MAX_QUERY_LENGTH = 120
USER_REQUESTS_PER_MINUTE = 120
MAX_TRACKED_USERS = 50_000
ALLOWED_ALGORITHMS = {"ES256": "EC", "RS256": "RSA"}
SLUG = re.compile(r"^[A-Za-z0-9]+(?:-+[A-Za-z0-9]+)*$")


class _Problem(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        return None


class KlipyProxy:
    def __init__(self, api_key, issuer, jwks_path, upstream=None, additional_issuer=None):
        self._api_key = api_key.strip()
        self._issuer = issuer.rstrip("/")
        self._issuers = {self._issuer}
        if additional_issuer:
            self._issuers.add(additional_issuer.rstrip("/"))
        self._jwks_path = Path(jwks_path)
        self.upstream = upstream or self._fetch_upstream
        # shortcut: rate windows reset on restart; use shared storage before adding workers.
        self._rates = {}
        self._rate_lock = threading.Lock()

    @classmethod
    def from_environment(cls):
        credential_dir = os.environ.get("CREDENTIALS_DIRECTORY")
        if not credential_dir:
            raise RuntimeError("systemd API-key credential is unavailable")
        api_key = (Path(credential_dir) / "klipy_api_key").read_text().strip()
        if not api_key:
            raise RuntimeError("systemd API-key credential is empty")
        return cls(
            api_key=api_key,
            issuer=os.environ["SUPABASE_ISSUER"],
            additional_issuer=os.environ.get("VPS_AUTH_ISSUER"),
            jwks_path=os.environ.get(
                "SUPABASE_JWKS_PATH", "/etc/zangetsu-sync/jwks.json"
            ),
        )

    def handle(self, method, target, authorization, body):
        try:
            route = self._route(method, target, body)
            user_id = self._verify_user(authorization)
            if not self._allow_user(user_id):
                return self._json(
                    429, {"error": "Too many requests"}, {"Retry-After": "60"}
                )
            upstream_url, upstream_method, upstream_body = route
            status, response = self.upstream(
                upstream_url, upstream_method, upstream_body
            )
            if status == 429:
                return self._json(429, {"error": "GIF service is busy"})
            if status < 200 or status >= 300:
                return self._json(502, {"error": "GIF service is unavailable"})
            if len(response) > MAX_RESPONSE_BYTES:
                return self._json(502, {"error": "GIF response is too large"})
            if status != 204:
                try:
                    if not isinstance(json.loads(response), dict):
                        raise ValueError("expected JSON object")
                except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
                    return self._json(502, {"error": "Invalid GIF service response"})
            return self._response(status, response)
        except _Problem as problem:
            return self._json(problem.status, {"error": problem.message})
        except Exception:
            return self._json(502, {"error": "GIF service is unavailable"})

    def _route(self, method, target, body):
        if len(target) > 2048:
            raise _Problem(400, "Invalid request")
        parsed = urlsplit(target)
        if parsed.scheme or parsed.netloc or parsed.fragment:
            raise _Problem(400, "Invalid request")
        try:
            pairs = parse_qsl(
                parsed.query, keep_blank_values=True, strict_parsing=True, max_num_fields=4
            )
        except ValueError:
            raise _Problem(400, "Invalid request") from None
        if len({key for key, _ in pairs}) != len(pairs):
            raise _Problem(400, "Invalid request")
        params = dict(pairs)

        if parsed.path == "/klipy/v1/gifs/search":
            self._method(method, "GET")
            self._empty_body(body)
            if set(params) != {"q"}:
                raise _Problem(400, "Invalid search")
            query = self._query(params["q"])
            query_string = urlencode(
                {
                    "q": query,
                    "page": 1,
                    "per_page": 24,
                    "content_filter": "high",
                    "format_filter": "gif",
                }
            )
            return self._url("gifs/search") + "?" + query_string, "GET", None

        if parsed.path == "/klipy/v1/gifs/items":
            self._method(method, "GET")
            self._empty_body(body)
            if set(params) != {"slugs"} or not SLUG.fullmatch(params["slugs"]):
                raise _Problem(400, "Invalid GIF")
            query_string = urlencode(
                {"slugs": params["slugs"], "format_filter": "gif"}
            )
            return self._url("gifs/items") + "?" + query_string, "GET", None

        prefix = "/klipy/v1/gifs/share/"
        if parsed.path.startswith(prefix):
            self._method(method, "POST")
            if params:
                raise _Problem(400, "Invalid share")
            slug = parsed.path[len(prefix) :]
            if not SLUG.fullmatch(slug):
                raise _Problem(400, "Invalid GIF")
            try:
                payload = json.loads(body)
            except (UnicodeDecodeError, json.JSONDecodeError):
                raise _Problem(400, "Invalid share") from None
            if not isinstance(payload, dict) or set(payload) != {"q"}:
                raise _Problem(400, "Invalid share")
            query = self._query(payload["q"])
            encoded = json.dumps({"q": query}, separators=(",", ":")).encode()
            return self._url(f"gifs/share/{slug}"), "POST", encoded

        raise _Problem(404, "Not found")

    @staticmethod
    def _method(actual, expected):
        if actual != expected:
            raise _Problem(405, "Method not allowed")

    @staticmethod
    def _empty_body(body):
        if body:
            raise _Problem(400, "Invalid request")

    @staticmethod
    def _query(value):
        if (
            not isinstance(value, str)
            or not value.strip()
            or len(value) > MAX_QUERY_LENGTH
            or any(ord(char) < 32 for char in value)
        ):
            raise _Problem(400, "Invalid search")
        return value

    def _verify_user(self, authorization):
        if not isinstance(authorization, str) or not authorization.startswith("Bearer "):
            raise _Problem(401, "Sign in to use GIF search")
        token = authorization[7:]
        if not token or len(token) > MAX_TOKEN_BYTES or any(char.isspace() for char in token):
            raise _Problem(401, "Invalid sign-in token")
        try:
            header = jwt.get_unverified_header(token)
        except jwt.PyJWTError:
            raise _Problem(401, "Invalid sign-in token") from None
        algorithm = header.get("alg")
        kid = header.get("kid")
        expected_kty = ALLOWED_ALGORITHMS.get(algorithm)
        if expected_kty is None or not isinstance(kid, str) or not kid or len(kid) > 128:
            raise _Problem(401, "Invalid sign-in token")
        try:
            jwks = json.loads(self._jwks_path.read_text())
            keys = jwks.get("keys") if isinstance(jwks, dict) else None
            if not isinstance(keys, list) or not keys:
                raise ValueError("invalid key set")
            matches = [key for key in keys if isinstance(key, dict) and key.get("kid") == kid]
            if len(matches) != 1:
                raise _Problem(401, "Invalid sign-in token")
            jwk_data = matches[0]
            key_issuer = jwk_data.get("issuer", self._issuer)
            if not isinstance(key_issuer, str) or key_issuer not in self._issuers:
                raise _Problem(401, "Invalid sign-in token")
            if (
                jwk_data.get("kty") != expected_kty
                or jwk_data.get("use", "sig") != "sig"
                or "verify" not in jwk_data.get("key_ops", ["verify"])
                or any(name in jwk_data for name in ("d", "p", "q", "dp", "dq", "qi", "k"))
                or jwk_data.get("alg", algorithm) != algorithm
            ):
                raise _Problem(401, "Invalid sign-in token")
            jwk_data = dict(jwk_data)
            jwk_data["alg"] = algorithm
            key = PyJWK.from_dict(jwk_data, algorithm=algorithm).key
        except _Problem:
            raise
        except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError, jwt.PyJWTError):
            raise _Problem(503, "Sign-in verification is temporarily unavailable") from None
        try:
            claims = jwt.decode(
                token,
                key=key,
                algorithms=[algorithm],
                issuer=key_issuer,
                audience="authenticated",
                options={"require": ["exp", "iat", "sub", "iss", "aud", "role"]},
            )
        except jwt.PyJWTError:
            raise _Problem(401, "Invalid sign-in token") from None
        subject = claims.get("sub")
        try:
            user_id = str(uuid.UUID(subject)) if isinstance(subject, str) else ""
        except ValueError:
            user_id = ""
        if (
            not user_id
            or claims.get("role") != "authenticated"
            or claims.get("is_anonymous") is True
        ):
            raise _Problem(401, "Sign in to use GIF search")
        return user_id

    def _allow_user(self, user_id):
        window = int(time.time() // 60)
        with self._rate_lock:
            current = self._rates.get(user_id)
            if current is None:
                if len(self._rates) >= MAX_TRACKED_USERS:
                    self._rates = {
                        key: value for key, value in self._rates.items() if value[0] == window
                    }
                if len(self._rates) >= MAX_TRACKED_USERS:
                    return False
                self._rates[user_id] = (window, 1)
                return True
            if current[0] != window:
                self._rates[user_id] = (window, 1)
                return True
            if current[1] >= USER_REQUESTS_PER_MINUTE:
                return False
            self._rates[user_id] = (window, current[1] + 1)
            return True

    def _url(self, path):
        return KLIPY_API + quote(self._api_key, safe="") + "/" + path

    @staticmethod
    def _fetch_upstream(url, method, body):
        headers = {
            "Accept": "application/json",
            "User-Agent": "Zangetsu (+https://zangetsu.online)",
        }
        if body is not None:
            headers["Content-Type"] = "application/json"
        request = Request(url, data=body, headers=headers, method=method)
        opener = build_opener(ProxyHandler({}), _NoRedirect())
        try:
            with opener.open(request, timeout=8) as response:
                return response.status, response.read(MAX_RESPONSE_BYTES + 1)
        except HTTPError as error:
            return error.code, error.read(MAX_RESPONSE_BYTES + 1)

    @staticmethod
    def _json(status, value, extra_headers=None):
        body = json.dumps(value, separators=(",", ":")).encode()
        return KlipyProxy._response(status, body, extra_headers)

    @staticmethod
    def _response(status, body, extra_headers=None):
        headers = {
            "Content-Type": "application/json; charset=utf-8",
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
        }
        if extra_headers:
            headers.update(extra_headers)
        return status, headers, body


class _Handler(BaseHTTPRequestHandler):
    server_version = "Zangetsu"
    sys_version = ""

    def do_GET(self):
        self._dispatch()

    def do_POST(self):
        self._dispatch()

    def _dispatch(self):
        if self.headers.get("Transfer-Encoding") is not None:
            self.close_connection = True
            status, headers, body = KlipyProxy._json(400, {"error": "Invalid request"})
        else:
            lengths = self.headers.get_all("Content-Length", [])
            if len(lengths) > 1:
                length = -1
            else:
                try:
                    length = int(lengths[0]) if lengths else 0
                except ValueError:
                    length = -1
            if length < 0:
                self.close_connection = True
                status, headers, body = KlipyProxy._json(400, {"error": "Invalid request"})
            elif length > MAX_BODY_BYTES:
                self.close_connection = True
                status, headers, body = KlipyProxy._json(413, {"error": "Request is too large"})
            else:
                payload = self.rfile.read(length) if length else b""
                authorizations = self.headers.get_all("Authorization", [])
                authorization = authorizations[0] if len(authorizations) == 1 else None
                if len(authorizations) > 1:
                    status, headers, body = KlipyProxy._json(
                        400, {"error": "Invalid request"}
                    )
                else:
                    status, headers, body = self.server.proxy.handle(
                        self.command,
                        self.path,
                        authorization,
                        payload,
                    )
        self.send_response(status)
        for name, value in headers.items():
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def log_message(self, format_string, *args):
        return


def serve():
    proxy = KlipyProxy.from_environment()
    server = ThreadingHTTPServer(("127.0.0.1", 3110), _Handler)
    server.daemon_threads = True
    server.proxy = proxy
    server.serve_forever()


if __name__ == "__main__":
    serve()
