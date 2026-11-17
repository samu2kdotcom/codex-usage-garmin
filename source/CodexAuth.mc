using Toybox.Lang;
using Toybox.Application;
using Toybox.Application.Storage;
using Toybox.Communications;
using Toybox.Cryptography;
using Toybox.StringUtil;
using Toybox.System;
using Toybox.Time;
using Toybox.Timer;
using Toybox.WatchUi;

//! Tokens OAuth de la cuenta (scope de solo lectura), login PKCE en el reloj
//! y refresco. Solo este módulo toca Storage["cu_auth"]. NUNCA se imprimen ni
//! se registran tokens.
//!
//! PLACEHOLDER — CONTRATO SIN SUSTITUIR: CLIENT_ID, AUTHORIZE_URL, TOKEN_URL,
//! REDIRECT_URI y SCOPE son aún los de Claude, copiados de ../claude-usage.
//! Sustituir por los de ChatGPT/Codex al cerrar el contrato (SPEC.md,
//! "Autenticación"). NO hacer login real hasta entonces.
module CodexAuth {

    const AUTH_KEY = "cu_auth";        // { "access", "refresh", "exp" (epoch) }
    const LOGIN_KEY = "cu_login";      // { "v" verifier, "st" state, "t" epoch } mientras dura el login
    const NOSEED_KEY = "cu_noseed";    // true: no volver a sembrar desde properties

    const CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
    const AUTHORIZE_URL = "https://claude.com/cai/oauth/authorize";
    const TOKEN_URL = "https://platform.claude.com/v1/oauth/token";
    const REDIRECT_URI = "https://platform.claude.com/oauth/code/callback";
    const SCOPE = "user:profile";
    const SKEW_S = 60;                 // refrescar si caduca en < 60 s
    const LOGIN_TTL_S = 900;
    const LONG_EXPIRES_S = 31536000;
    // platform.claude.com/v1/oauth/token responde un 429 FALSO ("Rate limited")
    // a todo User-Agent que empiece por "Mozilla/5.0" o "curl/" (comprobado:
    // mismo cuerpo con otro UA -> 400/200). Garmin Connect manda UA de
    // navegador, así que se fija uno propio en las peticiones de tokens.
    const USER_AGENT = "CodexUsageGarmin/0.2";

    const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~";
    const DIGITS = "0123456789";

    var sAuth as Lang.Dictionary or Null = null;
    var sAuthLoaded as Lang.Boolean = false;
    var sRefreshing as Lang.Boolean = false;
    var sRefreshCbs as Lang.Array = [];
    var sLoginCb as Lang.Method or Null = null;
    var sLoginTriedExp as Lang.Boolean = false;
    var sLoginCode as Lang.String = "";
    var sLoginState as Lang.String = "";
    var sLoginVerifier as Lang.String = "";
    var sExchange429 as Lang.Number = 0;     // reintentos del canje tras 429
    var sTimer as Timer.Timer or Null = null;

