using Toybox.Lang;
using Toybox.Application;
using Toybox.Application.Storage;
using Toybox.Communications;
using Toybox.Cryptography;
using Toybox.StringUtil;
using Toybox.System;
using Toybox.Time;

//! Tokens OAuth de ChatGPT/Codex y su refresco (SPEC.md, "Autenticación").
//!
//! v1: la sesión se crea FUERA del reloj (scripts/codex-login.py, device code)
//! y llega horneada por scripts/bake-personal.sh; seed() la siembra en Storage
//! la primera vez. NO se leen ni refrescan los tokens de la CLI de Codex
//! (~/.codex/auth.json): el refresh token rota y rompería esa sesión.
//!
//! El refresh token es de UN SOLO USO: storeTokens() lo persiste en Storage
//! ANTES de devolver el access token (mismo patrón que ../claude-usage). Solo
//! este módulo toca Storage["cx_auth"]. NUNCA se imprimen ni registran tokens.
module CodexAuth {

    const AUTH_KEY = "cx_auth";        // { "access", "refresh", "exp" (epoch) }
    const NOSEED_KEY = "cx_noseed";    // HASH del refresh horneado a no sembrar, o true

    // Constantes de auth.openai.com (codex-rs/login); el client id es público.
    const CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";
    const TOKEN_URL = "https://auth.openai.com/oauth/token";
    const REVOKE_URL = "https://auth.openai.com/oauth/revoke";
    const SKEW_S = 60;                 // refrescar si caduca en < 60 s
    const DEFAULT_LIFE_S = 3600;       // access token JWT ~1 h si no hay expires_in
    // Cloudflare de chatgpt.com/auth.openai.com bloquea UA genéricos
    // (curl/*, reqwest/*): UA propio del reloj en TODAS las peticiones.
    const USER_AGENT = "CodexUsageGarmin/0.3";

    var sAuth as Lang.Dictionary or Null = null;
    var sAuthLoaded as Lang.Boolean = false;
    var sRefreshing as Lang.Boolean = false;
    var sRefreshCbs as Lang.Array = [];

    //! Tipo/mensaje de error de un cuerpo JSON ({"error":"..."} o
    //! {"error":{code,message}}), solo para los logs. Nunca contiene tokens.
    function errType(data as Lang.Object or Null) as Lang.String {
        if (data instanceof Lang.Dictionary) {
            var e = (data as Lang.Dictionary).get("error");
            if (e instanceof Lang.String) {
                return e as Lang.String;
            }
            if (e instanceof Lang.Dictionary) {
                var ed = e as Lang.Dictionary;
                var c = ed.get("code");
                var m = ed.get("message");
                var t = ed.get("type");
                var head = (c instanceof Lang.String) ? c as Lang.String
                    : ((t instanceof Lang.String) ? t as Lang.String : "");
                return head + ((m instanceof Lang.String) ? ": " + m : "");
            }
        }
        return "";
    }

    // ------------------------------------------------------------------
    // Estado de credenciales
    // ------------------------------------------------------------------

    //! true si hay refresh token (en Storage o sembrado desde properties).
    function hasCredentials() as Lang.Boolean {
        return load() != null;
    }

    //! v1: no hay login en curso en el reloj (el flujo es por portátil).
    function loginPending() as Lang.Boolean {
        return false;
    }

    //! Borra tokens, la instantánea y la cuenta aprendida; revoca el refresh
    //! en el servidor (mejor esfuerzo). Deja marcado (por hash) el refresh
    //! horneado para no volver a sembrarlo (un token NUEVO, tras re-login y
    //! re-bake, sí se siembra).
    function logout() as Void {
        var a = load();
        var rt = (a == null) ? null : (a.get("refresh") as Lang.String or Null);
        clear(rt);
        UsageStore.clearAll();
        if (rt != null && rt.length() > 0) {
            revoke(rt);
        }
    }

