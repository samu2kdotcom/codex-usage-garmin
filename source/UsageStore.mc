using Toybox.Lang;
using Toybox.System;
using Toybox.Application;
using Toybox.Application.Storage;
using Toybox.Communications;
using Toybox.Time;

//! Instantánea del uso de la cuenta ChatGPT/Codex (SPEC.md, "Instantánea"):
//! GET a /wham/usage + /wham/rate-limit-reset-credits, clasificación de
//! ventanas por limit_window_seconds, histórico y estado de error. Solo
//! proceso principal (la glance lee Storage directamente).
//!
//! La API es interna y sin documentar: el parseo se aísla aquí y degrada con
//! mensajes claros ("Respuesta inválida", "Bloqueado (Cloudflare)"). Nunca se
//! imprimen tokens.
typedef Json as Lang.Dictionary<Lang.String, Lang.Object or Null>;

module UsageStore {

    const SNAP_KEY = "cx_snap";
    const FETCH_KEY = "cx_fetch";
    const ERR_KEY = "cx_err";
    const HIST_KEY = "cx_hist";
    const ATTEMPT_KEY = "cx_attempt";   // [epoch del último intento fallido, espera en s]
    const AID_KEY = "cx_aid";           // chatgpt-account-id aprendido (lo siembra CodexAuth.seed())

    const USAGE_URL = "https://chatgpt.com/backend-api/wham/usage";
    const RESETS_URL = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits";
    const ORIGINATOR = "codex_cli_rs";  // allowlist de primera parte de OpenAI

    const W_SESSION = 18000;    // ventana de 5 h
    const W_WEEK = 604800;      // ventana semanal

    const FRESH_S = 300;        // sync(false) no hace red si el dato tiene < 5 min
    const RETRY_S = 120;        // ni reintenta antes de 2 min tras un fallo
    const RETRY_429_S = 600;    // ni antes de 10 min si da 429
    const RETRY_BLOCKED_S = 1800;   // Cloudflare: backoff largo, sin bucle
    const BUSY_S = 60;          // una petición en vuelo caduca a los 60 s
    const HIST_MAX = 96;
    const HIST_GAP_S = 900;     // ≥ 15 min entre muestras salvo que cambie el % semanal

    var sBusy as Lang.Boolean = false;
    var sBusyAt as Lang.Number = 0;
    var sRetried as Lang.Boolean = false;
    var sCbs as Lang.Array = [];

    // Caché en memoria de Storage (se carga una vez, perezosa; solo este módulo
    // escribe estas claves y mantiene la caché al día).
    var sLoaded as Lang.Boolean = false;
    var sSnap as Lang.Dictionary or Null = null;
    var sFetch as Lang.Number or Null = null;
    var sErr as Lang.String or Null = null;
    var sHist as Lang.Array = [];
    var sAttempt as Lang.Array or Null = null;
    var sAid as Lang.String or Null = null;
    var sToken as Lang.String or Null = null;   // access token del ciclo en vuelo
    var sVer as Lang.Number = 0;        // sube cuando cambian snapshot/histórico
    // Instantánea a la espera del segundo GET (reset credits) en este ciclo.
    var sPending as Json or Null = null;

    function ensure() as Void {
        if (sLoaded) {
            return;
        }
        sLoaded = true;
        var v = Storage.getValue(SNAP_KEY);
        sSnap = (v instanceof Lang.Dictionary) ? (v as Lang.Dictionary) : null;
        v = Storage.getValue(FETCH_KEY);
        sFetch = (v instanceof Lang.Number) ? (v as Lang.Number) : null;
        v = Storage.getValue(ERR_KEY);
        sErr = (v instanceof Lang.String) ? (v as Lang.String) : null;
        v = Storage.getValue(HIST_KEY);
        sHist = (v instanceof Lang.Array) ? (v as Lang.Array) : [];
        v = Storage.getValue(ATTEMPT_KEY);
        sAttempt = (v instanceof Lang.Array && (v as Lang.Array).size() >= 2) ? (v as Lang.Array) : null;
        v = Storage.getValue(AID_KEY);
        sAid = (v instanceof Lang.String && (v as Lang.String).length() > 0) ? (v as Lang.String) : null;
    }

    // ------------------------------------------------------------------
    // Lectura
    // ------------------------------------------------------------------

