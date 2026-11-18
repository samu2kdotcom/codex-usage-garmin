# AGENTS.md — contexto para agentes de código (opencode, omp, …)

**Codex Usage**: widget Garmin Connect IQ (Monkey C) que muestra el uso de tu
cuenta **ChatGPT** (Codex, chat, …) con sus restablecimientos, también en el
tier gratuito. Responde en español. Contrato de datos, API, OAuth y pantallas:
[`SPEC.md`](SPEC.md) (cerrado 2026-11-18; queda validación con cuenta real,
§ "Pendiente de verificar"). Login v1: device code por portátil
(`scripts/codex-login.py`) + `scripts/bake-personal.sh`. Boilerplate de
origen: la app Claude Usage (`../claude-usage` en el monorepo `garminapps`,
que a su vez proviene de `../nan-usage`).

## Estructura

- `source/UsageStore.mc` (red, parseo, caché, histórico), `CodexAuth.mc`
  (tokens OAuth de ChatGPT, refresh, seed desde properties), `UsageMath.mc`
  (ritmo).
- `source/Theme.mc`, `Skin.mc`, `Fmt.mc`, `Pages.mc`, `CodexUsageView.mc`,
  `CodexGlanceView.mc`, `LogoMark.mc` (generado): UI.
- `resources/` comunes; `resources-<ancho>/` fuentes BMFont y launcher icon por
  resolución (asignadas por producto en `monkey.jungle`).
- `tools/gen_fonts.py`, `tools/gen_logo.py`: regeneran fuentes (Geist) y logo
  (blossom de OpenAI; ver SPEC.md, "Branding").
- `DemoData.mc` + `demo.jungle`: datos de ejemplo (`DEMO=1`), anotación `(:demo)`.

## UI (reglas del rediseño)

- **Marca**: el isotipo (blossom) va **solo** en la pantalla Uso, grande
  (34 px sobre base 260, escala con el ancho); las demás páginas llevan solo
  título, con línea base 58. No repetir el isotipo por página ni poner
  "Codex" junto a él. Glance: sin isotipo (el sistema ya pinta el launcher).
- **Filas clave/valor**: `Skin.kvRow` alinea etiqueta y valor por línea base;
  cifras del héroe en Geist Mono (tabulares, "%" en gris), filas alineadas a
  la derecha.
- **Puntos de paginación**: al hueco del anillo, radio 3, 15 px del borde; deben
  dejar ≥ 15 px libres bajo la última fila (en 260 px es lo que los hacía
  pisar "Créditos").
- **Densidad**: "Otros límites" usa bloques de 3 renglones (54 px de paso:
  nombre + %, barra, reinicio tenue); con más de 3, "y N más".
- **Glance** (proceso de 64 KB): 3 renglones clave/valor — Sesión, Semana y
  Restablece; en free solo Semana + Restablece.
- Probar siempre el **caso free** (sin ventana de 5 h): anillo en semanal, sin
  filas de sesión/créditos y estados "Sin ventana de 5 h" / "No tienes
  reinicios disponibles" (comentario de variante en `DemoData.mc`).

## Comandos

```bash
scripts/build.sh [deviceId]            # fr955 por defecto -> bin/CodexUsage.prg
DEMO=1 scripts/build.sh fr955          # -> bin/CodexUsage.demo.prg (capturas)
scripts/sideload.sh bin/CodexUsage.prg
scripts/sideload.sh --pull-logs /tmp/ciq-logs
scripts/release.sh <tag>               # compila los 9 productos y publica la release (DRY=1: no publica)
```

- Verificación mínima: `scripts/build.sh` → `BUILD SUCCESSFUL` sin warnings; si
  tocas UI o recursos, compila también 240/280/416/454 (fenix7s, fenix7x, fr265, fr965).
- La glance corre en un proceso de 64 KB: solo código `(:glance)` y Storage.

## Reglas (no negociables)

- **Nunca** leer, imprimir ni copiar `devkey*`, `*.der`, `*.pem`, `~/.secrets/*`
  (`devkey.der` aquí es un symlink a la clave del monorepo; no se versiona).
- **Nunca** usar ni refrescar los tokens de `~/.codex/auth.json` (CLI de
  Codex): rotaría el refresh token y rompería esa sesión.
- **Nunca** publicar builds ni hornear tokens ajenos hasta validar el
  contrato con una cuenta real (SPEC.md, "Pendiente de verificar"): login
  real SOLO con la sesión propia de la app (`scripts/codex-login.py`).
- **Nunca** ejecutar `scripts/codex-login.py --refresh` si ya se horneó al
  reloj (mismo refresh, un solo uso: el reloj se queda con el muerto y su
  siguiente refresco da `refresh_token_reused`). Re-autenticar = login
  nuevo → `bake-personal.sh` → `sideload.sh`, y reabrir el widget para que
  re-siembre.
- **Nunca** escribir tokens en `properties.xml` versionado ni imprimirlos;
  `scripts/bake-personal.sh` los hornea y restaura el fichero.
- `*.prg`, `*.iq`, `bin/`, `fonts-src/local/` jamás en git. Antes de commit:
  `git status` sin claves, tokens ni binarios.
