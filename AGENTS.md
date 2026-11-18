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
  (PKCE, login por Garmin Connect, refresh), `UsageMath.mc` (ritmo).
- `source/Theme.mc`, `Skin.mc`, `Fmt.mc`, `Pages.mc`, `CodexUsageView.mc`,
  `CodexGlanceView.mc`, `Spark.mc` (generado): UI.
- `resources/` comunes; `resources-<ancho>/` fuentes BMFont y launcher icon por
  resolución (asignadas por producto en `monkey.jungle`).
- `tools/gen_fonts.py`, `tools/gen_logo.py`: regeneran fuentes y logo (aún
  los de Claude: ver SPEC.md, Branding).
- `DemoData.mc` + `demo.jungle`: datos de ejemplo (`DEMO=1`), anotación `(:demo)`.

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
