# SPEC — Codex Usage (widget Garmin Connect IQ)

Widget que muestra en el reloj el uso de tu cuenta **ChatGPT**: límites de
**Codex** (ventanas de 5 h y semanal, un único pool compartido con el chat
desde diciembre), límites por feature (`additional_rate_limits`), créditos y
**restablecimientos** — también en el tier gratuito (solo ventana semanal).
Boilerplate de origen: `../claude-usage` (que a su vez proviene de
`../nan-usage`): misma arquitectura, navegación y ciclo de red/batería.

Idioma de la UI: **español**.

## Estado (2026-11-18): CONTRATO CERRADO, implementación en curso

OAuth y fuente de datos fijados por investigación contra el código de
Codex (`github.com/openai/codex`) y payloads reales documentados (fuentes al
final). Queda **validación con cuenta real** (§ "Pendiente de verificar"):
login por portátil → volcado de una cuenta free y una Plus → congelar shapes
→ bake + sideload para probar el GET desde el reloj. Mientras tanto, el modo
`DEMO=1` funciona con datos de ejemplo del contrato nuevo.

Vías de login por prioridad: **(1)** device code por portátil
(`scripts/codex-login.py`) + `bake-personal.sh` — la segura; **(2)** login en
el reloj (experimento, § Autenticación). **Nunca** reutilizar los tokens de
`~/.codex/auth.json` de la CLI (rotaría el refresh y rompería esa sesión).

## Fuente de datos

### `GET https://chatgpt.com/backend-api/wham/usage`

Cabeceras:

| Header | Valor |
|---|---|
| `Authorization` | `Bearer <access_token>` |
| `Accept` | `application/json` |
| `User-Agent` | `CodexUsageGarmin/<ver>` (nunca `curl/*` ni `reqwest/*`: Cloudflare responde 403) |
| `originator` | `codex_cli_rs` (allowlist de primera parte) |
| `chatgpt-account-id` | `<account_id>` cuando se conozca; **se aprende del body de la primera respuesta** y se persiste |

Respuesta (recortada, campos útiles):

```jsonc
{
  "user_id": "user-…", "account_id": "…", "email": "…",
  "plan_type": "plus",                  // guest|free|go|plus|pro|prolite|promax|team|business|…
  "rate_limit": {
    "allowed": true, "limit_reached": false,
    "primary_window": {
      "used_percent": 6,               // % USADO (no restante); clamp 0..100
      "limit_window_seconds": 18000,   // 18000 = 5 h · 604800 = 7 d
      "reset_after_seconds": 13140,
      "reset_at": 1782770922 },        // epoch segundos
    "secondary_window": { … o null } },
  "code_review_rate_limit": { "primary_window": { … } },   // opcional
  "additional_rate_limits": [                               // opcional (Spark, etc.)
    { "limit_name": "GPT-Codex-Spark", "metered_feature": "codex_spark_preview",
      "rate_limit": { "primary_window": {…}, "secondary_window": {…} } } ],
  "credits": { "has_credits": false, "unlimited": false, "balance": null,
               "overage_limit_reached": false },
  "spend_control": { "reached": false, "individual_limit": { "limit":"2400",
                     "used":"1434.58", "used_percent": 60, "reset_at": 1789000000,
                     "reset_after_seconds": 11831 } },
  "rate_limit_reset_credits": { "available_count": 2 }
}
```

Reglas de interpretación:

- **Clasificar ventanas por `limit_window_seconds`, no por posición**:
  `primary` puede ser la semanal (free y Team). 5 h = 18000; semanal = 604800;
  otras duraciones → página de "otros límites".
- `used_percent` es **% usado**; `allowed:false` manda sobre los porcentajes.
- `reset_at` no es un calendario fijo: no prometer "cada 7 días".
- **Tier free**: solo ventana semanal; sin créditos ni resets; la UI no debe
  asumir sesión de 5 h (un solo anillo).
- **No hay desglose chat vs codex** (pool compartido); lo más cercano es
  `additional_rate_limits[]` por feature/modelo.
- `plan_type`: enum del cliente
  (`codex-rs/codex-backend-openapi-models/.../rate_limit_status_payload.rs`).

### `GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits`

```jsonc
{ "available_count": 2, "total_earned_count": 0,
  "credits": [
    { "id": "RateLimitResetCredit_…", "reset_type": "codex_rate_limits",
      "status": "available",                 // solo ofrecer "available"
      "granted_at": "2026-06-18T00:33:49.661454Z",   // RFC3339
      "expires_at": "2026-07-18T00:33:49.661454Z",   // ~30 días desde concesión
      "title": "Full reset (Weekly + 5 hr)", "description": "…" } ] }
```

