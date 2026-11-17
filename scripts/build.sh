#!/usr/bin/env bash
#
# scripts/build.sh [deviceId] [output.prg]
#
# Compila Codex Usage con monkeyc para un dispositivo (por defecto fr955).
#   deviceId    : id de ~/.Garmin/ConnectIQ/Devices/ (fr955, fr965, fr265, fenix7, ...)
#   output.prg  : opcional; por defecto bin/CodexUsage.prg
#
# Entorno:
#   CONNECTIQ_SDK  raíz del SDK. Si no está: ~/.Garmin/ConnectIQ/current-sdk.cfg
#                  (lo escribe el SDK Manager) o el SDK más nuevo de ~/.Garmin/ConnectIQ/Sdks.
#   DEVKEY         clave de firma DER (por defecto ./devkey.der; nunca se versiona).
#   DEMO=1         compila con datos de ejemplo (demo.jungle) -> bin/CodexUsage.demo.prg
#                  (sin red ni login; para capturas con scripts/ui-shot.sh).
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CIQ_HOME="${HOME:-$(cd ~ && pwd)}/.Garmin/ConnectIQ"

die() { echo "ERROR: $*" >&2; exit 1; }

case "${1:-}" in -h|--help) sed -n '3,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
[ $# -le 2 ] || die "uso: scripts/build.sh [deviceId] [output.prg]"

DEVICE_ID="${1:-fr955}"
JUNGLE="$ROOT/monkey.jungle"
if [ "${DEMO:-0}" = "1" ]; then
    JUNGLE="$ROOT/monkey.jungle;$ROOT/demo.jungle"
    OUTPUT="${2:-$ROOT/bin/CodexUsage.demo.prg}"
else
    OUTPUT="${2:-$ROOT/bin/CodexUsage.prg}"
fi
case "$OUTPUT" in /*) ;; *) OUTPUT="$PWD/$OUTPUT" ;; esac
DEVKEY="${DEVKEY:-$ROOT/devkey.der}"

SDK="${CONNECTIQ_SDK:-}"
[ -z "$SDK" ] || [ -x "$SDK/bin/monkeyc" ] || die "CONNECTIQ_SDK='$SDK' no contiene bin/monkeyc."
if [ -z "$SDK" ] && [ -f "$CIQ_HOME/current-sdk.cfg" ]; then
    SDK="$(head -n1 "$CIQ_HOME/current-sdk.cfg")"
    SDK="${SDK%/}"
fi
if [ -z "$SDK" ] || [ ! -d "$SDK" ]; then
    SDK="$(ls -d "$CIQ_HOME"/Sdks/connectiq-sdk-lin-* 2>/dev/null | sort | tail -n1 || true)"
fi
[ -n "$SDK" ] && [ -x "$SDK/bin/monkeyc" ] \
    || die "no encuentro el SDK de Connect IQ (define CONNECTIQ_SDK; ver DESARROLLO.md)."
[ -d "$CIQ_HOME/Devices/$DEVICE_ID" ] \
    || die "dispositivo '$DEVICE_ID' no está en $CIQ_HOME/Devices (descárgalo con el SDK Manager)."
[ -f "$DEVKEY" ] || die "falta la clave de firma '$DEVKEY' (ver DESARROLLO.md)."
command -v java >/dev/null 2>&1 || die "falta Java (17+): monkeyc lo necesita."

mkdir -p "$(dirname "$OUTPUT")"
echo "== Build CodexUsage ($DEVICE_ID) =="
echo "   SDK:    $SDK"
echo "   Salida: $OUTPUT"

if "$SDK/bin/monkeyc" -f "$JUNGLE" -d "$DEVICE_ID" \
        -w -l 2 -O2 -y "$DEVKEY" -o "$OUTPUT"; then
    echo "BUILD SUCCESSFUL: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
else
    rc=$?
    rm -f "$OUTPUT"
    die "monkeyc devolvió $rc."
fi
