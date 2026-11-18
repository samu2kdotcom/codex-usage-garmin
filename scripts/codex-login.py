#!/usr/bin/env python3
"""Login OAuth PROPIO del reloj para Codex Usage (solo stdlib).

Crea una sesión INDEPENDIENTE de la CLI de Codex: NO lee ni toca
~/.codex/auth.json (refrescar esos tokens rotaría su refresh token y rompería
esa sesión). Contrato: SPEC.md, "Autenticación".

Dos métodos:

  1) Device code (POR DEFECTO). Exige el ajuste "inicio de sesión con código de
     dispositivo" activo en los ajustes de seguridad de ChatGPT:
       1. POST .../deviceauth/usercode  -> device_auth_id + user_code
       2. Abres https://auth.openai.com/codex/device y tecleas el user_code
       3. Poll .../deviceauth/token cada `interval` s -> code + code_verifier
       4. Canje form-urlencoded en /oauth/token

  2) --pkce (PKCE S256; sirve desde OTRO dispositivo, p. ej. el móvil):
       - La URL de autorización solo admite redirect_uri
         http://localhost:1455/auth/callback (allowlist de la CLI de Codex;
         si 1455 está ocupado se escucha en 1457 y se avisa).
       - El código se captura por DOS vías en paralelo: el servidor local
         /auth/callback (navegador en ESTE equipo) o pegando la URL final de
         redirección (navegador en otro equipo: no alcanza localhost, pero la
         barra de direcciones conserva ?code=&state=). También vale "code#state".

Ambos métodos guardan {access_token, refresh_token, expires_at, account_id,
id_token} en ~/.secrets/codex_watch.json (0600; ~/.secrets 0700), que luego
hornea scripts/bake-personal.sh. NUNCA imprime tokens.

Uso:
  scripts/codex-login.py              # login por device code (interactivo)
  scripts/codex-login.py --pkce       # login PKCE (localhost:1455 o pegar la URL)
  scripts/codex-login.py --refresh    # rota el refresh y actualiza el fichero

El fichero se puede mover con CODEX_WATCH_TOKENS (ruta alternativa).
"""
import argparse
import base64
import hashlib
import json
import os
import queue
import secrets
import stat
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"          # público, sin secreto
DEVICE_USERCODE_URL = "https://auth.openai.com/api/accounts/deviceauth/usercode"
DEVICE_TOKEN_URL = "https://auth.openai.com/api/accounts/deviceauth/token"
VERIFY_URL = "https://auth.openai.com/codex/device"
AUTHORIZE_URL = "https://auth.openai.com/oauth/authorize"
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

# PKCE: la CLI de Codex solo tiene en la allowlist localhost:1455 (y 1457 como
# fallback histórico del propio CLI). Otro puerto = redirect_uri rechazado.
PKCE_TIMEOUT_S = 900            # ≤ 15 min, igual que el device flow
PKCE_PORTS = (1455, 1457)
PKCE_CALLBACK_PATH = "/auth/callback"
SCOPE = "openid profile email offline_access"
PKCE_HINT = (
    "SUGERENCIA: si el código de dispositivo está desactivado en tu cuenta\n"
    "(ajustes de seguridad de ChatGPT), usa el flujo PKCE, que funciona desde\n"
    "otro dispositivo:  scripts/codex-login.py --pkce")
# Marcadores del aviso de política (device code desactivado por la cuenta).
POLICY_MARKERS = (
    "device code login", "device_code_login", "enable device code",
    "device code is disabled", "deviceauth_disabled",
    "código de dispositivo", "codigo de dispositivo",
    "security settings", "ajustes de seguridad",
)


def pkce_hint() -> str:
    return "\n" + PKCE_HINT


def policy_notice(data: dict) -> bool:
    """¿La respuesta es el aviso de 'device code desactivado por política'?"""
    try:
        text = json.dumps(data, ensure_ascii=False).lower()
    except Exception:
        text = str(data).lower()
    return any(m in text for m in POLICY_MARKERS)


def b64url_decode(raw: str) -> bytes:
    pad = "=" * (-len(raw) % 4)
    return base64.urlsafe_b64decode(raw + pad)


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def pkce_pair():
    """verifier aleatorio (64 car.) + challenge = base64url(sha256(verifier))."""
    verifier = b64url(secrets.token_bytes(48))
    challenge = b64url(hashlib.sha256(verifier.encode("ascii")).digest())
    return verifier, challenge


def build_authorize_url(challenge: str, state: str, redirect_uri: str) -> str:
    q = {
        "response_type": "code",
        "client_id": CLIENT_ID,
        "redirect_uri": redirect_uri,
        "scope": SCOPE,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "state": state,
        "id_token_add_organizations": "true",
        "codex_cli_simplified_flow": "true",
        "originator": "codex_cli_rs",
    }
    return AUTHORIZE_URL + "?" + urllib.parse.urlencode(
        q, quote_via=urllib.parse.quote)


