#!/usr/bin/env python3
"""Tiny 3x-ui panel API helper (local only, 127.0.0.1). Reads the login from secrets/panel.env; never prints it.

3x-ui v3 needs a CSRF token: GET <base>/csrf-token -> {"obj": token}, sent as X-CSRF-Token on every POST
(the token is re-fetched after login because the session changes).

As a module:   import api; api.login(); api.req("/panel/api/inbounds/list")
From a shell:  api.py get  /panel/api/inbounds/list
               api.py post /panel/api/inbounds/add '<json>'      (JSON body)
               api.py form /panel/setting/all                     (form/empty POST)
Env: XUI_ROOT (default: this file's dir), XUI_PANEL_PORT (default 20530), XUI_BASE_URL (overrides both host+port).
"""
import http.cookiejar
import json
import os
import sys
import urllib.parse
import urllib.request

R = os.environ.get("XUI_ROOT") or os.path.dirname(os.path.abspath(__file__))
env = dict(l.strip().split("=", 1) for l in open(os.path.join(R, "secrets", "panel.env")) if "=" in l)
_base = os.environ.get("XUI_BASE_URL", "http://127.0.0.1:" + os.environ.get("XUI_PANEL_PORT", "20530"))
BASE = (_base.rstrip("/") + "/" + env.get("XUI_PATH", "/").strip("/")).rstrip("/")
cj = http.cookiejar.CookieJar()
op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))
op.addheaders = [("User-Agent", "Mozilla/5.0 (X11; Linux x86_64) xui-local-helper")]
CSRF = [None]


def csrf():
    r = op.open(BASE + "/csrf-token", timeout=20)
    CSRF[0] = json.loads(r.read().decode())["obj"]


def req(path, data=None, js=False, method=None):
    if CSRF[0] is None:
        csrf()
    if js:
        body = json.dumps(data).encode()
        h = {"Content-Type": "application/json"}
    else:
        body = urllib.parse.urlencode(data).encode() if data is not None else None
        h = {}
    h["X-CSRF-Token"] = CSRF[0]
    h["X-Requested-With"] = "XMLHttpRequest"
    m = method or ("POST" if body is not None or path.endswith("/all") else "GET")   # v3: GET .../inbounds/list, POST /panel/setting/all
    r = op.open(urllib.request.Request(BASE + path, data=body, headers=h, method=m), timeout=20)
    t = r.read().decode()
    try:
        return json.loads(t)
    except Exception:
        return t


def login():
    j = req("/login", {"username": env["XUI_USER"], "password": env["XUI_PASS"]})
    assert isinstance(j, dict) and j.get("success"), "login failed: " + str(j.get("msg") if isinstance(j, dict) else j)[:200]
    csrf()
    return j


if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[1] not in ("get", "post", "form"):
        print(__doc__.strip()); sys.exit(2)
    login()
    verb, path = sys.argv[1], sys.argv[2]
    arg = sys.argv[3] if len(sys.argv) > 3 else None
    if verb == "get":
        out = req(path, method="GET")
    elif verb == "post":
        out = req(path, json.loads(arg) if arg else {}, js=True, method="POST")
    else:
        out = req(path, dict(urllib.parse.parse_qsl(arg)) if arg else None, method="POST")
    print(json.dumps(out, ensure_ascii=False, indent=1) if not isinstance(out, str) else out)
