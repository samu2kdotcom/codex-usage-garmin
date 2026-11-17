using Toybox.Lang;
using Toybox.System;
using Toybox.Application;
using Toybox.Application.Storage;
using Toybox.Communications;
using Toybox.Time;

//! Instantánea del uso de la cuenta (SPEC.md, "Instantánea"): petición al
//! endpoint de uso, parseo, histórico y estado de error. Solo proceso
//! principal (la glance lee Storage directamente).
//!
//! PLACEHOLDER — CONTRATO SIN SUSTITUIR: USAGE_URL y el parseo son aún los
//! de la API de Claude, copiados de ../claude-usage. El endpoint de uso de
//! ChatGPT/Codex y su shape se cierran en SPEC.md. El modo DEMO funciona.
typedef Json as Lang.Dictionary<Lang.String, Lang.Object or Null>;

module UsageStore {

    const SNAP_KEY = "cu_snap";
    const FETCH_KEY = "cu_fetch";
    const ERR_KEY = "cu_err";
    const HIST_KEY = "cu_hist";
    const ATTEMPT_KEY = "cu_attempt";   // [epoch del último intento fallido, espera en s]

    const USAGE_URL = "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1";
    const FRESH_S = 300;        // sync(false) no hace red si el dato tiene < 5 min
    const RETRY_S = 120;        // ni reintenta antes de 2 min tras un fallo
    const RETRY_429_S = 600;    // ni antes de 10 min si el reintento con token nuevo también da 429
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
    var sVer as Lang.Number = 0;        // sube cuando cambian snapshot/histórico

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

    //! Borra datos y errores (logout) y vacía la caché.
    function clearAll() as Void {
        Storage.deleteValue(SNAP_KEY);
        Storage.deleteValue(FETCH_KEY);
        Storage.deleteValue(ERR_KEY);
        Storage.deleteValue(HIST_KEY);
        Storage.deleteValue(ATTEMPT_KEY);
        sLoaded = true;
        sSnap = null;
        sFetch = null;
        sErr = null;
        sHist = [];
        sAttempt = null;
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
        sCbs = (cb != null) ? [cb] : [];
        CodexAuth.getAccessToken(new Lang.Method($.UsageStore, :onToken));
    }

    function onToken(ok as Lang.Boolean, token as Lang.String or Null, err as Lang.String or Null) as Void {
        if (!ok || token == null) {
            finish(false, err, RETRY_S);
            return;
        }
        Communications.makeWebRequest(
            USAGE_URL,
            null,
            {
                :method => Communications.HTTP_REQUEST_METHOD_GET,
                :headers => {
                    "Authorization" => "Bearer " + token,
                    "anthropic-beta" => "oauth-2025-04-20",
                    "User-Agent" => CodexAuth.USER_AGENT,
                    "Accept" => "application/json"
                },
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
            },
            new Lang.Method($.UsageStore, :onUsage)
        );
    }

