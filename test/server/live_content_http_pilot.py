"""Check the new PostgREST routes with a real test-app JWT over SSH tunnel."""

import json
import subprocess
import urllib.error
import urllib.parse
import urllib.request
import uuid
import xml.etree.ElementTree as ET


BASE_URL = "https://sync.AniAura.online"
PACKAGE = "com.spyou.watch_app.vpstest"
ROUTES = ("reading_history", "profile_reading_history", "viewer_profiles", "backups")


def session():
    xml = subprocess.check_output([
        "adb", "exec-out", "run-as", PACKAGE, "cat",
        "shared_prefs/FlutterSharedPreferences.xml",
    ])
    root = ET.fromstring(xml)
    stored = json.loads(next(
        element.text for element in root
        if "auth-token" in element.attrib.get("name", "")
    ))
    return stored["access_token"], stored["user"]["id"]


def request(route, token=None, method="GET", body=None, filters=None):
    query = "?" + urllib.parse.urlencode(filters) if filters else ""
    headers = {}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if body is not None:
        headers["Content-Type"] = "application/json"
    data = json.dumps(body).encode() if body is not None else None
    call = urllib.request.Request(
        f"{BASE_URL}/{route}{query}", data=data,
        headers=headers, method=method,
    )
    try:
        with urllib.request.urlopen(call, timeout=8) as response:
            return response.status, json.loads(response.read() or b"null")
    except urllib.error.HTTPError as error:
        return error.code, None


def main():
    token, user_id = session()
    for route in ROUTES:
        assert request(route)[0] == 401, route
        assert request(route, "invalid-token")[0] == 401, route
        assert request(route, token)[0] == 200, route
    other = str(uuid.uuid4())
    status, rows = request("viewer_profiles", token,
                           filters={"user_key": f"eq.{other}"})
    assert status == 200 and rows == []
    assert request("backups", token, "POST",
                   {"user_key": other, "payload": "{}"})[0] == 403

    show_id = f"pilot-{uuid.uuid4()}"
    filters = {"user_key": f"eq.{user_id}", "source_id": "eq.pilot",
               "show_id": f"eq.{show_id}"}
    try:
        assert request("reading_history", token, "POST", {
            "user_key": user_id, "source_id": "pilot", "show_id": show_id,
            "title": "Migration test", "updated_ms": 1,
        })[0] in (200, 201)
        status, rows = request("reading_history", token, filters=filters)
        assert status == 200 and len(rows) == 1
    finally:
        assert request("reading_history", token, "DELETE",
                       filters=filters)[0] in (200, 204)
    print("http-pilot-pass: public HTTPS, JWT, ownership, and content write/delete")


if __name__ == "__main__":
    main()