    function snapshot() as Lang.Dictionary or Null {
        if (BuildFlags.isDemo()) {
            return demoSnapshot();
        }
        ensure();
        return sSnap;
    }

    function fetchEpoch() as Lang.Number or Null {
        ensure();
        return sFetch;
    }

    function lastError() as Lang.String or Null {
        ensure();
        return sErr;
    }

    //! Cambia cada vez que snapshot o histórico se renuevan (para memoizar en la UI).
    function version() as Lang.Number {
        return sVer;
    }

    function needsLogin() as Lang.Boolean {
        return !BuildFlags.isDemo() && !CodexAuth.hasCredentials();
    }

    function isBusy() as Lang.Boolean {
        return sBusy && (Time.now().value() - sBusyAt) < BUSY_S;
    }

    function history() as Lang.Array {
        if (BuildFlags.isDemo()) {
            return demoHistory();
        }
        ensure();
        return sHist;
    }

    //! account_id conocido (chatgpt-account-id), o null.
    function accountId() as Lang.String or Null {
        ensure();
        return sAid;
    }

    //! Borra datos y errores (logout) y vacía la caché.
    function clearAll() as Void {
        Storage.deleteValue(SNAP_KEY);
        Storage.deleteValue(FETCH_KEY);
        Storage.deleteValue(ERR_KEY);
        Storage.deleteValue(HIST_KEY);
        Storage.deleteValue(ATTEMPT_KEY);
        Storage.deleteValue(AID_KEY);
        sLoaded = true;
        sSnap = null;
        sFetch = null;
        sErr = null;
        sHist = [];
        sAttempt = null;
        sAid = null;
        sPending = null;
        sVer++;
        sBusy = false;
        sCbs = [];
    }

    function setError(err as Lang.String) as Void {
        ensure();
        if (sErr == null || !(sErr as Lang.String).equals(err)) {
            sErr = err;
            Storage.setValue(ERR_KEY, err);
        }
    }

    function clearError() as Void {
        ensure();
        if (sErr != null) {
            sErr = null;
            Storage.deleteValue(ERR_KEY);
        }
    }

    //! true si hubo un fallo reciente y aún no toca reintentar.
    function inBackoff(now as Lang.Number) as Lang.Boolean {
        ensure();
        if (sAttempt == null) {
            return false;
        }
        var t = (sAttempt as Lang.Array)[0];
        var w = (sAttempt as Lang.Array)[1];
        if (!(t instanceof Lang.Number) || !(w instanceof Lang.Number)) {
            return false;
        }
        var d = now - (t as Lang.Number);
        return d >= 0 && d < (w as Lang.Number);
    }

    // ------------------------------------------------------------------
    // Sincronización
    // ------------------------------------------------------------------

    //! cb.invoke(ok as Boolean) al terminar (también si no hay red).
    function sync(force as Lang.Boolean, cb as Lang.Method or Null) as Void {
        if (BuildFlags.isDemo()) {
            if (cb != null) {
                cb.invoke(true);
            }
            return;
        }
        var now = Time.now().value();
        if (isBusy()) {
            if (cb != null) {
                sCbs.add(cb);       // anti-rebote: se avisa al terminar la petición en vuelo
            }
            return;
        }
        if (!CodexAuth.hasCredentials()) {
            setError("Sin sesión");
            if (cb != null) {
                cb.invoke(false);
            }
            return;
        }
        if (!force) {
            var f = fetchEpoch();
            if (f != null && now - f >= 0 && now - f < FRESH_S) {
                if (cb != null) {
                    cb.invoke(true);
                }
                return;
            }
            if (inBackoff(now)) {
                if (cb != null) {
                    cb.invoke(false);
                }
                return;
            }
        }
        sBusy = true;
        sBusyAt = now;
        sRetried = false;
        sPending = null;
        sToken = null;
        sCbs = (cb != null) ? [cb] : [];
        CodexAuth.getAccessToken(new Lang.Method($.UsageStore, :onToken));
    }

    function onToken(ok as Lang.Boolean, token as Lang.String or Null, err as Lang.String or Null) as Void {
        if (!ok || token == null) {
            finish(false, err, RETRY_S);
            return;
        }
        var t = token as Lang.String;
        sToken = t;
        Communications.makeWebRequest(
            USAGE_URL,
            null,
            {
                :method => Communications.HTTP_REQUEST_METHOD_GET,
                :headers => headers(t),
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
            },
            new Lang.Method($.UsageStore, :onUsage)
        );
    }

