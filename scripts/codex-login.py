#!/usr/bin/env python3
"""Login OAuth PROPIO del reloj para Codex Usage (device code, solo stdlib).

Crea una sesión INDEPENDIENTE de la CLI de Codex: NO lee ni toca
~/.codex/auth.json (refrescar esos tokens rotaría su refresh token y rompería
esa sesión). Contrato: SPEC.md, "Autenticación · Vía 1".

  1. POST .../deviceauth/usercode  -> device_auth_id + user_code
  2. Abres https://auth.openai.com/codex/device y tecleas el user_code
  3. Poll .../deviceauth/token cada `interval` s -> code + code_verifier
  4. Canje form-urlencoded en /oauth/token

Guarda {access_token, refresh_token, expires_at, account_id, id_token} en
~/.secrets/codex_watch.json (0600; ~/.secrets 0700), que luego hornea
scripts/bake-personal.sh. NUNCA imprime tokens.

Uso:
  scripts/codex-login.py              # login por device code (interactivo)
  scripts/codex-login.py --refresh    # rota el refresh y actualiza el fichero

El fichero se puede mover con CODEX_WATCH_TOKENS (ruta alternativa).
"""
import argparse
import base64
import json
import os
import stat
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"          # público, sin secreto
DEVICE_USERCODE_URL = "https://auth.openai.com/api/accounts/deviceauth/usercode"
DEVICE_TOKEN_URL = "https://auth.openai.com/api/accounts/deviceauth/token"
VERIFY_URL = "https://auth.openai.com/codex/device"
TOKEN_URL = "https://auth.openai.com/oauth/token"
REDIRECT_URI = "https://auth.openai.com/deviceauth/callback"
STORE = os.environ.get("CODEX_WATCH_TOKENS") or os.path.expanduser(
    "~/.secrets/codex_watch.json")
# UA propio en TODAS las peticiones: Cloudflare (auth.openai.com) responde 403
# a User-Agent genéricos como curl/* o reqwest/*.
UA = "CodexUsageGarmin/0.3"
DEVICE_TIMEOUT_S = 900          # ≤ 15 min (SPEC)
DEFAULT_INTERVAL_S = 5
DEFAULT_LIFE_S = 3600           # access token JWT ~1 h


def b64url_decode(raw: str) -> bytes:
    pad = "=" * (-len(raw) % 4)
    return base64.urlsafe_b64decode(raw + pad)


def parse_json(raw: bytes) -> dict:
    try:
        data = json.loads(raw.decode() or "{}")
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


def post_json(url: str, body: dict, timeout: int = 30):
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(), method="POST",
        headers={"Content-Type": "application/json", "Accept": "application/json",
                 "User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, parse_json(r.read())
    except urllib.error.HTTPError as e:
        return e.code, parse_json(e.read())


def post_form(url: str, fields: dict, timeout: int = 30):
    req = urllib.request.Request(
        url, data=urllib.parse.urlencode(fields).encode(), method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded",
                 "Accept": "application/json", "User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, parse_json(r.read())
    except urllib.error.HTTPError as e:
        return e.code, parse_json(e.read())


def explain(status: int, data: dict) -> str:
    """HTTP + código/mensaje del error (nunca incluye tokens)."""
    err = data.get("error") if isinstance(data, dict) else None
    if isinstance(err, dict):
        err = err.get("code") or err.get("message") or err.get("type")
    return "HTTP %d" % status + (": %s" % err if err else "")


def as_int(v, default: int) -> int:
    try:
        return int(v)
    except (TypeError, ValueError):
        return default


def account_id_from_id_token(id_token: str) -> str:
    """chatgpt_account_id del claim https://api.openai.com/auth (o "")."""
    if not id_token or id_token.count(".") < 2:
        return ""
    try:
        payload = parse_json(b64url_decode(id_token.split(".")[1]))
    except Exception:
        return ""
    auth = payload.get("https://api.openai.com/auth")
    if isinstance(auth, dict):
        return str(auth.get("chatgpt_account_id") or auth.get("account_id") or "")
    return ""


def write_private(path: str, doc: dict) -> None:
    d = os.path.dirname(path)
    os.makedirs(d, mode=0o700, exist_ok=True)
    os.chmod(d, 0o700)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(doc, f)
    os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)


def save(tok: dict, old: dict) -> None:
    """Persiste la sesión. Llamar ANTES de usar el access token: el refresh
    token rota y es de un solo uso (SPEC.md, "Refresco")."""
    access = tok.get("access_token")
    if not access:
        sys.exit("ERROR: la respuesta no trae access_token.")
    refresh = tok.get("refresh_token") or old.get("refresh_token")
    if not refresh:
        sys.exit("ERROR: la respuesta no trae refresh_token.")
    id_token = tok.get("id_token") or old.get("id_token") or ""
    account_id = (tok.get("account_id") or old.get("account_id")
                  or account_id_from_id_token(id_token))
    exp = int(time.time()) + as_int(tok.get("expires_in"), DEFAULT_LIFE_S)
    doc = {
        "access_token": access,
        "refresh_token": refresh,
        "expires_at": exp,
        "account_id": account_id,
        "id_token": id_token,
    }
    write_private(STORE, doc)
    when = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(exp))
    print("OK: sesión guardada en %s (0600); access caduca %s" % (STORE, when))
    if not account_id:
        print("AVISO: sin account_id (llegará en la primera respuesta de uso).",
              file=sys.stderr)