    //! revoked = refresh token que ya no vale (o null). No se guarda el token:
    //! cx_noseed recibe el HASH del refresh horneado en properties, que es el
    //! único que seed() podría volver a sembrar.
    function clear(revoked as Lang.String or Null) as Void {
        Storage.deleteValue(AUTH_KEY);
        var baked = prop("refresh_token");
        var target = null as Lang.String or Null;
        if (baked != null && (baked as Lang.String).length() >= 10) {
            target = baked;
        } else if (revoked != null && (revoked as Lang.String).length() > 0) {
            target = revoked;
        }
        var h = (target == null) ? null : hashOf(target as Lang.String);
        if (h != null) {
            Storage.setValue(NOSEED_KEY, h as Lang.String);
        } else {
            Storage.setValue(NOSEED_KEY, true);
        }
        sAuth = null;
        sAuthLoaded = true;
    }

    //! SHA-256 de un token en base64 (nunca se guarda el token en claro), o
    //! null si el dispositivo no tiene Cryptography.
    function hashOf(s as Lang.String) as Lang.String or Null {
        try {
            var bytes = StringUtil.convertEncodedString(s, {
                :fromRepresentation => StringUtil.REPRESENTATION_STRING_PLAIN_TEXT,
                :toRepresentation => StringUtil.REPRESENTATION_BYTE_ARRAY
            }) as Lang.ByteArray;
            var h = new Cryptography.Hash({ :algorithm => Cryptography.HASH_SHA256 });
            h.update(bytes);
            return StringUtil.convertEncodedString(h.digest(), {
                :fromRepresentation => StringUtil.REPRESENTATION_BYTE_ARRAY,
                :toRepresentation => StringUtil.REPRESENTATION_STRING_BASE64
            }) as Lang.String;
        } catch (e) {
            return null;
        }
    }

    //! Tokens en memoria (Storage solo se lee una vez; save/clear/seed la mantienen).
    function load() as Lang.Dictionary or Null {
        if (sAuthLoaded) {
            if (sAuth != null) {
                return sAuth;
            }
            // Sin sesión: si el refresh horneado es otro (re-bake tras re-login)
            // se siembra ya, sin esperar a reabrir la app.
            sAuth = seed();
            return sAuth;
        }
        sAuthLoaded = true;
        var v = Storage.getValue(AUTH_KEY);
        if (v instanceof Lang.Dictionary) {
            var rt = (v as Lang.Dictionary).get("refresh");
            if ((rt instanceof Lang.String) && (rt as Lang.String).length() > 0) {
                sAuth = v as Lang.Dictionary;
                return sAuth;
            }
        }
        sAuth = seed();
        return sAuth;
    }

    //! Siembra Storage desde las propiedades horneadas (scripts/bake-personal.sh):
    //! refresh_token, access_token, access_exp (epoch) y account_id. Solo se
    //! usa si Storage está vacío; se salta el refresh marcado en cx_noseed
    //! (comparado por hash, sin retener el secreto).
    function seed() as Lang.Dictionary or Null {
        var ns = Storage.getValue(NOSEED_KEY);
        if (ns instanceof Lang.Boolean && (ns as Lang.Boolean)) {
            return null;        // logout sin refresh horneado conocido
        }
        var rt = prop("refresh_token");
        if (rt == null || rt.length() < 10) {
            return null;
        }
        var rts = rt as Lang.String;
        if (ns instanceof Lang.String) {
            var nss = ns as Lang.String;
            var h = hashOf(rts);
            if (nss.equals(rts)) {
                // cx_noseed de una versión anterior (refresh EN CLARO): se purga.
                if (h != null) {
                    Storage.setValue(NOSEED_KEY, h);
                }
                return null;
            }
            if (h != null && nss.equals(h as Lang.String)) {
                return null;    // ese refresh horneado ya se descartó
            }
        }
        Storage.deleteValue(NOSEED_KEY);
        var at = prop("access_token");
        var exp = 0;
        var ex = prop("access_exp");
        if (at != null && at.length() > 0 && ex != null) {
            var n = ex.toNumber();
            if (n != null) {
                exp = n;
            }
        }
        var a = {
            "access" => (at == null) ? "" : at,
            "refresh" => rt,
            "exp" => exp
        };
        Storage.setValue(AUTH_KEY, a);
        sAuth = a;
        // account_id horneado: UsageStore.AID_KEY (misma cadena; se evita
        // referenciar el módulo desde aquí para no acoplar la siembra).
        var aid = prop("account_id");
        if (aid != null && aid.length() > 0) {
            Storage.setValue("cx_aid", aid);
        }
        return a;
    }