    //! Cabeceras del SPEC ("Fuente de datos"): UA propio + originator de primera
    //! parte (Cloudflare) y chatgpt-account-id cuando se conoce.
    function headers(token as Lang.String) as Lang.Dictionary {
        var h = {
            "Authorization" => "Bearer " + token,
            "Accept" => "application/json",
            "User-Agent" => CodexAuth.USER_AGENT,
            "originator" => ORIGINATOR
        };
        var aid = accountId();
        if (aid != null) {
            h.put("chatgpt-account-id", aid as Lang.String);
        }
        return h;
    }

    function onUsage(code as Lang.Number, data as Lang.Dictionary or Lang.String or Null) as Void {
        System.println("cx usage " + code + (sRetried ? " (reintento)" : "")
            + ((code != 200) ? (" " + CodexAuth.errType(data)) : ""));
        // 401 ⇒ un refresh + un reintento (el access token JWT caduca ~1 h).
        if (code == 401) {
            if (!sRetried) {
                sRetried = true;
                CodexAuth.forceRefresh(new Lang.Method($.UsageStore, :onToken));
                return;
            }
            finish(false, "Sesión caducada", RETRY_S);
            return;
        }
        // 403 en chatgpt.com/backend-api es el reto de Cloudflare (a menudo con
        // body HTML): mensaje claro y backoff largo, sin bucle.
        if (code == 403) {
            finish(false, "Bloqueado (Cloudflare)", RETRY_BLOCKED_S);
            return;
        }
        if (code == 429) {
            finish(false, "API saturada (429)", RETRY_429_S);
            return;
        }
        if (code != 200) {
            finish(false, CodexAuth.errText(code), RETRY_S);
            return;
        }
        if (!(data instanceof Lang.Dictionary)) {
            finish(false, "Respuesta inválida", RETRY_S);
            return;
        }
        if (!CodexAuth.hasCredentials()) {
            // logout mientras la petición volaba: no resucitar datos borrados
            release(false);
            return;
        }
        var d = data as Json;
        // account_id: se aprende en la primera respuesta y se manda en adelante.
        var aid = d.get("account_id");
        if (aid instanceof Lang.String && (aid as Lang.String).length() > 0) {
            setAccountId(aid as Lang.String);
        }
        var snap = parseSnapshot(d);
        if (snap == null) {
            finish(false, "Respuesta inválida", RETRY_S);
            return;
        }
        sPending = snap as Json;
        Communications.makeWebRequest(
            RESETS_URL,
            null,
            {
                :method => Communications.HTTP_REQUEST_METHOD_GET,
                :headers => headers((sToken == null) ? "" : sToken as Lang.String),
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
            },
            new Lang.Method($.UsageStore, :onResets)
        );
    }

    //! Segundo GET del ciclo: reset credits. Si falla, el uso se guarda igual
    //! (queda el available_count inline de /wham/usage como contador).
    function onResets(code as Lang.Number, data as Lang.Dictionary or Lang.String or Null) as Void {
        System.println("cx resets " + code);
        var snap = sPending;
        sPending = null;
        if (snap == null) {
            return;     // huérfano (logout u otro ciclo)
        }
        if (code == 200 && (data instanceof Lang.Dictionary)) {
            var r = parseResets(data as Json);
            snap.put("g", r["g"]);
            var gc = r["gc"];
            if (gc != null) {
                snap.put("gc", gc);
            }
        }
        commit(snap);
    }

    function commit(snap as Json) as Void {
        if (!CodexAuth.hasCredentials()) {
            release(false);
            return;
        }
        var now = Time.now().value();
        ensure();
        sSnap = snap;
        sFetch = now;
        sVer++;
        Storage.setValue(SNAP_KEY, snap as Lang.Dictionary<Application.Storage.KeyType, Application.Storage.ValueType>);
        Storage.setValue(FETCH_KEY, now);
        appendHistory(snap, now);
        finish(true, null, 0);
    }

