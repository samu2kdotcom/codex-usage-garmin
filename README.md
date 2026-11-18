# Codex Usage

Widget Garmin que muestra en el reloj el uso de tu cuenta **ChatGPT**: límites
de **Codex**, chat y demás superficies, ventanas y restablecimientos — también
en el tier gratuito. Sin abrir el móvil.

> Proyecto personal y **no oficial**: no está afiliado a OpenAI. El logo y la
> marca ChatGPT/Codex son de OpenAI.

**Estado: en desarrollo.** Estructura, pantallas y ciclo de red/batería
portados de
[claude-usage-garmin](https://github.com/samu2kdotcom/claude-usage-garmin)
(boilerplate de origen). El contrato de la API de ChatGPT está cerrado e
implementado ([SPEC.md](SPEC.md)): login por device code en el portátil y
lectura de `chatgpt.com/backend-api/wham/usage` (+ reset credits), con
soporte del tier gratuito (solo ventana semanal). Queda validar con cuenta
real (SPEC.md, "Pendiente de verificar") y el branding (logo, paleta,
tipografía) está en curso. El modo `DEMO=1` funciona con datos de ejemplo del
contrato nuevo.

## Probarlo con tu cuenta

1. `python3 scripts/codex-login.py` — device code: abre
   `https://auth.openai.com/codex/device`, teclea el código que imprime;
   guarda una sesión **independiente** en `~/.secrets/codex_watch.json`
   (no toca la de la CLI de Codex, nunca imprime tokens).
2. `scripts/check-usage.sh [--raw]` — lee los dos endpoints con tu sesión
   (`--raw` vuelca el JSON: contiene email/account_id, no lo pegues en
   sitios públicos).
3. `scripts/bake-personal.sh [deviceId]` → `bin/CodexUsage.personal.prg`
   (lleva la sesión en claro: no compartir) → `scripts/sideload.sh
   bin/CodexUsage.personal.prg` al reloj.

**Trampa del refresh de un solo uso**: nunca ejecutes
`codex-login.py --refresh` después de hornear al reloj — rota el refresh y el
reloj se queda con el muerto (`refresh_token_reused`). Para re-autenticar:
`codex-login.py` (login nuevo) → `bake-personal.sh` → `sideload.sh`, y
reabre el widget una vez para que re-siembre la sesión.

## Compilar

```bash
scripts/build.sh [deviceId]    # fr955 por defecto -> bin/CodexUsage.prg
DEMO=1 scripts/build.sh fr955  # -> bin/CodexUsage.demo.prg (datos de ejemplo)
```

Productos: fr955/965/970, fr255/255m/265, fēnix 7/7S/7X. Firmar con tu
`devkey.der` (symlink a la clave del monorepo; no se versiona).