def parse_pasted(text: str):
    """(code, state) de una URL de redirección, 'code#state' o un code suelto.

    El usuario del MÓVIL abre la URL en su navegador: la conexión a localhost
    falla, pero la barra de direcciones conserva
    http://localhost:1455/auth/callback?code=…&state=…, que es lo que pega.
    """
    text = text.strip().strip("'\"").strip()
    if not text:
        return "", ""
    if "://" in text or text.lower().startswith("localhost"):
        url = text if "://" in text else "http://" + text
        try:
            q = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
        except ValueError:
            return "", ""
        return (q.get("code") or [""])[0], (q.get("state") or [""])[0]
    if "#" in text:                       # convención de claude-login.py
        code, _, st = text.partition("#")
        return code.strip(), st.strip()
    return text, ""


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


def net_err(e: BaseException) -> str:
    """Fallo de red en UNA línea legible (URLError/timeout ya son OSError)."""
    reason = getattr(e, "reason", None) or e
    text = str(reason).strip().splitlines()
    return text[0] if text else e.__class__.__name__


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
    """Escritura atómica: temporal en el MISMO directorio + os.replace (0600).

    Un crash a mitad no debe dejar el fichero vacío: es el único sitio donde
    vive el refresh token válido.
    """
    d = os.path.dirname(path) or "."
    os.makedirs(d, mode=0o700, exist_ok=True)
    os.chmod(d, 0o700)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".codex_watch.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(doc, f)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, stat.S_IRUSR | stat.S_IWUSR)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    try:                       # que el rename también llegue al disco
        dfd = os.open(d, os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    except OSError:
        pass


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
    try:
        status, d = post_json(DEVICE_USERCODE_URL, {"client_id": CLIENT_ID})
    except OSError as e:
        sys.exit("ERROR: no se pudo contactar con el device flow: " + net_err(e)
                 + pkce_hint())
    if status != 200:
        msg = "ERROR: device flow no disponible: " + explain(status, d)
        if status in (403, 404) or policy_notice(d):
            msg += pkce_hint()
        sys.exit(msg)
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
        try:
            status, d = post_json(DEVICE_TOKEN_URL,
                                  {"device_auth_id": dev_id, "user_code": user_code})
        except OSError as e:
            # Fallo transitorio (URLError, timeout, DNS): se reintenta dentro
            # del deadline en vez de abortar con traceback.
            print("AVISO: fallo de red temporal (%s); reintentando…" % net_err(e),
                  file=sys.stderr)
            continue
        if status == 200:
            credited = d
            break
        if status in (403, 404, 400, 428):
            if policy_notice(d):
                sys.exit("ERROR: la cuenta tiene el device code DESACTIVADO "
                         "(política de ChatGPT)." + pkce_hint())
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
    try:
        status, tok = post_form(TOKEN_URL, {
            "grant_type": "authorization_code",
            "client_id": CLIENT_ID,
            "code": code,
            "redirect_uri": REDIRECT_URI,
            "code_verifier": verifier,
        })
    except OSError as e:
        # El código es de un solo uso: no se reintenta, pero sin traceback.
        sys.exit("ERROR: canje fallido por la red: " + net_err(e))
    if status != 200:
        sys.exit("ERROR: canje rechazado: " + explain(status, tok))
    save(tok, {})


def _callback_handler(state: str, deliver) -> type:
    """Handler de GET /auth/callback. `deliver(("ok", code))` /
    `deliver(("fatal", motivo))`; sin code= se ignora y el servidor sigue."""
    page = ("<!doctype html><meta charset=utf-8><title>Codex Usage</title>"
            "<body style='font-family:sans-serif;padding:2rem'>%s</body>")

    class CallbackHandler(BaseHTTPRequestHandler):
        def _page(self, status: int, msg: str):
            body = (page % msg).encode()
            try:
                self.send_response(status)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(body)
            except OSError:
                pass                    # el navegador colgó: da igual

        def do_GET(self):               # noqa: N802 (API de http.server)
            u = urllib.parse.urlparse(self.path)
            if u.path != PKCE_CALLBACK_PATH:
                self._page(404, "Ruta desconocida.")
                return
            q = urllib.parse.parse_qs(u.query)
            code = (q.get("code") or [""])[0]
            st = (q.get("state") or [""])[0]
            if not code:
                # Sin code (p. ej. ?error=access_denied): no se aborta, el
                # servidor sigue escuchando y el pegado sigue disponible.
                self._page(400, "Falta el parámetro code; el login sigue "
                                "esperando en la terminal.")
                print("AVISO: callback sin code= en la URL; se ignora.",
                      file=sys.stderr)
                return
            if st != state:
                self._page(400, "El state no coincide. Login cancelado.")
                deliver(("fatal", "el state del callback no coincide; "
                                  "posible callback ajeno. Repite --pkce."))
                return
            self._page(200, "Puedes cerrar esta pestaña y volver a la terminal.")
            deliver(("ok", code))

        def log_message(self, *a):      # sin ruido en stderr
            pass

    return CallbackHandler


def _bind_callback(state: str, deliver):
    """HTTPServer en 127.0.0.1:1455 (o 1457) -> (server, puerto) o (None, None)."""
    last = None
    for port in PKCE_PORTS:
        try:
            srv = HTTPServer(("127.0.0.1", port),
                             _callback_handler(state, deliver))
        except OSError as e:            # EADDRINUSE / permisos
            last = e
            continue
        return srv, port
    print("AVISO: no pude escuchar en %s (%s); queda solo pegar la URL."
          % (" ni ".join(str(p) for p in PKCE_PORTS), net_err(last)),
          file=sys.stderr)
    return None, None


def login_pkce() -> None:
    """Flujo PKCE de la CLI de Codex: servidor local + pegar la URL final."""
    verifier, challenge = pkce_pair()
    state = b64url(secrets.token_bytes(24))
    results = queue.Queue()
    lock = threading.Lock()
    fired = [False]

    def deliver(ev: tuple) -> None:
        with lock:
            if fired[0]:
                return
            fired[0] = True
        results.put(ev)

    srv, port = _bind_callback(state, deliver)
    if port is None:
        port = PKCE_PORTS[0]            # inalcanzable, pero es el de la allowlist
    elif port != PKCE_PORTS[0]:
        print("AVISO: el puerto %d está ocupado; escucho en %d. En el navegador "
              "la URL acaba en :%d (la allowlist solo admite %s)."
              % (PKCE_PORTS[0], port, port,
                 " o ".join(str(p) for p in PKCE_PORTS)), file=sys.stderr)
    redirect_uri = "http://localhost:%d%s" % (port, PKCE_CALLBACK_PATH)

    print("Login PKCE de ChatGPT/Codex (sesión propia del reloj, no la CLI).")
    print("1) Abre esta URL (no es secreta) e inicia sesión:\n")
    print(build_authorize_url(challenge, state, redirect_uri), "\n")
    print("2a) Si abres la URL en ESTE equipo, el navegador te devolverá solo:")
    print("    «Puedes cerrar esta pestaña».\n")
    print("2b) Si la abres en el MÓVIL (u otro equipo), el navegador fallará al")
    print("    conectar con localhost: copia la URL completa de la barra de")
    print("    direcciones (empieza por %s?code=…) y pégala aquí:" % redirect_uri)
    print("Esperando el código (máx. %d min)…" % (PKCE_TIMEOUT_S // 60))

    if srv is not None:
        threading.Thread(target=srv.serve_forever, daemon=True).start()

    def paste_loop() -> None:
        while not fired[0]:
            try:
                line = input("   > ")
            except (EOFError, OSError):
                return                  # stdin cerrado: queda el servidor local
            if fired[0]:
                return
            code, st = parse_pasted(line)
            if not code:
                print("AVISO: no encuentro code= en lo pegado; pégalo otra vez "
                      "o pulsa Ctrl-C.", file=sys.stderr)
                continue
            if st and st != state:
                deliver(("fatal", "el state de lo pegado no coincide con el de "
                                  "este login; repite --pkce."))
                return
            deliver(("ok", code))

    threading.Thread(target=paste_loop, daemon=True).start()

    code = None
    deadline = time.time() + PKCE_TIMEOUT_S
    while code is None:
        remaining = deadline - time.time()
        if remaining <= 0:
            sys.exit("ERROR: tiempo agotado esperando el código (%d min)."
                     % (PKCE_TIMEOUT_S // 60))
        try:
            ev = results.get(timeout=remaining)
        except queue.Empty:
            sys.exit("ERROR: tiempo agotado esperando el código (%d min)."
                     % (PKCE_TIMEOUT_S // 60))
        if ev[0] == "fatal":
            sys.exit("ERROR: " + ev[1])
        code = ev[1]

    print("Código recibido; canjeando…")
    try:
        status, tok = post_form(TOKEN_URL, {
            "grant_type": "authorization_code",
            "client_id": CLIENT_ID,
            "code": code,
            "redirect_uri": redirect_uri,
            "code_verifier": verifier,
        })
    except OSError as e:
        # El código es de un solo uso: no se reintenta, pero sin traceback.
        sys.exit("ERROR: canje fallido por la red: " + net_err(e))
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
        description="Login propio del reloj para Codex Usage: device code "
                    "(por defecto) o --pkce.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__)
    ap.add_argument("--pkce", action="store_true",
                    help="método 2: PKCE S256 por localhost:1455 (o 1457), o "
                         "pegando la URL final; sirve desde el móvil")
    ap.add_argument("--refresh", action="store_true",
                    help="rota el refresh token y actualiza el fichero de sesión")
    args = ap.parse_args()
    if args.refresh and args.pkce:
        ap.error("--refresh y --pkce no se combinan")
    if args.refresh:
        refresh()
    elif args.pkce:
        login_pkce()
    else:
        login()


if __name__ == "__main__":
    main()