- `available_count` es autoritativo (también llega inline en `/wham/usage`);
  `credits[]` puede venir truncado. Equivalente de los `cedar_ember.grants`
  de Claude. En free: esperar `available_count: 0`.

## Autenticación (OAuth de ChatGPT)

Constantes verificadas en `codex-rs/login`:

```
CLIENT_ID       = "app_EMoamEEZ73f0CkXaXp7hrann"   (público, sin secreto)
AUTHORIZE_URL   = "https://auth.openai.com/oauth/authorize"
TOKEN_URL       = "https://auth.openai.com/oauth/token"
REVOKE_URL      = "https://auth.openai.com/oauth/revoke"
SCOPE           = "openid profile email offline_access"   (separado por espacios; encodeURL)
```

### Vía 1 — device code (portátil, RECOMENDADA; la v1)

1. `POST https://auth.openai.com/api/accounts/deviceauth/usercode`
   JSON `{"client_id": CLIENT_ID}` → `{"device_auth_id","user_code","interval"}`
   (interval puede venir como string).
2. El usuario visita `https://auth.openai.com/codex/device` y teclea el
   `user_code`.
3. Poll `POST …/api/accounts/deviceauth/token` JSON
   `{"device_auth_id","user_code"}` cada `interval` s (≤15 min);
   403/404 = pendiente; 200 → `{"authorization_code","code_challenge","code_verifier"}`
   (el servidor devuelve el verifier).
4. Canje `POST {TOKEN_URL}` **form-urlencoded**:
   `grant_type=authorization_code&client_id=…&code=…&redirect_uri=https://auth.openai.com/deviceauth/callback&code_verifier=…`
   → `{id_token, access_token, refresh_token}`.

`scripts/codex-login.py` implementa esto y guarda
`{access_token, refresh_token, expires_at, account_id, id_token}` en
`~/.secrets/codex_watch.json` (0600); `bake-personal.sh` los hornea en
`properties.xml` y `CodexAuth.seed()` los siembra si Storage está vacío.

### Refresco (crítico)

`POST {TOKEN_URL}` **JSON** (no form): `{"grant_type":"refresh_token",
"client_id":…, "refresh_token":…}` → `{"access_token","refresh_token"?,"id_token"?}`.
**El refresh token rota y es de un solo uso** (errores `refresh_token_reused`,
`refresh_token_expired`, `refresh_token_invalidated`): persistir el nuevo
**antes** de usar el access token (patrón `storeTokens` de claude-usage).
Access token JWT ~1 h: guardar `expires_in` si viene; si no, `exp = now+3600`;
`401 ⇒ un refresh + un reintento`. Logout: `POST /oauth/revoke`.

### Vía 2 — login en el reloj (EXPERIMENTAL, posterior)

`makeOAuthRequest` con `redirect_uri=http://localhost:1455/auth/callback`
(allowlist Hydra de la CLI) y `codex_cli_simplified_flow=true`: la doc de
Garmin espera `http://localhost`; hay precedente de path propio
(`github.com/garmin/connectiq-apps/issues/30`) pero **puerto no verificado**.
1 prueba lo decide; si OpenAI rechaza el redirect, no hay workaround.

## Instantánea (Storage, claves `cx_*`)

| clave | contenido | origen |
|---|---|---|
| `"s"` | `{"p","r","sv"}` sesión 5 h (puede faltar en free) | ventana `18000` |
| `"w"` | `{"p","r","sv"}` semanal | ventana `604800` |
| `"o"` | Array `{"n","p","r","sec"}` otras ventanas | resto de duraciones |
| `"a"` | Array `{"n","p","r","sec"}` límites adicionales | `additional_rate_limits[]` (`n`=limit_name) |
| `"cr"` | `{"p","r"}` code review | `code_review_rate_limit` |
| `"g"` | Array `{"id","l","t","e","st"}` resets disponibles | `/wham/rate-limit-reset-credits` |
| `"x"` | `{"on","bal","unl","rc","sc","scp","scr"}` créditos + spend control | `credits`+`spend_control` |
| `"pl"` | String `plan_type` | fila de plan |
| `"al"` | Boolean `rate_limit.allowed` | estado autoritativo |
| `"aid"` | String `account_id` | header de las llamadas |

## Pantallas

Mismas que claude-usage con este mapeo:

- **Uso**: anillo de la sesión 5 h (o de la semanal en free), hora de
  reinicio, límite semanal compacto y fila de plan ("Plus", "Free"…).
- **Semana**: barra de la ventana 604800 y reset.
- **Otros límites** (antes "Superficies"): `additional_rate_limits[]`,
  code review y otras ventanas (`"o"`): nombre + % + reset.