    function onUsage(code as Lang.Number, data as Lang.Dictionary or Lang.String or Null) as Void {
        System.println("cu usage " + code + (sRetried ? " (reintento)" : "")
            + ((code != 200) ? (" " + CodexAuth.errType(data)) : ""));
        // 429: /api/oauth/usage limita POR ACCESS TOKEN (anthropics/claude-code
        // #30930, 429 persistente con retry-after: 0). Un token nuevo trae cubo
        // nuevo: refrescar (el reloj tiene su propia cadena de tokens, no rompe
        // a nadie) y reintentar una vez. 401: token caducado, mismo camino.
        if (code == 401 || code == 429) {
            if (!sRetried) {
                sRetried = true;
                CodexAuth.forceRefresh(new Lang.Method($.UsageStore, :onToken));
                return;
            }
            if (code == 401) {
                finish(false, "Sesión caducada", RETRY_S);
            } else {
                finish(false, "API saturada (429)", RETRY_429_S);
            }
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
        var now = Time.now().value();
        var snap = parseSnapshot(data as Json);
        if (snap == null) {
            finish(false, "Respuesta inválida", RETRY_S);
            return;
        }
        ensure();
        sSnap = snap as Lang.Dictionary;
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
        var cbs = sCbs;
        sCbs = [];
        for (var i = 0; i < cbs.size(); i++) {
            (cbs[i] as Lang.Method).invoke(ok);
        }
    }

    // ------------------------------------------------------------------
    // Parseo
    // ------------------------------------------------------------------

    //! JSON de /api/oauth/usage -> instantánea; null si no hay ni sesión ni semana.
    function parseSnapshot(d as Json) as Json or Null {
        var s = null;
        var w = null;
        var models = [];

        var limits = d.get("limits");
        if (limits instanceof Lang.Array) {
            var arr = limits as Lang.Array;
            for (var i = 0; i < arr.size(); i++) {
                var lv = arr[i];
                if (!(lv instanceof Lang.Dictionary)) {
                    continue;
                }
                var l = lv as Json;
                var kind = l.get("kind");
                var it = item(l.get("percent"), l.get("resets_at"), l.get("severity"));
                if (it == null || !(kind instanceof Lang.String)) {
                    continue;
                }
                var k = kind as Lang.String;
                if (k.equals("session")) {
                    if (s == null) { s = it; }
                } else if (k.equals("weekly_all")) {
                    if (w == null) { w = it; }
                } else if (k.equals("weekly_scoped")) {
                    var e = {
                        "n" => scopeName(l.get("scope")),
                        "p" => it.get("p"),
                        "r" => it.get("r"),
                        "sv" => it.get("sv")
                    };
                    models.add(e);
                }
            }
        }
        if (s == null) {
            s = windowItem(d.get("five_hour"));
        }
        if (w == null) {
            w = windowItem(d.get("seven_day"));
        }
        if (s == null && w == null) {
            return null;
        }

        var out = { "m" => models, "b" => breakdown(d.get("seven_day_breakdown")),
                    "g" => grants(d.get("cedar_ember")), "x" => extra(d.get("extra_usage")) };
        if (s != null) { out.put("s", s); }
        if (w != null) { out.put("w", w); }
        return out;
    }

    //! { "p", "r", "sv" } o null si falta el porcentaje.
    function item(pct as Lang.Object or Null, resets as Lang.Object or Null,
            sev as Lang.Object or Null) as Lang.Dictionary or Null {
        var p = pctNumber(pct);
        if (p == null) {
            return null;
        }
        return {
            "p" => p,
            "r" => parseIso(resets),
            "sv" => (sev instanceof Lang.String) ? (sev as Lang.String) : null
        };
    }

    function windowItem(v as Lang.Object or Null) as Lang.Dictionary or Null {
        if (!(v instanceof Lang.Dictionary)) {
            return null;
        }
        var dd = v as Json;
        return item(dd.get("utilization"), dd.get("resets_at"), dd.get("severity"));
    }

    function scopeName(sc as Lang.Object or Null) as Lang.String {
        if (sc instanceof Lang.Dictionary) {
            var scd = sc as Json;
            var m = scd.get("model");
            if (m instanceof Lang.Dictionary) {
                var n = (m as Json).get("display_name");
                if (n instanceof Lang.String) {
                    return n as Lang.String;
                }
            }
            var sf = scd.get("surface");
            if (sf instanceof Lang.String) {
                return sf as Lang.String;
            }
            if (sf instanceof Lang.Dictionary) {
                var sn = (sf as Json).get("display_name");
                if (sn instanceof Lang.String) {
                    return sn as Lang.String;
                }
            }
        }
        return "Modelo";
    }

    function breakdown(v as Lang.Object or Null) as Lang.Array {
        var out = [];
        if (!(v instanceof Lang.Dictionary)) {
            return out;
        }
        var rows = (v as Json).get("rows");
        if (!(rows instanceof Lang.Array)) {
            return out;
        }
        var arr = rows as Lang.Array;
        for (var i = 0; i < arr.size(); i++) {
            var rv = arr[i];
            if (!(rv instanceof Lang.Dictionary)) {
                continue;
            }
            var r = rv as Json;
            var p = pctNumber(r.get("percent"));
            var n = r.get("display_name");
            if (!(n instanceof Lang.String)) {
                n = r.get("key");
            }
            if (p == null || !(n instanceof Lang.String)) {
                continue;
            }
            out.add({ "n" => n as Lang.String, "p" => p });
        }
        return out;
    }

    function grants(v as Lang.Object or Null) as Lang.Array {
        var out = [];
        if (!(v instanceof Lang.Dictionary)) {
            return out;
        }
        var gs = (v as Json).get("grants");
        if (!(gs instanceof Lang.Array)) {
            return out;
        }
        var arr = gs as Lang.Array;
        for (var i = 0; i < arr.size(); i++) {
            var gv = arr[i];
            if (!(gv instanceof Lang.Dictionary)) {
                continue;
            }
            var g = gv as Json;
            var leftF = asFloat(g.get("resets_left"));
            if (leftF == null || leftF <= 0.0) {
                continue;
            }
            var totF = asFloat(g.get("resets_total"));
            var tot = (totF == null) ? leftF.toNumber() : totF.toNumber();
            var lbl = g.get("label");
            var typ = g.get("type");
            var usable = g.get("usable_now");
            var paused = g.get("paused");
            out.add({
                "l" => (lbl instanceof Lang.String) ? (lbl as Lang.String) : "Restablecimiento",
                "t" => (typ instanceof Lang.String) ? (typ as Lang.String) : null,
                "left" => leftF.toNumber(),
                "tot" => tot,
                "e" => parseIso(g.get("ends_at")),
                "u" => (usable instanceof Lang.Boolean) ? (usable as Lang.Boolean) : false,
                "pz" => (paused instanceof Lang.Boolean) ? (paused as Lang.Boolean) : false
            });
        }
        return out;
    }

    function extra(v as Lang.Object or Null) as Lang.Dictionary {
        var on = false;
        var p = null;
        if (v instanceof Lang.Dictionary) {
            var d = v as Json;
            var en = d.get("is_enabled");
            on = (en instanceof Lang.Boolean) && (en as Lang.Boolean);
            p = pctNumber(d.get("utilization"));
        }
        return { "on" => on, "p" => p };
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
