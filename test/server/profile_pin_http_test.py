"""HTTP checks for a disposable PostgREST instance using a test-only HMAC key."""
import base64
import hashlib
import hmac
import json
import os
import time
import unittest
import urllib.error
import urllib.request


@unittest.skipUnless(os.environ.get("PROFILE_PIN_HTTP_URL") and os.environ.get("PROFILE_PIN_TEST_JWT_SECRET"),
                     "needs disposable PostgREST instance")
class ProfilePinHttpTest(unittest.TestCase):
    def token(self, owner="pin-http-owner"):
        def encode(value):
            return base64.urlsafe_b64encode(value).decode().rstrip("=")
        data = encode(b'{"alg":"HS256","typ":"JWT"}') + "." + encode(json.dumps({
            "sub": owner, "role": "authenticated", "aud": "authenticated",
            "exp": int(time.time()) + 300,
        }).encode())
        signature = hmac.new(os.environ["PROFILE_PIN_TEST_JWT_SECRET"].encode(),
                             data.encode(), hashlib.sha256).digest()
        return data + "." + encode(signature)

    def request(self, path, method="GET", body=None, grants=None, token=None):
        headers = {"authorization": "Bearer " + (token or self.token()), "content-type": "application/json"}
        if grants is not None:
            headers["x-profile-grants"] = json.dumps(grants)
        request = urllib.request.Request(os.environ["PROFILE_PIN_HTTP_URL"] + path,
                                         data=None if body is None else json.dumps(body).encode(),
                                         method=method, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                data = response.read()
                return response.status, json.loads(data) if data else None
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read())

    def rpc(self, action, **params):
        return self.request("/rpc/profile_lock", "POST", {"p_action": action, **params})

    def test_profile_lock_over_real_http_transport(self):
        status, _ = self.request("/rpc/profile_lock", "POST", {"p_action": "status"}, token="invalid")
        self.assertEqual(status, 401)
        status, _ = self.request("/viewer_profiles", "POST", {
            "user_key": "pin-http-owner", "profile_id": "private", "name": "Private",
            "photo_url": "https://avatars.example/avatars/pin-http-owner/private.jpg",
        })
        self.assertEqual(status, 201)
        status, _ = self.request("/profile_history", "POST", {
            "user_key": "pin-http-owner", "profile_id": "private", "source_id": "test", "show_id": "show",
        })
        self.assertEqual(status, 201)
        status, result = self.rpc("set", p_profile_id="private", p_new_pin="1234")
        self.assertEqual(status, 200)
        self.assertTrue(result["ok"])
        recovery = result["recovery_code"]
        self.assertEqual(self.request("/profile_history")[0], 403)
        self.assertEqual(self.request("/viewer_profiles?profile_id=eq.private", "DELETE")[0], 403)
        self.assertEqual(self.rpc("asset_delete_access", p_secret="avatars/pin-http-owner/private.jpg")[0], 403)
        self.assertFalse(self.rpc("unlock", p_profile_id="private", p_pin="0000")[1]["ok"])
        status, unlocked = self.rpc("unlock", p_profile_id="private", p_pin="1234")
        self.assertEqual(status, 200)
        grant = {"private": unlocked["grant_token"]}
        self.assertEqual(len(self.request("/profile_history", grants=grant)[1]), 1)
        self.assertEqual(self.request("/profile_history", grants=grant, token=self.token("other-owner"))[1], [])
        status, _ = self.rpc("set", p_profile_id="private", p_pin="1234", p_new_pin="5678")
        self.assertEqual(status, 200)
        self.assertEqual(self.request("/profile_history", grants=grant)[0], 403)
        self.assertFalse(self.rpc("recover", p_profile_id="private", p_new_pin="9012", p_secret=recovery)[1]["ok"])
        self.assertTrue(self.rpc("remove", p_profile_id="private", p_pin="5678")[1]["ok"])
        self.assertEqual(self.request("/viewer_profiles?profile_id=eq.private", "DELETE")[0], 204)


if __name__ == "__main__":
    unittest.main()
