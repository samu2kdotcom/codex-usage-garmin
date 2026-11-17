# Codex Usage

Widget Garmin que muestra en el reloj el uso de tu cuenta **ChatGPT**: límites
de **Codex**, chat y demás superficies, ventanas y restablecimientos — también
en el tier gratuito. Sin abrir el móvil.

> Proyecto personal y **no oficial**: no está afiliado a OpenAI. El logo y la
> marca ChatGPT/Codex son de OpenAI.

**Estado: en desarrollo (scaffold).** Estructura, pantallas y ciclo de
red/batería portados de
[claude-usage-garmin](https://github.com/samu2kdotcom/claude-usage-garmin)
(boilerplate de origen). El login con la cuenta ChatGPT y la fuente de datos
están en curso: el código de red lleva aún el contrato de Claude como
placeholder marcado `PLACEHOLDER — CONTRATO SIN SUSTITUIR` (ver
[SPEC.md](SPEC.md)). El modo `DEMO=1` ya funciona con datos de ejemplo, y el
branding (logo, paleta, tipografía) está pendiente de sustituir.

## Compilar

```bash
scripts/build.sh [deviceId]    # fr955 por defecto -> bin/CodexUsage.prg
DEMO=1 scripts/build.sh fr955  # -> bin/CodexUsage.demo.prg (datos de ejemplo)
```

Productos: fr955/965/970, fr255/255m/265, fēnix 7/7S/7X. Firmar con tu
`devkey.der` (symlink a la clave del monorepo; no se versiona).
