#!/usr/bin/env python3
"""Login OAuth PROPIO del reloj para Codex Usage (PKCE S256, solo stdlib).

PLACEHOLDER — CONTRATO SIN SUSTITUIR: AUTHORIZE_URL, TOKEN_URL, REDIRECT_URI y
CLIENT_ID son aún los de Claude (copiados de ../claude-usage). NO sirve para
un login real de ChatGPT hasta sustituirlos por el flujo auth.openai.com del
SPEC.md.

Cuando el contrato sea el de ChatGPT: esto crea una sesión nueva,
independiente de la CLI de Codex. NO reutiliza ni toca ~/.codex/auth.json
(refrescar esos tokens rotaría el refresh token y rompería esa sesión).

Uso:
  scripts/codex-login.py              # login interactivo: abre la URL, pega code#state
  scripts/codex-login.py --refresh    # refresca (rota) los tokens guardados
  scripts/codex-login.py --print-url  # solo genera y muestra URL + verifier de prueba (sin red)

Guarda {access_token, refresh_token, expires_at, scope} en
~/.secrets/codex_watch.json (0600; ~/.secrets 0700). Nunca imprime tokens.
"""
import argparse
import base64
import hashlib
import json
import os
import secrets
import stat
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
AUTHORIZE_URL = "https://claude.com/cai/oauth/authorize"
TOKEN_URL = "https://platform.claude.com/v1/oauth/token"
REDIRECT_URI = "https://platform.claude.com/oauth/code/callback"
SCOPE = "user:profile"
LONG_EXPIRES = 31536000
STORE = os.path.expanduser("~/.secrets/codex_watch.json")
UA = "codex-usage-watch-login/1.0"


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def pkce():
    verifier = b64url(secrets.token_bytes(48))          # 64 caracteres
    challenge = b64url(hashlib.sha256(verifier.encode("ascii")).digest())
    return verifier, challenge


def build_url(challenge: str, state: str) -> str:
    q = {
        "code": "true",
        "client_id": CLIENT_ID,
        "response_type": "code",
        "redirect_uri": REDIRECT_URI,
        "scope": SCOPE,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "state": state,
    }
    return AUTHORIZE_URL + "?" + urllib.parse.urlencode(q, quote_via=urllib.parse.quote)