    function prop(id as Lang.String) as Lang.String or Null {
        try {
            var v = Application.Properties.getValue(id);
            if (v instanceof Lang.String) {
                return v as Lang.String;
            }
        } catch (e) {
        }
        return null;
    }

    function save(access as Lang.String, refresh as Lang.String, exp as Lang.Number) as Void {
        var a = { "access" => access, "refresh" => refresh, "exp" => exp };
        Storage.setValue(AUTH_KEY, a);
        sAuth = a;
        sAuthLoaded = true;
    }

    // ------------------------------------------------------------------
    // Access token
    // ------------------------------------------------------------------

    //! Access token válido (refresca si caduca en < 60 s).
    //! cb.invoke(ok as Boolean, token as String or Null, err as String or Null)
    function getAccessToken(cb as Lang.Method) as Void {
        var a = load();
        if (a == null) {
            cb.invoke(false, null, "Sin sesión");
            return;
        }
        var at = a.get("access");
        var exp = a.get("exp");
        if ((at instanceof Lang.String) && (at as Lang.String).length() > 0
                && (exp instanceof Lang.Number)
                && (exp as Lang.Number) - Time.now().value() > SKEW_S) {
            cb.invoke(true, at, null);
            return;
        }
        forceRefresh(cb);
    }

    //! Refresca ahora (p. ej. tras un 401). Mismo callback que getAccessToken.
    //! Si el servidor rechaza el refresh token (400/401) se borran los tokens
    //! y err = "Sesión caducada".
    function forceRefresh(cb as Lang.Method) as Void {
        var a = load();
        if (a == null) {
            cb.invoke(false, null, "Sin sesión");
            return;
        }
        sRefreshCbs.add(cb);
        if (sRefreshing) {
            return;
        }
        var rt = a.get("refresh");
        if (!(rt instanceof Lang.String) || (rt as Lang.String).length() == 0) {
            sRefreshCbs = [];
            cb.invoke(false, null, "Sin sesión");
            return;
        }
        sRefreshing = true;
        // SPEC "Refresco": JSON (no form), sin scope.
        Communications.makeWebRequest(
            TOKEN_URL,
            {
                "grant_type" => "refresh_token",
                "client_id" => CLIENT_ID,
                "refresh_token" => rt as Lang.String
            },
            {
                :method => Communications.HTTP_REQUEST_METHOD_POST,
                :headers => {
                    "Content-Type" => Communications.REQUEST_CONTENT_TYPE_JSON,
                    "Accept" => "application/json",
                    "User-Agent" => USER_AGENT
                },
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
            },
            new Lang.Method($.CodexAuth, :onRefreshResponse)
        );
    }

    function onRefreshResponse(code as Lang.Number,
            data as Lang.Dictionary or Lang.String or Null) as Void {
        System.println("cx refresh " + code + ((code != 200) ? " " + errType(data) : ""));
        var cbs = sRefreshCbs;
        sRefreshCbs = [];
        sRefreshing = false;

        var token = null;
        var err = null;
        if (code == 200 && (data instanceof Lang.Dictionary)) {
            var old = load();
            if (old == null) {
                err = "Sin sesión";     // logout mientras se refrescaba: no resucitar tokens
            } else {
                token = storeTokens(data as Lang.Dictionary, old.get("refresh") as Lang.String);
                if (token == null) {
                    err = "Respuesta inválida";
                }
            }
        } else if (code == 400 || code == 401) {
            // refresh_token_reused / _expired / _invalidated
            var old = load();
            var rt = (old == null) ? null : (old.get("refresh") as Lang.String or Null);
            clear(rt);
            err = "Sesión caducada";
        } else {
            err = errText(code);
        }
        for (var i = 0; i < cbs.size(); i++) {
            (cbs[i] as Lang.Method).invoke(token != null, token, err);
        }
    }

