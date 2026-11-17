#!/usr/bin/env bash
#
# scripts/check-usage.sh [--raw]
#
# PLACEHOLDER — CONTRATO SIN SUSTITUIR: el endpoint y cabeceras son aún los de
# la API de Claude (copiados de ../claude-usage); sirve como plantilla del
# cliente para el endpoint de ChatGPT/Codex cuando se cierre en SPEC.md.
#
# Hace el GET del endpoint de uso con el token de ~/.secrets/codex_watch.json
# (login propio del reloj; ver scripts/codex-login.py) y resume el resultado.
# --raw muestra el JSON completo. NUNCA imprime el token.
#
set -euo pipefail

STORE="${CODEX_WATCH_TOKENS:-${HOME:-$(cd ~ && pwd)}/.secrets/codex_watch.json}"
URL="https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1"

case "${1:-}" in -h|--help) sed -n '3,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
[ -f "$STORE" ] || { echo "ERROR: falta $STORE (ejecuta scripts/codex-login.py)." >&2; exit 1; }

RAW="${1:-}" STORE="$STORE" URL="$URL" python3 - <<'PY'
import json, os, sys, time, urllib.error, urllib.request

store, url = os.environ["STORE"], os.environ["URL"]
tok = json.load(open(store))
left = tok.get("expires_at", 0) - time.time()
if left < 60:
    sys.exit("ERROR: access token caducado; ejecuta scripts/codex-login.py --refresh")
req = urllib.request.Request(url, headers={
    "Authorization": "Bearer " + tok["access_token"],
    "anthropic-beta": "oauth-2025-04-20",
    "Accept": "application/json",
    "User-Agent": "codex-usage-watch-check/1.0"})
try:
    with urllib.request.urlopen(req, timeout=30) as r:
        d = json.loads(r.read().decode())
except urllib.error.HTTPError as e:
    sys.exit(f"ERROR: HTTP {e.code}")
if os.environ.get("RAW") == "--raw":
    print(json.dumps(d, indent=2, ensure_ascii=False))
    sys.exit(0)
for l in d.get("limits") or []:
    sc = (l.get("scope") or {}).get("model", {}) or {}
    print(f"{l.get('kind'):14} {l.get('percent')!s:>4}%  {l.get('severity') or '-':9} reset {l.get('resets_at')}  {sc.get('display_name') or ''}")
if not d.get("limits"):
    for k in ("five_hour", "seven_day"):
        v = d.get(k) or {}
        print(f"{k:14} {v.get('utilization')!s:>4}%  reset {v.get('resets_at')}")
for r in (d.get("seven_day_breakdown") or {}).get("rows") or []:
    print(f"  {r.get('display_name')}: {r.get('percent')}%")
g = [x for x in ((d.get("cedar_ember") or {}).get("grants") or []) if (x.get("resets_left") or 0) > 0]
print(f"restablecimientos: {len(g)}")
PY