    //! Cierra la petición: guarda/borra el error y el intento fallido, y avisa a los callbacks.
    function finish(ok as Lang.Boolean, err as Lang.String or Null, wait as Lang.Number) as Void {
        ensure();
        if (ok) {
            clearError();
            if (sAttempt != null) {
                sAttempt = null;
                Storage.deleteValue(ATTEMPT_KEY);
            }
        } else {
            setError((err != null) ? err : "Error");
            sAttempt = [Time.now().value(), wait];
            Storage.setValue(ATTEMPT_KEY, sAttempt as Lang.Array<Application.Storage.ValueType>);
        }
        release(ok);
    }

    function release(ok as Lang.Boolean) as Void {
        sBusy = false;
        sPending = null;
        sToken = null;
        var cbs = sCbs;
        sCbs = [];
        for (var i = 0; i < cbs.size(); i++) {
            (cbs[i] as Lang.Method).invoke(ok);
        }
    }

    //! Guarda el account_id aprendido (Storage y caché) para las cabeceras.
    function setAccountId(aid as Lang.String) as Void {
        ensure();
        if (sAid != null && (sAid as Lang.String).equals(aid)) {
            return;
        }
        sAid = aid;
        Storage.setValue(AID_KEY, aid);
    }

    // ------------------------------------------------------------------
    // Parseo (SPEC.md, "Instantánea")
    // ------------------------------------------------------------------

    //! JSON de /wham/usage -> instantánea; null si no trae nada aprovechable.
    function parseSnapshot(d as Json) as Json or Null {
        var s = null as Lang.Dictionary or Null;
        var w = null as Lang.Dictionary or Null;
        var others = [] as Lang.Array;
        var allowed = null as Lang.Boolean or Null;

        var rl = d.get("rate_limit");
        if (rl instanceof Lang.Dictionary) {
            var r = rl as Json;
            var al = r.get("allowed");
            if (al instanceof Lang.Boolean) {
                allowed = al as Lang.Boolean;
            }
            // Clasificar por limit_window_seconds, NO por posición: en free y
            // Team la ventana semanal llega como primary_window.
            var wins = [] as Lang.Array;
            var pw = windowOf(r.get("primary_window"));
            if (pw != null) { wins.add(pw); }
            var sw = windowOf(r.get("secondary_window"));
            if (sw != null) { wins.add(sw); }
            for (var i = 0; i < wins.size(); i++) {
                var e = wins[i] as Lang.Dictionary;
                var sec = e["sec"] as Lang.Number or Null;
                if (sec != null && sec == W_SESSION && s == null) {
                    s = e;
                } else if (sec != null && sec == W_WEEK && w == null) {
                    w = e;
                } else if (sec != null && sec != W_SESSION && sec != W_WEEK) {
                    others.add(otherWindow(e));
                } else if (s == null) {
                    s = e;      // duración desconocida: hueco libre (primero sesión)
                } else if (w == null) {
                    w = e;
                } else {
                    others.add(otherWindow(e));
                }
            }
        }

        var add = additional(d.get("additional_rate_limits"));
        var cr = codeReview(d.get("code_review_rate_limit"));
        var x = credits(d.get("credits"), d.get("spend_control"));
        var pl = d.get("plan_type");
        var plan = (pl instanceof Lang.String) ? (pl as Lang.String) : null;

        var gc = null as Lang.Number or Null;
        var rrc = d.get("rate_limit_reset_credits");
        if (rrc instanceof Lang.Dictionary) {
            gc = asNumber((rrc as Json).get("available_count"));
        }

        var out = {
            "o" => others,
            "a" => add,
            "cr" => cr,
            "g" => [] as Lang.Array,
            "gc" => gc,
            "x" => x,
            "pl" => plan,
            "al" => allowed
        };
        if (s != null) { out.put("s", s); }
        if (w != null) { out.put("w", w); }

        if (s == null && w == null && others.size() == 0 && add.size() == 0
                && cr == null && plan == null) {
            return null;
        }
        return out;
    }

    //! Ventana de uso { "p", "r", "sv", "sec" } o null si no trae porcentaje.
    //! used_percent es % USADO (no restante) y se acota a 0..100.
    function windowOf(v as Lang.Object or Null) as Lang.Dictionary or Null {
        if (!(v instanceof Lang.Dictionary)) {
            return null;
        }
        var dd = v as Json;
        var p = pctNumber(dd.get("used_percent"));
        if (p == null) {
            return null;
        }
        return {
            "p" => p,
            "r" => resetOf(dd),
            "sv" => null,
            "sec" => asNumber(dd.get("limit_window_seconds"))
        };
    }