def post_token(body: dict):
    req = urllib.request.Request(
        TOKEN_URL, data=json.dumps(body).encode(), method="POST",
        headers={"Content-Type": "application/json", "Accept": "application/json",
                 "User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        try:
            data = json.loads(e.read().decode() or "{}")
        except Exception:
            data = {}
        return e.code, data


def save(resp: dict, old_refresh: str = ""):
    if not resp.get("access_token"):
        sys.exit("ERROR: la respuesta no trae access_token.")
    refresh = resp.get("refresh_token") or old_refresh
    if not refresh:
        sys.exit("ERROR: la respuesta no trae refresh_token.")
    doc = {
        "access_token": resp["access_token"],
        "refresh_token": refresh,
        "expires_at": int(time.time()) + int(resp.get("expires_in") or 3600),
        "scope": resp.get("scope") or SCOPE,
    }
    d = os.path.dirname(STORE)
    os.makedirs(d, mode=0o700, exist_ok=True)
    os.chmod(d, 0o700)
    fd = os.open(STORE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(doc, f)
    os.chmod(STORE, stat.S_IRUSR | stat.S_IWUSR)
    exp = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(doc["expires_at"]))
    print(f"OK: tokens guardados en {STORE} (0600). scope={doc['scope']} caduca={exp}")


def explain(status, data):
    err = data.get("error") if isinstance(data, dict) else None
    if isinstance(err, dict):
        err = err.get("message") or err.get("type")
    return f"HTTP {status}" + (f" ({err})" if err else "")


def login():
    verifier, challenge = pkce()
    state = b64url(secrets.token_bytes(24))
    print("Login propio del reloj (no es el de Claude Code).")
    print("1) Abre esta URL (no es secreta), inicia sesión y autoriza:\n")
    print(build_url(challenge, state), "\n")
    pasted = input("2) Pega el código que muestra la página (code#state): ").strip()
    code, _, st = pasted.partition("#")
    if not code:
        sys.exit("ERROR: código vacío.")
    if st and st != state:
        sys.exit("ERROR: el state no coincide; repite el login.")
    body = {
        "grant_type": "authorization_code", "code": code, "state": st or state,
        "client_id": CLIENT_ID, "redirect_uri": REDIRECT_URI,
        "code_verifier": verifier, "expires_in": LONG_EXPIRES,
    }
    status, data = post_token(body)
    if status == 400:
        body.pop("expires_in")
        status, data = post_token(body)
    if status != 200:
        sys.exit("ERROR: canje rechazado: " + explain(status, data))
    save(data)


PENDING = os.path.expanduser("~/.secrets/codex_login_pending.json")


def write_private(path: str, doc: dict):
    d = os.path.dirname(path)
    os.makedirs(d, mode=0o700, exist_ok=True)
    os.chmod(d, 0o700)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(doc, f)


def start():
    """Fase 1 (sin terminal interactiva): guarda verifier/state y muestra la URL."""
    verifier, challenge = pkce()
    state = b64url(secrets.token_bytes(24))
    write_private(PENDING, {"verifier": verifier, "state": state, "t": int(time.time())})
    print("Abre esta URL (no es secreta), inicia sesión, autoriza y copia el código (code#state):\n")
    print(build_url(challenge, state))


def finish(code_file: str):
    """Fase 2: lee code#state de un fichero (nunca de argv) y canjea."""
    try:
        with open(PENDING) as f:
            pend = json.load(f)
    except Exception:
        sys.exit(f"ERROR: no hay login pendiente en {PENDING}; ejecuta --start.")
    with open(code_file) as f:
        pasted = f.read().strip()
    code, _, st = pasted.partition("#")
    if not code:
        sys.exit("ERROR: código vacío.")
    if st and st != pend["state"]:
        sys.exit("ERROR: el state no coincide; repite --start.")
    body = {
        "grant_type": "authorization_code", "code": code, "state": pend["state"],
        "client_id": CLIENT_ID, "redirect_uri": REDIRECT_URI,
        "code_verifier": pend["verifier"], "expires_in": LONG_EXPIRES,
    }
    status, data = post_token(body)
    if status == 400:
        body.pop("expires_in")
        status, data = post_token(body)
    if status != 200:
        sys.exit("ERROR: canje rechazado: " + explain(status, data))
    save(data)
    os.remove(PENDING)


def refresh():
    try:
        with open(STORE) as f:
            cur = json.load(f)
    except Exception:
        sys.exit(f"ERROR: no hay tokens en {STORE}; ejecuta el login primero.")
    rt = cur.get("refresh_token", "")
    status, data = post_token({"grant_type": "refresh_token", "refresh_token": rt,
                               "client_id": CLIENT_ID, "scope": SCOPE})
    if status != 200:
        sys.exit("ERROR: refresh rechazado: " + explain(status, data))
    save(data, rt)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__.split("\n\n", 1)[1])
    ap.add_argument("--refresh", action="store_true", help="refrescar (rota) los tokens guardados")
    ap.add_argument("--print-url", action="store_true", help="solo mostrar URL de prueba (sin red ni guardar)")
    ap.add_argument("--start", action="store_true",
                    help="fase 1 sin terminal: guarda verifier/state pendientes y muestra la URL")
    ap.add_argument("--finish", metavar="FICHERO",
                    help="fase 2: canjea el code#state leído de FICHERO (no se pasa por argv)")
    a = ap.parse_args()
    if a.start:
        start()
    elif a.finish:
        finish(a.finish)
    elif a.print_url:
        v, c = pkce()
        print(build_url(c, b64url(secrets.token_bytes(24))))
        print(f"(verifier de prueba, {len(v)} car.; no se guarda)", file=sys.stderr)
    elif a.refresh:
        refresh()
    else:
        login()


if __name__ == "__main__":
    main()
