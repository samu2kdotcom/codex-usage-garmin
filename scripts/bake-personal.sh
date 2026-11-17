#!/usr/bin/env bash
#
# scripts/bake-personal.sh [deviceId]      (por defecto fr955)
#
# Build PERSONAL: hornea los tokens de ~/.secrets/codex_watch.json (login
# propio del reloj, scripts/codex-login.py) en las propiedades refresh_token /
# access_token / access_exp de resources/properties/properties.xml, compila a
# bin/CodexUsage.personal.prg y RESTAURA properties.xml siempre (trap).
#
#   - NUNCA imprime tokens (viajan por fichero/entorno dentro de python3).
#   - El .prg resultante lleva el refresh token en claro: NO compartir, NO
#     subir a la tienda, NO versionar (bin/ está fuera de git).
#   - Solo se usan si Storage del reloj no tiene tokens (login propio previo).
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STORE="${CODEX_WATCH_TOKENS:-${HOME:-$(cd ~ && pwd)}/.secrets/codex_watch.json}"
DEVICE_ID="${1:-fr955}"

die() { echo "ERROR: $*" >&2; exit 1; }
case "${1:-}" in -h|--help) sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
[ $# -le 1 ] || die "uso: scripts/bake-personal.sh [deviceId]"
[ -f "$STORE" ] || die "falta $STORE (ejecuta scripts/codex-login.py)."

PROPS="$ROOT/resources/properties/properties.xml"
BAK="$PROPS.bak.$$"
[ -f "$PROPS" ] || die "falta $PROPS."
OUTPUT="$ROOT/bin/CodexUsage.personal.prg"

cp "$PROPS" "$BAK"
restore_props() { cp "$BAK" "$PROPS"; rm -f "$BAK"; }
trap restore_props EXIT INT TERM

STORE="$STORE" python3 - "$PROPS" <<'PY'
import json, os, re, sys
from xml.sax.saxutils import escape

path = sys.argv[1]
tok = json.load(open(os.environ["STORE"]))
vals = {
    "refresh_token": tok.get("refresh_token", ""),
    "access_token": tok.get("access_token", ""),
    "access_exp": str(int(tok.get("expires_at", 0))),
}
if not vals["refresh_token"]:
    sys.exit("ERROR: el fichero de tokens no tiene refresh_token.")
text = open(path, encoding="utf-8").read()
for pid, v in vals.items():
    text, n = re.subn(r'(<property\s+id="%s"[^>]*>)(.*?)(</property>)' % pid,
                      lambda m: m.group(1) + escape(v, {'"': "&quot;"}) + m.group(3),
                      text, flags=re.S)
    if n != 1:
        sys.exit('ERROR: no hay exactamente una <property id="%s"> en %s' % (pid, path))
open(path, "w", encoding="utf-8").write(text)
PY

echo "== Build personal CodexUsage ($DEVICE_ID) =="
echo "   Tokens horneados en properties.xml (valores NO mostrados)."
"$ROOT/scripts/build.sh" "$DEVICE_ID" "$OUTPUT"
echo "Recuerda: este .prg lleva el refresh token en claro. Solo uso personal (sideload)."