    //! Otra ventana (duración distinta de 5 h / 7 d) para "Otros límites".
    function otherWindow(e as Lang.Dictionary) as Lang.Dictionary {
        var sec = e["sec"] as Lang.Number or Null;
        return {
            "n" => (sec == null) ? "Otra ventana" : durationName(sec),
            "p" => e["p"],
            "r" => e["r"],
            "sec" => sec
        };
    }

    //! additional_rate_limits[] -> filas { "n", "p", "r", "sec" }.
    //! n = limit_name (p. ej. "GPT-Codex-Spark"); una fila por ventana.
    function additional(v as Lang.Object or Null) as Lang.Array {
        var out = [] as Lang.Array;
        if (!(v instanceof Lang.Array)) {
            return out;
        }
        var arr = v as Lang.Array;
        for (var i = 0; i < arr.size(); i++) {
            var itv = arr[i];
            if (!(itv instanceof Lang.Dictionary)) {
                continue;
            }
            var it = itv as Json;
            var name = it.get("limit_name");
            if (!(name instanceof Lang.String)) {
                name = it.get("metered_feature");
            }
            var label = (name instanceof Lang.String) ? (name as Lang.String) : "Extra";
            var rlv = it.get("rate_limit");
            if (!(rlv instanceof Lang.Dictionary)) {
                continue;
            }
            var rl = rlv as Json;
            var p1 = windowOf(rl.get("primary_window"));
            var p2 = windowOf(rl.get("secondary_window"));
            if (p1 == null) {
                p1 = p2;
                p2 = null;
            }
            if (p1 != null) {
                out.add({ "n" => label, "p" => p1["p"], "r" => p1["r"], "sec" => p1["sec"] });
            }
            if (p2 != null) {
                var sec = p2["sec"] as Lang.Number or Null;
                out.add({
                    "n" => label + ((sec == null) ? " · extra" : " · " + durationName(sec)),
                    "p" => p2["p"],
                    "r" => p2["r"],
                    "sec" => sec
                });
            }
        }
        return out;
    }

    //! code_review_rate_limit -> { "p", "r" } o null.
    function codeReview(v as Lang.Object or Null) as Lang.Dictionary or Null {
        if (!(v instanceof Lang.Dictionary)) {
            return null;
        }
        var vd = v as Json;
        var win = windowOf(vd.get("primary_window"));
        if (win == null) {
            win = windowOf(vd.get("secondary_window"));
        }
        if (win == null) {
            return null;
        }
        return { "p" => win["p"], "r" => win["r"] };
    }

    //! credits + spend_control -> { "on", "bal", "unl", "rc", "sc", "scp", "scr" }.
    function credits(v as Lang.Object or Null, sc as Lang.Object or Null) as Lang.Dictionary {
        var on = false;
        var bal = null as Lang.Float or Null;
        var unl = false;
        var rc = false;
        if (v instanceof Lang.Dictionary) {
            var c = v as Json;
            var hc = c.get("has_credits");
            on = (hc instanceof Lang.Boolean) && (hc as Lang.Boolean);
            var ul = c.get("unlimited");
            unl = (ul instanceof Lang.Boolean) && (ul as Lang.Boolean);
            var orl = c.get("overage_limit_reached");
            rc = (orl instanceof Lang.Boolean) && (orl as Lang.Boolean);
            bal = asFloat(c.get("balance"));
        }
        var reached = false;
        var usedPct = null as Lang.Number or Null;
        var resetAt = null as Lang.Number or Null;
        if (sc instanceof Lang.Dictionary) {
            var sp = sc as Json;
            var r = sp.get("reached");
            reached = (r instanceof Lang.Boolean) && (r as Lang.Boolean);
            var il = sp.get("individual_limit");
            if (il instanceof Lang.Dictionary) {
                var ild = il as Json;
                usedPct = pctNumber(ild.get("used_percent"));
                resetAt = resetOf(ild);
            }
        }
        return {
            "on" => on,
            "bal" => bal,
            "unl" => unl,
            "rc" => rc,
            "sc" => reached,
            "scp" => usedPct,
            "scr" => resetAt
        };
    }