- **Sesión · 5 h / Semana · 7 d**: proyecciones de ritmo (`UsageMath`, igual).
- **Actividad**: histórico de muestras (igual).
- **Reinicios**: reset credits disponibles con caducidad (solo lectura).
- **Créditos** (fila en Uso): balance y spend control si existen.

## Riesgos

1. **Cloudflare (alto)**: `chatgpt.com/backend-api` y `auth.openai.com`
   bloquean UA genéricos (`curl/*`, `reqwest/*` → 403 challenge). Mitigación:
   `originator: codex_cli_rs`, UA propio o de navegador, `Accept: json`,
   403 con HTML ⇒ mensaje "Bloqueado (Cloudflare)" y backoff largo, sin
   bucle. Las peticiones del reloj salen por el móvil (IP residencial).
2. **API interna sin documentar**: sin garantía de compatibilidad; aislar el
   parseo en `UsageStore.mc` y degradar con mensajes claros.
3. **Refresh de un solo uso**: persistir el nuevo antes de nada.
4. `chatgpt-account-id` parece opcional para cuentas personales; mandarlo
   siempre que se conozca (aprendido de la primera respuesta).
5. Redirect de la CLI clavado a `localhost:1455/1457` → login en el reloj
   sin verificar (Vía 2).

## Pendiente de verificar (con cuenta real)

1. ¿`makeWebRequest` a `/wham/usage` pasa Cloudflare desde Garmin Connect (sin
   cookies, UA custom)? Mirar código HTTP y si el body es HTML.
2. ¿El device flow está habilitado para todas las cuentas y `interval` llega
   como número o string?
3. ¿El refresh devuelve `expires_in` y siempre `refresh_token` nuevo?
4. Shape exacto en **free** (¿`rate_limit` no nulo siempre? ¿`credits`?) y si
   `/wham/rate-limit-reset-credits` responde 200 con `available_count:0`.
5. ¿`chatgpt-account-id` es opcional para cuentas personales?
6. Valores reales de `limit_name`/`metered_feature` hoy (¿solo Spark?).

**Plan de validación**: (1) `scripts/codex-login.py` en el portátil → tokens;
(2) `scripts/check-usage.sh --raw` con una cuenta free y una Plus → congelar
shapes (ajustar este SPEC); (3) `bake-personal.sh` + `sideload.sh` → probar
el GET desde el reloj; (4) solo si (3) funciona, intentar la Vía 2.

## Branding — EN CURSO (lane aparte)

- Isotipo/launcher: `tools/gen_logo.py` + `tools/claude-symbol.svg` generan
  aún el spark de Claude; sustitución en curso.
- Paleta y tipografía: `Skin.mc`, `Theme.mc` y `tools/gen_fonts.py` siguen con
  la piel de claude.ai; sustitución en curso.
- Capturas: regenerar con `tools/marketing_shots.py` cuando haya branding y
  datos (o demo) propios.

## Fuentes

- Código de primera parte: `github.com/openai/codex` — `codex-rs/login/src/{server.rs,auth/manager.rs,device_code_auth.rs,oauth/client.rs}`
  (CLIENT_ID, redirect 1455/1457 "Keep in sync with the Codex CLI Hydra
  redirect URI allow-list", refresh JSON vs canje form, rotación con
  `refresh_token_reused`), `codex-rs/backend-client/src/{client/rate_limit_resets.rs,types.rs}`
  (`wham/rate-limit-reset-credits`), `codex-rs/http-client/src/{openai_headers.rs,chatgpt_cloudflare_cookies.rs}`
  (`chatgpt-account-id`, cookies CF).
- Payloads reales: gist `monperrus/21dc7d85…` (reset_at desplazable),
  `github.com/nguyenphutrong/quotio/issues/356` (free: semanal en
  `primary_window`), `github.com/can1357/oh-my-pi/issues/7617` (`allowed`
  manda), `github.com/zlliang/pi-spark` y `github.com/suasgn/openburn`
  (reset credits), `codex-rs/codex-backend-openapi-models` (enum plan_type).
- Límites free/pool compartido: `help.openai.com/en/articles/20001625`
  y `11369540`, `www.codexusage.dev/limits/free`.
- Cloudflare: `github.com/openclaw/openclaw/issues/94432` + PR 95150,
  `github.com/openai/codex/issues/{21735,18456,17860}`.
- Device flow en terceros: `github.com/BerriAI/litellm` (chatgpt common_utils),
  `github.com/badlogic/pi-mono` (openai-codex.ts).
- Garmin: `developer.garmin.com/connect-iq/core-topics/authenticated-web-services/`,
  `github.com/garmin/connectiq-apps/issues/30`.