def login() -> None:
    status, d = post_json(DEVICE_USERCODE_URL, {"client_id": CLIENT_ID})
    if status != 200:
        sys.exit("ERROR: device flow no disponible: " + explain(status, d))
    dev_id = d.get("device_auth_id")
    user_code = d.get("user_code")
    if not dev_id or not user_code:
        sys.exit("ERROR: respuesta de device code incompleta.")
    interval = as_int(d.get("interval"), DEFAULT_INTERVAL_S)
    if interval < 1:
        interval = DEFAULT_INTERVAL_S
    if interval > 30:
        interval = 30

    print("Login de ChatGPT/Codex (sesión propia del reloj, no la CLI).")
    print("1) Abre %s en cualquier navegador:" % VERIFY_URL)
    print("2) Teclea el código:", user_code)
    print("Esperando la autorización (máx. %d min)…" % (DEVICE_TIMEOUT_S // 60))

    deadline = time.time() + DEVICE_TIMEOUT_S
    credited = None
    while time.time() < deadline:
        time.sleep(interval)
        status, d = post_json(DEVICE_TOKEN_URL,
                              {"device_auth_id": dev_id, "user_code": user_code})
        if status == 200:
            credited = d
            break
        if status in (403, 404, 400, 428):
            continue                      # pendiente: el usuario aún no autorizó
        if status == 429:
            time.sleep(interval)
            continue
        sys.exit("ERROR: poll rechazado: " + explain(status, d))
    if credited is None:
        sys.exit("ERROR: tiempo agotado esperando la autorización.")

    code = credited.get("authorization_code")
    verifier = credited.get("code_verifier")
    if not code or not verifier:
        sys.exit("ERROR: el servidor no devolvió authorization_code/code_verifier.")
    status, tok = post_form(TOKEN_URL, {
        "grant_type": "authorization_code",
        "client_id": CLIENT_ID,
        "code": code,
        "redirect_uri": REDIRECT_URI,
        "code_verifier": verifier,
    })
    if status != 200:
        sys.exit("ERROR: canje rechazado: " + explain(status, tok))
    save(tok, {})


def refresh() -> None:
    try:
        with open(STORE) as f:
            cur = json.load(f)
    except Exception:
        sys.exit("ERROR: no hay sesión en %s; ejecuta el login primero." % STORE)
    rt = cur.get("refresh_token")
    if not rt:
        sys.exit("ERROR: el fichero de sesión no tiene refresh_token.")
    status, tok = post_json(TOKEN_URL, {
        "grant_type": "refresh_token",
        "client_id": CLIENT_ID,
        "refresh_token": rt,
    })
    if status != 200:
        sys.exit("ERROR: refresh rechazado: " + explain(status, tok))
    save(tok, cur)      # persiste el refresh nuevo ANTES de cualquier uso


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Login propio del reloj (device code) para Codex Usage.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__)
    ap.add_argument("--refresh", action="store_true",
                    help="rota el refresh token y actualiza el fichero de sesión")
    args = ap.parse_args()
    if args.refresh:
        refresh()
    else:
        login()


if __name__ == "__main__":
    main()
