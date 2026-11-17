# SPEC — Codex Usage (widget Garmin Connect IQ)

Widget que muestra en el reloj el uso de tu cuenta **ChatGPT**: límites de
**Codex**, chat y demás superficies, ventanas y **restablecimientos**,
también en el tier gratuito. Boilerplate de origen: `../claude-usage` (que a
su vez proviene de `../nan-usage`): misma arquitectura, navegación y ciclo de
red/batería.

Idioma de la UI: **español**.

## Estado (2026-11-17): SCAFFOLD

La app compila y el modo `DEMO=1` funciona. **Auth y fuente de datos son aún
el contrato de Claude**, copiado como placeholder en `source/CodexAuth.mc`,
`source/UsageStore.mc`, `scripts/codex-login.py` y `scripts/check-usage.sh`
(marcados con "PLACEHOLDER — CONTRATO SIN SUSTITUIR").

**No hacer login real (autenticaría contra Claude), no hornear tokens ni
publicar builds hasta sustituirlos.**

## Fuente de datos — PENDIENTE DE VERIFICAR

Endpoint de uso de la cuenta ChatGPT: ventanas activas, resets y desglose por
producto (chat, codex…), disponible también en tier free. Al cerrarse la
investigación, este apartado fija: endpoint, cabeceras, shape del JSON y
semántica de cada campo. Plantilla de cliente: `scripts/check-usage.sh`.

## Autenticación — PENDIENTE DE VERIFICAR

Login con la cuenta ChatGPT (OAuth PKCE estilo CLI de Codex, auth.openai.com).
Al fijarse: client_id, URLs, scope, rotación del refresh token y cabeceras
posteriores. El reloj tiene su propio login: **nunca** reutilizar los tokens
de `~/.codex/auth.json` de la CLI (rotaría el refresh y rompería esa sesión).

## Pantallas

Mismas que claude-usage (glance, uso, semana, superficies, proyecciones de
ritmo, actividad, reinicios), adaptando etiquetas y cálculos al shape real
de la API cuando se cierre el contrato.

## Branding — TODO

- Isotipo/launcher: `tools/gen_logo.py` + `tools/claude-symbol.svg` generan
  aún el spark de Claude; sustituir por marca Codex.
- Paleta y tipografía: `Skin.mc`, `Theme.mc` y `tools/gen_fonts.py` siguen con
  la piel de claude.ai; sustituir por la de ChatGPT/Codex.
- Capturas: regenerar con `tools/marketing_shots.py` cuando haya branding y
  datos reales (o demo) propios.