    //! /wham/rate-limit-reset-credits -> { "g": filas, "gc": disponible(s) }.
    //! Solo se ofrecen los créditos con status "available"; available_count es
    //! autoritativo (credits[] puede venir truncado).
    function parseResets(d as Json) as Json {
        var out = [] as Lang.Array;
        var creds = d.get("credits");
        if (creds instanceof Lang.Array) {
            var arr = creds as Lang.Array;
            for (var i = 0; i < arr.size(); i++) {
                var cv = arr[i];
                if (!(cv instanceof Lang.Dictionary)) {
                    continue;
                }
                var c = cv as Json;
                var st = c.get("status");
                if (!(st instanceof Lang.String) || !(st as Lang.String).equals("available")) {
                    continue;
                }
                var id = c.get("id");
                var l = c.get("title");
                var t = c.get("reset_type");
                out.add({
                    "id" => (id instanceof Lang.String) ? (id as Lang.String) : null,
                    "l" => (l instanceof Lang.String) ? (l as Lang.String) : "Reinicio",
                    "t" => (t instanceof Lang.String) ? (t as Lang.String) : null,
                    "e" => parseIso(c.get("expires_at")),
                    "st" => st as Lang.String
                });
            }
        }
        var cnt = asNumber(d.get("available_count"));
        if (cnt == null) {
            cnt = out.size();
        }
        return { "g" => out, "gc" => cnt };
    }

    //! Epoch de reinicio: reset_at (epoch) o reset_after_seconds desde ahora.
    function resetOf(d as Json) as Lang.Number or Null {
        var at = asNumber(d.get("reset_at"));
        if (at != null) {
            return at;
        }
        var after = asNumber(d.get("reset_after_seconds"));
        if (after == null) {
            return null;
        }
        return Time.now().value() + after;
    }

    //! Duración legible: "5 h", "7 d", "2 h"…
    function durationName(sec as Lang.Number) as Lang.String {
        if (sec > 0 && sec % 86400 == 0) {
            return (sec / 86400) + " d";
        }
        if (sec > 0 && sec % 3600 == 0) {
            return (sec / 3600) + " h";
        }
        if (sec >= 60) {
            return (sec / 60) + " min";
        }
        return sec + " s";
    }

    //! JSON numérico -> Number; null si no es número.
    function asNumber(v as Lang.Object or Null) as Lang.Number or Null {
        if (v instanceof Lang.Number) {
            return v as Lang.Number;
        }
        if (v instanceof Lang.Long) {
            return (v as Lang.Long).toNumber();
        }
        if (v instanceof Lang.Float) {
            return (v as Lang.Float).toNumber();
        }
        if (v instanceof Lang.Double) {
            return (v as Lang.Double).toNumber();
        }
        return null;
    }

    //! JSON numérico -> Float (a prueba de Number/Long/Float/Double); null si no es número.
    function asFloat(v as Lang.Object or Null) as Lang.Float or Null {
        if (v instanceof Lang.Float) {
            return v as Lang.Float;
        }
        if (v instanceof Lang.Double) {
            return (v as Lang.Double).toFloat();
        }
        if (v instanceof Lang.Number) {
            return (v as Lang.Number).toFloat();
        }
        if (v instanceof Lang.Long) {
            return (v as Lang.Long).toFloat();
        }
        return null;
    }

    //! Porcentaje redondeado y acotado a 0..100, o null.
    function pctNumber(v as Lang.Object or Null) as Lang.Number or Null {
        var f = asFloat(v);
        if (f == null) {
            return null;
        }
        if (f < 0.0) {
            f = 0.0;
        }
        if (f > 100.0) {
            f = 100.0;
        }
        return (f + 0.5).toNumber();
    }

    // ------------------------------------------------------------------
    // ISO-8601 -> epoch UTC
    // ------------------------------------------------------------------