    //! Persiste {access_token, refresh_token?, expires_in} ANTES de nada (el
    //! refresh token rota). Devuelve el access token o null si no es válido.
    function storeTokens(d as Lang.Dictionary, fallbackRefresh as Lang.String) as Lang.String or Null {
        var at = d.get("access_token");
        var rt = d.get("refresh_token");
        var refresh = ((rt instanceof Lang.String) && (rt as Lang.String).length() > 0)
            ? (rt as Lang.String) : fallbackRefresh;
        if (!(at instanceof Lang.String) || (at as Lang.String).length() == 0) {
            // refresh_token rotado sin access_token: se guarda igual (el
            // anterior ya no vale) y la siguiente petición lo usa.
            if (!refresh.equals(fallbackRefresh)) {
                save("", refresh, 0);
            }
            return null;
        }
        var life = DEFAULT_LIFE_S;
        var ei = d.get("expires_in");
        if (ei instanceof Lang.Number) {
            life = ei as Lang.Number;
        } else if (ei instanceof Lang.Long) {
            life = (ei as Lang.Long).toNumber();
        } else if (ei instanceof Lang.Float) {
            life = (ei as Lang.Float).toNumber();
        } else if (ei instanceof Lang.Double) {
            life = (ei as Lang.Double).toNumber();
        }
        save(at as Lang.String, refresh, Time.now().value() + life);
        return at as Lang.String;
    }

    //! Revoca el refresh token (RFC 7009, form-urlencoded). Mejor esfuerzo:
    //! la respuesta solo se registra en el log y no bloquea el logout.
    function revoke(rt as Lang.String) as Void {
        try {
            Communications.makeWebRequest(
                REVOKE_URL,
                {
                    "token" => rt,
                    "token_type_hint" => "refresh_token",
                    "client_id" => CLIENT_ID
                },
                {
                    :method => Communications.HTTP_REQUEST_METHOD_POST,
                    :headers => {
                        "Content-Type" => Communications.REQUEST_CONTENT_TYPE_URL_ENCODED,
                        "Accept" => "application/json",
                        "User-Agent" => USER_AGENT
                    },
                    :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
                },
                new Lang.Method($.CodexAuth, :onRevokeResponse)
            );
        } catch (e) {
        }
    }

    function onRevokeResponse(code as Lang.Number,
            data as Lang.Dictionary or Lang.String or Null) as Void {
        System.println("cx revoke " + code);
    }

    //! Texto corto en español para un código de makeWebRequest / HTTP.
    function errText(code as Lang.Number) as Lang.String {
        if (code == -104 || code == -2 || code == -101) {
            return "Sin teléfono";
        }
        if (code == -300 || code == -1 || code == -3) {
            return "Sin conexión";
        }
        if (code == -400 || code == -402) {
            return "Respuesta inválida";
        }
        if (code == 429) {
            return "Demasiadas peticiones";
        }
        if (code == 403) {
            return "Acceso denegado";
        }
        if (code >= 500 && code < 600) {
            return "Error " + code;
        }
        if (code < 0) {
            return "Sin conexión";
        }
        return "Error " + code;
    }

    // ------------------------------------------------------------------
    // Login en el reloj — FUERA de v1
    // ------------------------------------------------------------------

    //! La Vía 1 del SPEC (device code por portátil) es la única soportada:
    //! scripts/codex-login.py crea la sesión y scripts/bake-personal.sh la
    //! hornea. cb.invoke(false, aviso) para que la vista lo muestre.
    //!
    //! TODO(Vía 2): login en el reloj, experimental y sin verificar:
    //! makeOAuthRequest con redirect_uri=http://localhost:1455/auth/callback
    //! (allowlist Hydra de la CLI) y codex_cli_simplified_flow=true; la doc de
    //! Garmin espera http://localhost y el puerto no está verificado
    //! (github.com/garmin/connectiq-apps/issues/30). Solo si OpenAI acepta ese
    //! redirect; si no, no hay workaround.
    //! Endpoints de referencia: https://auth.openai.com/oauth/authorize y la
    //! página del device code (https://auth.openai.com/codex/device, Vía 1).
    function startLogin(cb as Lang.Method or Null) as Void {
        if (cb != null) {
            cb.invoke(false, "Login: ejecuta scripts/codex-login.py en el portátil y scripts/bake-personal.sh");
        }
    }

    //! Sin efecto en v1; CodexUsageApp la llama al abrir la app y la Vía 2 la
    //! necesitaría para recibir el resultado OAuth de Garmin Connect.
    function register() as Void {
    }
}
