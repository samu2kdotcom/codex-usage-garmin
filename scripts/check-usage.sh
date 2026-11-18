#!/usr/bin/env bash
#
# scripts/check-usage.sh [--raw]
#
# GET de los dos endpoints del SPEC ("Fuente de datos") con la sesión de
# ~/.secrets/codex_watch.json (login propio: scripts/codex-login.py):
#   /wham/usage                  -> plan, ventanas, límites adicionales, créditos
#   /wham/rate-limit-reset-credits -> reinicios disponibles (solo "available")
#
# Cabeceras del SPEC: Authorization Bearer, Accept json, originator
# codex_cli_rs, User-Agent propio (Cloudflare rechaza UA genéricos) y
# chatgpt-account-id cuando se conoce. --raw vuelca los dos JSON completos;
# sin él, resume en texto. NUNCA imprime el token.
#
set -euo pipefail

STORE="${CODEX_WATCH_TOKENS:-${HOME:-$(cd ~ && pwd)}/.secrets/codex_watch.json}"
USAGE_URL="https://chatgpt.com/backend-api/wham/usage"
RESETS_URL="https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"

case "${1:-}" in
    -h|--help) sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    ""|--raw) ;;
    *) echo "uso: scripts/check-usage.sh [--raw]" >&2; exit 2 ;;
esac
[ -f "$STORE" ] || { echo "ERROR: falta $STORE (ejecuta scripts/codex-login.py)." >&2; exit 1; }

RAW="${1:-}" STORE="$STORE" USAGE_URL="$USAGE_URL" RESETS_URL="$RESETS_URL" python3 - <<'PY'
import json, os, sys, time, urllib.error, urllib.request

store = os.environ["STORE"]
try:
    tok = json.load(open(store))
except Exception:
    sys.exit("ERROR: no se puede leer %s." % store)
access = tok.get("access_token") or ""
if not access:
    sys.exit("ERROR: el fichero de sesión no tiene access_token.")
if (tok.get("expires_at") or 0) - time.time() < 60:
    sys.exit("ERROR: access token caducado; ejecuta scripts/codex-login.py --refresh")

base = {
    "Authorization": "Bearer " + access,
    "Accept": "application/json",
    "originator": "codex_cli_rs",
    "User-Agent": "CodexUsageGarmin/0.3",
}
account_id = tok.get("account_id") or ""
if account_id:
    base["chatgpt-account-id"] = account_id


def get(url):
    req = urllib.request.Request(url, headers=base)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def kind(sec):
    if sec == 18000:
        return "5 h"
    if sec == 604800:
        return "7 d"
    if isinstance(sec, int) and sec > 0:
        if sec % 86400 == 0:
            return "%d d" % (sec // 86400)
        if sec % 3600 == 0:
            return "%d h" % (sec // 3600)
        if sec % 60 == 0:
            return "%d min" % (sec // 60)
        return "%d s" % sec
    return "?"


def window(name, w, auto=False):
    if not isinstance(w, dict):
        return
    sec = w.get("limit_window_seconds")
    if auto:
        name = "sesión" if sec == 18000 else ("semana" if sec == 604800 else "ventana")
    reset = w.get("reset_at")
    when = time.strftime("%Y-%m-%d %H:%M", time.localtime(reset)) if reset else "-"
    print("%-10s %-5s %4s %% usado  reset %s"
          % (name, kind(sec), w.get("used_percent"), when))


url_hint = os.environ["USAGE_URL"]
status, body = get(url_hint)
if status != 200:
    hint = " (¿Cloudflare? el body no es JSON)" if status == 403 else ""
    sys.exit("ERROR: /wham/usage HTTP %d%s" % (status, hint))
try:
    usage = json.loads(body)
except Exception:
    sys.exit("ERROR: /wham/usage HTTP 200 con body no JSON.")
account_id = usage.get("account_id") or account_id

rstatus, rbody = get(os.environ["RESETS_URL"])
resets = None
if rstatus == 200:
    try:
        resets = json.loads(rbody)
    except Exception:
        resets = None

if os.environ.get("RAW") == "--raw":
    print(json.dumps(usage, indent=2, ensure_ascii=False))
    if resets is None:
        print("(rate-limit-reset-credits: HTTP %d)" % rstatus, file=sys.stderr)
    else:
        print(json.dumps(resets, indent=2, ensure_ascii=False))
    sys.exit(0)

rl = usage.get("rate_limit") or {}
print("plan: %s   allowed: %s   cuenta: %s"
      % (usage.get("plan_type") or "-", rl.get("allowed"),
         "ok" if account_id else "desconocida"))
window("", rl.get("primary_window"), True)
window("", rl.get("secondary_window"), True)
extra = usage.get("additional_rate_limits") or []
for item in extra:
    if not isinstance(item, dict):
        continue
    sub = item.get("rate_limit") or {}
    label = item.get("limit_name") or item.get("metered_feature") or "extra"
    for key in ("primary_window", "secondary_window"):
        if sub.get(key):
            window(label, sub.get(key))
cr = (usage.get("code_review_rate_limit") or {}).get("primary_window")
if cr:
    window("code review", cr)

credits = usage.get("credits") or {}
spend = usage.get("spend_control") or {}
limit = spend.get("individual_limit") or {}
print("créditos: has=%s unlimited=%s balance=%s overage=%s"
      % (credits.get("has_credits"), credits.get("unlimited"),
         credits.get("balance"), credits.get("overage_limit_reached")))
if limit:
    print("spend control: reached=%s %s %% (limit %s, used %s)"
          % (spend.get("reached"), limit.get("used_percent"),
             limit.get("limit"), limit.get("used")))

inline = (usage.get("rate_limit_reset_credits") or {}).get("available_count")
if resets is None:
    print("reinicios disponibles: %s (detalle no disponible)" % inline)
    sys.exit(0)
print("reinicios disponibles: %s" % resets.get("available_count"))
for c in resets.get("credits") or []:
    if not isinstance(c, dict) or c.get("status") != "available":
        continue
    print("  - %s  caduca %s" % (c.get("title") or c.get("reset_type"),
                                 (c.get("expires_at") or "-")[:10]))
PY
