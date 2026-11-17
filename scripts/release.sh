#!/usr/bin/env bash
#
# scripts/release.sh <tag> [notas.md]
#
# Compila TODOS los productos del manifest (mismo set que NaN Usage) a
# exports/release/CodexUsage-<deviceId>.prg, comprueba que ningún .prg lleva
# tokens y publica la release <tag> en GitHub con esos binarios.
#   - Sin notas: crea la release con la tabla de relojes (estilo nan-usage).
#   - Si la release ya existe, sustituye los .prg (--clobber).
#   - DRY=1: solo compila y verifica, no publica.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die() { echo "ERROR: $*" >&2; exit 1; }

[ $# -ge 1 ] && [ $# -le 2 ] || die "uso: scripts/release.sh <tag> [notas.md]"
TAG="$1"
NOTES="${2:-}"
REPO="samu2kdotcom/codex-usage-garmin"
OUT="$ROOT/exports/release"

PRODUCTS=$(sed -n 's/.*<iq:product id="\([^"]*\)".*/\1/p' "$ROOT/manifest.xml")
[ -n "$PRODUCTS" ] || die "no hay <iq:product> en manifest.xml"

# properties.xml debe estar vacío: un build de release nunca lleva tokens.
grep -qE '<property id="(refresh|access)_token" type="string">[^<]+' "$ROOT/resources/properties/properties.xml" \
    && die "properties.xml tiene un token horneado: restaura el fichero antes de publicar."

rm -rf "$OUT"; mkdir -p "$OUT"
for d in $PRODUCTS; do
    log=$("$ROOT/scripts/build.sh" "$d" "$OUT/CodexUsage-$d.prg" 2>&1) || { echo "$log" >&2; die "falla el build de $d"; }
    echo "$log" | grep -q WARNING && { echo "$log" | grep WARNING >&2; die "warnings en $d"; }
    echo "OK  $d  $(du -h "$OUT/CodexUsage-$d.prg" | cut -f1)"
done
rm -rf "$OUT"/*.debug.xml "$OUT"/gen "$OUT"/mir "$OUT"/internal-mir

if grep -lE 'sk-ant-(oat|ort)' "$OUT"/*.prg >/dev/null 2>&1; then
    die "algún .prg contiene un token: no se publica."
fi

[ "${DRY:-0}" = "1" ] && { echo "DRY=1: no se publica."; exit 0; }

if [ -z "$NOTES" ]; then
    NOTES="$(mktemp)"
    cat > "$NOTES" <<'EOF'
### Instalar o actualizar

Descarga el `.prg` de tu reloj, conéctalo por USB (modo MTP) y cópialo a `GARMIN/APPS/` como `CodexUsage.prg`. Al desconectar se instala. La sesión guardada se mantiene.

| Archivo | Reloj |
| --- | --- |
| `CodexUsage-fr955.prg` | Forerunner 955 / 955 Solar |
| `CodexUsage-fr965.prg` | Forerunner 965 |
| `CodexUsage-fr970.prg` | Forerunner 970 |
| `CodexUsage-fr255.prg` | Forerunner 255 |
| `CodexUsage-fr255m.prg` | Forerunner 255 Music |
| `CodexUsage-fr265.prg` | Forerunner 265 |
| `CodexUsage-fenix7.prg` | fēnix 7 / 7 Sapphire |
| `CodexUsage-fenix7s.prg` | fēnix 7S / 7S Sapphire |
| `CodexUsage-fenix7x.prg` | fēnix 7X / 7X Sapphire |
EOF
fi

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release upload "$TAG" "$OUT"/CodexUsage-*.prg --repo "$REPO" --clobber
else
    gh release create "$TAG" "$OUT"/CodexUsage-*.prg --repo "$REPO" \
        --title "Codex Usage $TAG" --notes-file "$NOTES"
fi
gh release view "$TAG" --repo "$REPO" --json assets --jq '.assets[].name'