    //! "2026-11-16T02:19:59.533786+00:00" (o "...Z", "...-05:30", "+0100",
    //! sin fracción) -> epoch UTC (Number); null si no se entiende.
    function parseIso(v as Lang.Object or Null) as Lang.Number or Null {
        if (!(v instanceof Lang.String)) {
            return null;
        }
        var s = v as Lang.String;
        if (s.length() < 19) {
            return null;
        }
        var y = digits(s, 0, 4);
        var mo = digits(s, 5, 7);
        var d = digits(s, 8, 10);
        var h = digits(s, 11, 13);
        var mi = digits(s, 14, 16);
        var se = digits(s, 17, 19);
        if (y == null || mo == null || d == null || h == null || mi == null || se == null) {
            return null;
        }
        var i = 19;
        var n = s.length();
        if (i < n && ch(s, i).equals(".")) {
            i++;
            while (i < n && "0123456789".find(ch(s, i)) != null) {
                i++;
            }
        }
        var off = 0;
        if (i < n) {
            var c = ch(s, i);
            if (c.equals("+") || c.equals("-")) {
                var oh = digits(s, i + 1, i + 3);
                if (oh == null) {
                    return null;
                }
                var j = i + 3;
                if (j < n && ch(s, j).equals(":")) {
                    j++;
                }
                var om = (j + 2 <= n) ? digits(s, j, j + 2) : 0;
                if (om == null) {
                    om = 0;
                }
                off = oh * 3600 + om * 60;
                if (c.equals("-")) {
                    off = -off;
                }
            }
        }
        return dayNumber(y, mo, d) * 86400 + h * 3600 + mi * 60 + se - off;
    }

    function ch(s as Lang.String, i as Lang.Number) as Lang.String {
        return s.substring(i, i + 1) as Lang.String;
    }

    //! Entero de dígitos s[a..b) o null si hay algo que no es dígito.
    function digits(s as Lang.String, a as Lang.Number, b as Lang.Number) as Lang.Number or Null {
        if (b > s.length()) {
            return null;
        }
        var acc = 0;
        for (var i = a; i < b; i++) {
            var pos = "0123456789".find(ch(s, i));
            if (pos == null) {
                return null;
            }
            acc = acc * 10 + pos;
        }
        return acc;
    }

    //! Días desde 1970-01-01 (calendario civil; algoritmo de Howard Hinnant).
    function dayNumber(y as Lang.Number, mo as Lang.Number, d as Lang.Number) as Lang.Number {
        if (mo <= 2) {
            y -= 1;
        }
        var era = y / 400;
        var yoe = y - era * 400;
        var mp = (mo > 2) ? (mo - 3) : (mo + 9);
        var doy = (153 * mp + 2) / 5 + d - 1;
        var doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146097 + doe - 719468;
    }

    // ------------------------------------------------------------------
    // Histórico
    // ------------------------------------------------------------------

    function appendHistory(snap as Json, now as Lang.Number) as Void {
        var wv = snap.get("w");
        if (!(wv instanceof Lang.Dictionary)) {
            return;
        }
        var wp = (wv as Json).get("p");
        if (!(wp instanceof Lang.Number)) {
            return;
        }
        var sp = 0;
        var sv = snap.get("s");
        if (sv instanceof Lang.Dictionary) {
            var p = (sv as Json).get("p");
            if (p instanceof Lang.Number) {
                sp = p as Lang.Number;
            }
        }
        var hist = sHist;
        if (hist.size() > 0) {
            var last = hist[hist.size() - 1];
            if (last instanceof Lang.Array && (last as Lang.Array).size() >= 3) {
                var la = last as Lang.Array;
                var lt = la[0];
                var lw = la[2];
                if (lt instanceof Lang.Number && lw instanceof Lang.Number
                        && now - (lt as Lang.Number) >= 0
                        && now - (lt as Lang.Number) < HIST_GAP_S
                        && (lw as Lang.Number) == (wp as Lang.Number)) {
                    return;
                }
            }
        }
        hist.add([now, sp, wp]);
        if (hist.size() > HIST_MAX) {
            hist = hist.slice(hist.size() - HIST_MAX, null);
        }
        sHist = hist;
        Storage.setValue(HIST_KEY, hist as Lang.Array<Application.Storage.ValueType>);
    }

    (:demo)
    function demoSnapshot() as Lang.Dictionary or Null { return DemoData.snapshot(); }
    (:prod)
    function demoSnapshot() as Lang.Dictionary or Null { return null; }

    (:demo)
    function demoHistory() as Lang.Array { return DemoData.history(); }
    (:prod)
    function demoHistory() as Lang.Array { return []; }
}