    //! Tipo/mensaje de error de un cuerpo JSON de Anthropic ({"error":{type,message}}
    //! o {"error":"..."}), para los logs. Nunca contiene tokens.
    function errType(data as Lang.Object or Null) as Lang.String {
        if (data instanceof Lang.Dictionary) {
            var e = (data as Lang.Dictionary).get("error");
            if (e instanceof Lang.String) {
                return e as Lang.String;
            }
            if (e instanceof Lang.Dictionary) {
                var t = (e as Lang.Dictionary).get("type");
                var m = (e as Lang.Dictionary).get("message");
                return ((t instanceof Lang.String) ? t as Lang.String : "")
                    + ((m instanceof Lang.String) ? ": " + m : "");
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

    //! true mientras hay un login iniciado hace < 15 min sin completar.
    function loginPending() as Lang.Boolean {
        var l = Storage.getValue(LOGIN_KEY);
        if (!(l instanceof Lang.Dictionary)) {
            return false;
        }
        var t = (l as Lang.Dictionary).get("t");
        if (t instanceof Lang.Number) {
            return (Time.now().value() - (t as Lang.Number)) < LOGIN_TTL_S;
        }
        return false;
    }

    //! Borra tokens y la instantánea. En builds personales evita que se
    //! vuelva a sembrar el token horneado.
    function logout() as Void {
        clear();
        Storage.deleteValue(LOGIN_KEY);
        UsageStore.clearAll();
    }

    function clear() as Void {
        Storage.deleteValue(AUTH_KEY);
        Storage.setValue(NOSEED_KEY, true);
        sAuth = null;
        sAuthLoaded = true;
    }

    //! Tokens en memoria (Storage solo se lee una vez; save/clear/seed la mantienen).
    function load() as Lang.Dictionary or Null {
        if (sAuthLoaded) {
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

    //! Siembra Storage desde las propiedades horneadas (build personal).
    function seed() as Lang.Dictionary or Null {
        var ns = Storage.getValue(NOSEED_KEY);
        if ((ns instanceof Lang.Boolean) && (ns as Lang.Boolean)) {
            return null;
        }
        var rt = prop("refresh_token");
        if (rt == null || rt.length() < 10) {
            return null;
        }
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
        var rt = a.get("refresh") as Lang.String;
        sRefreshing = true;
        Communications.makeWebRequest(
            TOKEN_URL,
            {
                "grant_type" => "refresh_token",
                "refresh_token" => rt,
                "client_id" => CLIENT_ID,
                "scope" => SCOPE
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
        System.println("cu refresh " + code + ((code != 200) ? " " + errType(data) : ""));
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
            clear();
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
        if (!(at instanceof Lang.String) || (at as Lang.String).length() == 0) {
            return null;
        }
        var rt = d.get("refresh_token");
        var refresh = ((rt instanceof Lang.String) && (rt as Lang.String).length() > 0)
            ? (rt as Lang.String) : fallbackRefresh;
        var life = 3600;
        var ei = d.get("expires_in");
        if (ei instanceof Lang.Number) {
            life = ei as Lang.Number;
        } else if (ei instanceof Lang.Long) {
            life = (ei as Lang.Long).toNumber();
        } else if (ei instanceof Lang.Float || ei instanceof Lang.Double) {
            life = (ei as Lang.Float).toNumber();
        }
        save(at as Lang.String, refresh, Time.now().value() + life);
        return at as Lang.String;
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
    // Login en el reloj (PKCE + Garmin Connect)
    // ------------------------------------------------------------------

    //! Registra el receptor de mensajes OAuth. Llamar al abrir la app
    //! (proceso principal): entrega también un resultado en caché si la app
    //! se cerró durante el login.
    function register() as Void {
        Communications.registerForOAuthMessages(new Lang.Method($.CodexAuth, :onOAuthMessage));
    }

    //! Inicia el login: avisa en el móvil (Garmin Connect) para autorizar.
    //! cb.invoke(ok as Boolean, err as String or Null) al terminar el canje.
    function startLogin(cb as Lang.Method or Null) as Void {
        if (BuildFlags.isDemo()) {
            if (cb != null) {
                cb.invoke(false, "Modo demo");
            }
            return;
        }
        sLoginCb = cb;
        var verifier = randomString(64);
        var state = randomString(32);
        var plain = false;
        var challenge = s256(verifier);
        if (challenge == null) {
            // Sin Cryptography/Hash en este dispositivo: el servidor acepta "plain".
            plain = true;
            challenge = verifier;
        }
        Storage.setValue(LOGIN_KEY, { "v" => verifier, "st" => state, "t" => Time.now().value() });
        try {
            Communications.makeOAuthRequest(
                AUTHORIZE_URL,
                {
                    "code" => "true",
                    "client_id" => CLIENT_ID,
                    "response_type" => "code",
                    "redirect_uri" => REDIRECT_URI,
                    "scope" => SCOPE,
                    "code_challenge" => challenge,
                    "code_challenge_method" => plain ? "plain" : "S256",
                    "state" => state
                },
                REDIRECT_URI,
                Communications.OAUTH_RESULT_TYPE_URL,
                { "code" => "cu_code", "state" => "cu_state", "error" => "cu_error" }
            );
        } catch (e) {
            finishLogin(false, "Sin teléfono");
        }
    }

    //! Cadena aleatoria de n caracteres del alfabeto PKCE [A-Za-z0-9-._~].
    function randomString(n as Lang.Number) as Lang.String {
        var out = "";
        var len = ALPHABET.length();
        var bytes = null;
        try {
            bytes = Cryptography.randomBytes(n);
        } catch (e) {
            bytes = null;
        }
        for (var i = 0; i < n; i++) {
            var r = (bytes != null) ? (bytes as Lang.ByteArray)[i] : Toybox.Math.rand();
            if (r < 0) {
                r = -r;
            }
            var k = r % len;
            out += ALPHABET.substring(k, k + 1);
        }
        return out;
    }

    //! base64url(SHA-256(verifier)) sin relleno, o null si no se puede.
    function s256(verifier as Lang.String) as Lang.String or Null {
        try {
            var bytes = StringUtil.convertEncodedString(verifier, {
                :fromRepresentation => StringUtil.REPRESENTATION_STRING_PLAIN_TEXT,
                :toRepresentation => StringUtil.REPRESENTATION_BYTE_ARRAY
            }) as Lang.ByteArray;
            var h = new Cryptography.Hash({ :algorithm => Cryptography.HASH_SHA256 });
            h.update(bytes);
            var b64 = StringUtil.convertEncodedString(h.digest(), {
                :fromRepresentation => StringUtil.REPRESENTATION_BYTE_ARRAY,
                :toRepresentation => StringUtil.REPRESENTATION_STRING_BASE64
            }) as Lang.String;
            var out = "";
            for (var i = 0; i < b64.length(); i++) {
                var c = b64.substring(i, i + 1) as Lang.String;
                if (c.equals("+")) {
                    out += "-";
                } else if (c.equals("/")) {
                    out += "_";
                } else if (ALPHABET.find(c) != null && !c.equals(".") && !c.equals("~")) {
                    out += c;
                }
                // '=' y saltos de línea se descartan
            }
            return (out.length() == 43) ? out : null;
        } catch (e) {
            return null;
        }
    }

    //! Resultado de la autorización (callback de registerForOAuthMessages).
    function onOAuthMessage(msg as Communications.OAuthMessage) as Void {
        var d = msg.data;
        if (!(d instanceof Lang.Dictionary)) {
            finishLogin(false, "Login cancelado");
            return;
        }
        var dd = d as Lang.Dictionary;
        var l = Storage.getValue(LOGIN_KEY);
        if (!(l instanceof Lang.Dictionary)) {
            return;   // mensaje huérfano (login ya terminado o caducado)
        }
        var ld = l as Lang.Dictionary;
        var code = dd.get("cu_code");
        if (!(code instanceof Lang.String) || (code as Lang.String).length() == 0) {
            finishLogin(false, "Login rechazado");
            return;
        }
        var codeS = code as Lang.String;
        var hash = codeS.find("#");     // por si llega "code#state"
        if (hash != null && hash > 0) {
            codeS = codeS.substring(0, hash) as Lang.String;
        }
        var stored = ld.get("st");
        var got = dd.get("cu_state");
        if ((got instanceof Lang.String) && (stored instanceof Lang.String)
                && !(got as Lang.String).equals(stored as Lang.String)) {
            finishLogin(false, "Login inválido");
            return;
        }
        sLoginCode = codeS;
        sLoginState = (stored instanceof Lang.String) ? (stored as Lang.String) : "";
        sLoginVerifier = ld.get("v") as Lang.String;
        sLoginTriedExp = true;
        sExchange429 = 0;
        exchange(true);
    }

    function retryExchange() as Void {
        sTimer = null;
        exchange(sLoginTriedExp);
    }

    function exchange(withExpires as Lang.Boolean) as Void {
        var body = {
            "grant_type" => "authorization_code",
            "code" => sLoginCode,
            "state" => sLoginState,
            "client_id" => CLIENT_ID,
            "redirect_uri" => REDIRECT_URI,
            "code_verifier" => sLoginVerifier
        };
        if (withExpires) {
            body.put("expires_in", LONG_EXPIRES_S);
        }
        Communications.makeWebRequest(TOKEN_URL, body, {
            :method => Communications.HTTP_REQUEST_METHOD_POST,
            :headers => {
                "Content-Type" => Communications.REQUEST_CONTENT_TYPE_JSON,
                "Accept" => "application/json",
                "User-Agent" => USER_AGENT
            },
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        }, new Lang.Method($.CodexAuth, :onExchangeResponse));
    }

    function onExchangeResponse(code as Lang.Number,
            data as Lang.Dictionary or Lang.String or Null) as Void {
        System.println("cu exchange " + code + (sLoginTriedExp ? " (expires_in)" : "")
            + ((code != 200) ? " " + errType(data) : ""));
        if (code == 400 && sLoginTriedExp) {
            sLoginTriedExp = false;      // reintento sin expires_in
            exchange(false);
            return;
        }
        if (code == 429 && sExchange429 < 2) {
            // Límite de peticiones del endpoint de tokens: reintento a los 3 s
            // (el código aún no se ha consumido).
            sExchange429 += 1;
            sTimer = new Timer.Timer();
            (sTimer as Timer.Timer).start(new Lang.Method($.CodexAuth, :retryExchange), 3000, false);
            return;
        }
        if (code == 200 && (data instanceof Lang.Dictionary)) {
            var t = storeTokens(data as Lang.Dictionary, "");
            var a = load();
            if (t != null && a != null) {
                Storage.deleteValue(NOSEED_KEY);
                UsageStore.clearError();
                finishLogin(true, null);
                return;
            }
            finishLogin(false, "Respuesta inválida");
            return;
        }
        finishLogin(false, (code == 400 || code == 401) ? "Login rechazado" : errText(code));
    }

    function finishLogin(ok as Lang.Boolean, err as Lang.String or Null) as Void {
        Storage.deleteValue(LOGIN_KEY);
        sLoginCode = "";
        sLoginVerifier = "";
        var cb = sLoginCb;
        sLoginCb = null;
        if (cb != null) {
            cb.invoke(ok, err);
        }
        WatchUi.requestUpdate();
    }
}
