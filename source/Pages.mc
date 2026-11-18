using Toybox.Lang;
using Toybox.Graphics;
using Toybox.Math;
using Toybox.Time;

//! Las 7 pantallas del ciclo (SPEC.md, "Pantallas"). Todas dibujan con Skin;
//! ninguna toca la red. La instantánea usa las claves de "Instantánea":
//!   "s" sesión 5 h · "w" semana 7 d · "o" otras ventanas · "a" límites
//!   adicionales · "cr" code review · "g"/"gc" reinicios · "x" créditos y
//!   spend control · "pl" plan_type · "al" allowed.
//!
//! Retícula común (líneas base a 260 px, todo escalado con Skin.sc):
//!   Uso       isotipo 24..54 · héroe 110 · etiqueta 130 · reinicio 151 ·
//!             filas 174/198/222 (semana, dinero, plan)
//!   Resto     título 58 · contenido desde ~80 · puntos de página a 245
//! Los puntos viven en el hueco inferior del anillo y el contenido acaba antes
//! de 226: nunca se pisan.
class Pages {
    private var k as Skin;
    private const RING_START = 225;     // arco de 270 grados con el hueco abajo
    private const RING_SWEEP = 270;

    private const Y_TITLE = 58;         // título de página (línea base)
    private const STALE_S = 1800;       // edad a partir de la que el pie avisa
    private const Y_ROW0 = 176;         // primera fila del pie de Uso
    private const ROW_PITCH = 24;       // filas del pie de Uso
    private const ROW_W = 140;          // ancho de las filas del pie

    // Geometría fija del anillo (calculada una vez)
    private var mRingR as Lang.Number;
    private var mPen as Lang.Number;
    private var mCapR as Lang.Number;
    private var mP0 as Lang.Array<Lang.Number>;
    private var mP1 as Lang.Array<Lang.Number>;
    private var mTrackEnd as Lang.Number;

    // Memos por (versión de datos, minuto): ritmo [sesión, semana] y puntos de Actividad
    private var mPaceVer as Lang.Array<Lang.Number> = [-1, -1];
    private var mPaceMin as Lang.Array<Lang.Number> = [-1, -1];
    private var mPace as Lang.Array = [null, null];
    private var mActVer as Lang.Number = -1;
    private var mActMin as Lang.Number = -1;
    private var mActPts as Lang.Array = [];

    function initialize(skin as Skin, dc as Graphics.Dc) {
        k = skin;
        mRingR = k.sc(118);
        mPen = k.sc1(9);
        mCapR = mPen / 2;
        mP0 = ringPoint(RING_START, mRingR);
        mP1 = ringPoint(arcEnd(RING_SWEEP), mRingR);
        mTrackEnd = arcEnd(RING_SWEEP - 1);
    }

    //! Ritmo memoizado: una vez por versión de datos y minuto (no por frame).
    private function paceFor(week as Lang.Boolean, p as Lang.Number, r as Lang.Number or Null,
                             now as Lang.Number) as Lang.Dictionary or Null {
        var i = week ? 1 : 0;
        var m = now / 60;
        var v = UsageStore.version();
        if (mPaceVer[i] != v || mPaceMin[i] != m) {
            mPace[i] = UsageMath.pace(p, r, week ? UsageMath.WEEK_S : UsageMath.SESSION_S, now);
            mPaceVer[i] = v;
            mPaceMin[i] = m;
        }
        return mPace[i] as Lang.Dictionary or Null;
    }

    // -------------------------------------------------------------------------
    // Utilidades
    // -------------------------------------------------------------------------

    private function num(v as Lang.Numeric or Null) as Lang.Number {
        return (v == null) ? 0 : v.toNumber();
    }

    private function dict(snap as Lang.Dictionary, key as Lang.String) as Lang.Dictionary or Null {
        return snap[key] as Lang.Dictionary or Null;
    }

    //! Sesión / semana: Dictionary con "p", "r", "sv".
    private function lvOf(e as Lang.Dictionary) as Lang.Number {
        return k.pal.level(e["sv"] as Lang.String or Null, num(e["p"] as Lang.Numeric or Null));
    }

    //! rate_limit.allowed: false ⇒ límite alcanzado (manda sobre los %).
    private function blocked(snap as Lang.Dictionary) as Lang.Boolean {
        var al = snap["al"];
        if (!(al instanceof Lang.Boolean)) {
            return false;
        }
        return !(al as Lang.Boolean);
    }

    //! plan_type del cliente (codex-rs): free, plus, pro, team…
    private function planName(p as Lang.String or Null) as Lang.String {
        if (p == null || p.length() == 0) {
            return "—";
        }
        if (p.equals("free")) { return "Free"; }
        if (p.equals("guest")) { return "Invitado"; }
        if (p.equals("go")) { return "Go"; }
        if (p.equals("plus")) { return "Plus"; }
        if (p.equals("pro")) { return "Pro"; }
        if (p.equals("prolite")) { return "Pro Lite"; }
        if (p.equals("promax")) { return "Pro Max"; }
        if (p.equals("team")) { return "Team"; }
        if (p.equals("business")) { return "Business"; }
        return p;
    }

    //! Nombre corto para las filas de "Otros límites".
    private function shortName(n as Lang.String) as Lang.String {
        if (n.find("GPT-Codex-") == 0) {
            return n.substring(10, n.length()) as Lang.String;
        }
        if (n.find("codex_") == 0) {
            return n.substring(6, n.length()) as Lang.String;
        }
        return n;
    }

    //! Título del reset credit en español (la API lo manda en inglés).
    private function resetTitle(l as Lang.String or Null) as Lang.String {
        if (l == null || l.length() == 0) {
            return "Reinicio";
        }
        if (l.find("Full reset") != null || l.find("full reset") != null) {
            return "Reinicio completo";
        }
        if (l.find("Weekly") != null) {
            return "Reinicio semanal";
        }
        return l;
    }

    //! Valor de la fila de créditos.
    private function balText(x as Lang.Dictionary) as Lang.String {
        var unl = x["unl"];
        if (unl instanceof Lang.Boolean && (unl as Lang.Boolean)) {
            return "Ilimitados";
        }
        var bal = x["bal"];
        var f = null as Lang.Float or Null;
        if (bal instanceof Lang.Float) {
            f = bal as Lang.Float;
        } else if (bal instanceof Lang.Double) {
            f = (bal as Lang.Double).toFloat();
        } else if (bal instanceof Lang.Number) {
            f = (bal as Lang.Number).toFloat();
        }
        if (f == null) {
            return "Sí";
        }
        return (f as Lang.Float).toNumber().toString();
    }

    private function ringPoint(a as Lang.Number, r as Lang.Number) as Lang.Array<Lang.Number> {
        var rad = Math.toRadians(a);
        return [k.cx + (r * Math.cos(rad)).toNumber(), k.cy - (r * Math.sin(rad)).toNumber()] as Lang.Array<Lang.Number>;
    }

    private function arcEnd(sweep as Lang.Number) as Lang.Number {
        var e = (RING_START - sweep) % 360;
        return (e < 0) ? e + 360 : e;
    }

    //! Cifra héroe: el número y el "%" en la misma mono tabular (así comparten
    //! línea base y ancho), con el % en gris para que el número mande.
    private function hero(dc as Graphics.Dc, txt as Lang.String, base as Lang.Number,
                          color as Lang.Number) as Void {
        var nw = dc.getTextWidthInPixels(txt, k.fHero);
        var pw = dc.getTextWidthInPixels("%", k.fHero);
        var hx = k.cx - (nw + k.sc(2) + pw) / 2;
        k.text(dc, hx, base, k.fHero, txt, color, Graphics.TEXT_JUSTIFY_LEFT);
        k.text(dc, hx + nw + k.sc(2), base, k.fHero, "%", k.pal.dim, Graphics.TEXT_JUSTIFY_LEFT);
    }

    //! Renglón centrado y tenue con la cuerda del círculo en su línea base.
    private function caption(dc as Graphics.Dc, txt as Lang.String, base as Lang.Number,
                             color as Lang.Number) as Void {
        k.text(dc, k.cx, base, k.fSmall,
               k.fit(dc, txt, k.fSmall, k.chord(dc, k.fSmall, base)), color,
               Graphics.TEXT_JUSTIFY_CENTER);
    }

    // -------------------------------------------------------------------------
    // Estados sin datos
    // -------------------------------------------------------------------------

    //! Isotipo + titular + párrafo (login, sin datos, cargando, error).
    function drawNotice(dc as Graphics.Dc, head as Lang.String, msg as Lang.String,
                        msgColor as Lang.Number) as Void {
        k.mark(dc, k.sc(40), k.cy - k.sc(72));
        k.title(dc, head, k.cy + k.sc(4));
        // 4 líneas: el aviso de login por portátil es largo
        k.para(dc, msg, k.fSmall, k.cy + k.sc(16), k.hSmall, 4, msgColor);
    }

    // -------------------------------------------------------------------------
    // 1 · Principal "Uso"
    // -------------------------------------------------------------------------

    //! Anillo de la sesión de 5 h; en free (sin sesión) el de la semanal.
    //! Dentro: isotipo (marca, sin el nombre de la app), % de la ventana y hora
    //! de reinicio. Debajo, tres filas por importancia: semana, dinero, plan.
    function drawMain(dc as Graphics.Dc, snap as Lang.Dictionary, now as Lang.Number,
                      status as Lang.String or Null, warn as Lang.Boolean) as Void {
        var pal = k.pal;
        var s = dict(snap, "s");
        var w = dict(snap, "w");
        var main = (s != null) ? s : w;
        var pct = (main == null) ? 0 : num(main["p"] as Lang.Numeric or Null);
        var block = blocked(snap);
        var lv = (main == null) ? 0 : lvOf(main);
        if (block) { lv = 2; }
        if (pct > 100) { pct = 100; }

        // anillo: pista + progreso, con puntas redondas
        var r = mRingR;
        var capR = mCapR;
        var p0 = mP0;
        dc.setPenWidth(mPen);
        dc.setColor(pal.track(lv), Graphics.COLOR_TRANSPARENT);
        dc.drawArc(k.cx, k.cy, r, Graphics.ARC_CLOCKWISE, RING_START, mTrackEnd);
        dc.fillCircle(p0[0], p0[1], capR);
        dc.fillCircle(mP1[0], mP1[1], capR);
        var sweep = (RING_SWEEP * pct / 100.0).toNumber();
        if (pct > 0 && sweep < 3) { sweep = 3; }
        if (sweep > 0) {
            dc.setColor(pal.fill(lv), Graphics.COLOR_TRANSPARENT);
            if (sweep >= RING_SWEEP) { sweep = RING_SWEEP - 1; }
            dc.drawArc(k.cx, k.cy, r, Graphics.ARC_CLOCKWISE, RING_START, arcEnd(sweep));
            var pe = ringPoint(arcEnd(sweep), r);
            dc.fillCircle(p0[0], p0[1], capR);
            dc.fillCircle(pe[0], pe[1], capR);
        }
        dc.setPenWidth(1);

        // marca: el isotipo solo y grande (el launcher y el móvil ya dan el nombre)
        k.mark(dc, k.sc(34), k.sc(21));

        // héroe: % de la ventana principal, en mono tabular
        hero(dc, pct.toString(), k.sc(112), pal.text);

        // qué ventana es (o el estado de red) y cuándo se reinicia
        var label = (s != null) ? "Sesión · 5 h" : "Semanal · 7 d";
        if (block) {
            label = "Límite alcanzado";
        } else if (status != null) {
            label = status;
        }
        var lc = block ? pal.fill(2) : ((status != null && warn) ? pal.amber : pal.dim);
        caption(dc, label, k.sc(132), lc);
        if (main != null && main["r"] != null) {
            caption(dc, "Restablece " + Fmt.resetWhen(num(main["r"] as Lang.Numeric or Null), now),
                    k.sc(153), pal.text);
        }

        // filas: semana (si el anillo es la sesión), dinero, plan (lo más estático)
        var rows = [] as Lang.Array;
        if (s != null && w != null) {
            var wp = num(w["p"] as Lang.Numeric or Null);
            var wl = pal.level(w["sv"] as Lang.String or Null, wp);
            rows.add(["Semana", Fmt.pct(wp), (wl > 0) ? pal.fill(wl) : pal.text]);
        }
        var x = dict(snap, "x");
        if (x != null) {
            var scReached = x["sc"];
            var hasCredits = x["on"];
            var scPct = x["scp"] as Lang.Numeric or Null;
            if (scReached instanceof Lang.Boolean && (scReached as Lang.Boolean)) {
                var sp = num(scPct);
                rows.add(["Gasto", Fmt.pct(sp), pal.fill(pal.level(null, sp))]);
            } else if (hasCredits instanceof Lang.Boolean && (hasCredits as Lang.Boolean)) {
                rows.add(["Créditos", balText(x), pal.text]);
            } else if (scPct != null) {
                // spend control configurado (aún sin alcanzar): % del límite
                var sp2 = num(scPct);
                rows.add(["Gasto", Fmt.pct(sp2),
                          (sp2 >= 70) ? pal.fill(pal.level(null, sp2)) : pal.text]);
            }
        }
        rows.add(["Plan", planName(snap["pl"] as Lang.String or Null), pal.dim]);

        var rw = k.sc(ROW_W);
        var rx = k.cx - rw / 2;
        for (var i = 0; i < rows.size(); i++) {
            var row = rows[i] as Lang.Array;
            k.kvRow(dc, rx, rx + rw, k.sc(Y_ROW0) + i * k.sc(ROW_PITCH),
                    row[0] as Lang.String, row[1] as Lang.String, pal.dim, row[2] as Lang.Number);
        }
    }

    // -------------------------------------------------------------------------
    // 2 · Límites semanales
    // -------------------------------------------------------------------------

    //! La semana como ficha: héroe (% usado), barra ancha y reinicio. La edad
    //! del dato va de pie, separada del bloque que describe.
    function drawWeekly(dc as Graphics.Dc, snap as Lang.Dictionary, now as Lang.Number,
                        fetched as Lang.Number or Null) as Void {
        var pal = k.pal;
        k.title(dc, "Esta semana", k.sc(Y_TITLE));
        var w = dict(snap, "w");
        if (w == null) {
            k.para(dc, "Sin ventana semanal", k.fSmall, k.sc(104), k.hSmall, 2, pal.dim);
            return;
        }
        var p = num(w["p"] as Lang.Numeric or Null);
        var lv = lvOf(w);
        hero(dc, p.toString(), k.sc(112), (lv >= 1) ? pal.fill(lv) : pal.text);
        caption(dc, "usado · todos los modelos", k.sc(134), pal.dim);
        var bw = k.sc(176);
        k.bar(dc, k.cx - bw / 2, k.sc(152), bw, k.sc1(8), p, lv);
        var r = (w["r"] == null) ? null : num(w["r"] as Lang.Numeric or Null);
        if (r != null) {
            caption(dc, "Restablece " + Fmt.resetWhen(r, now), k.sc(180), pal.text);
        }
        // ritmo ideal: a qué % irías si gastaras de forma constante (mismo criterio
        // que las pantallas de proyección, sin repetir su barra)
        var pace = paceFor(true, p, r, now);
        if (pace != null) {
            var rw = k.sc(ROW_W);
            k.kvRow(dc, k.cx - rw / 2, k.cx + rw / 2, k.sc(206), "Ritmo ideal",
                    Fmt.pct((pace["el"] as Lang.Numeric).toFloat() * 100), pal.dim, pal.text);
        }
        // pie: solo si el dato está viejo (recién sincronizado, la página no lo dice)
        if (fetched != null && now - fetched > STALE_S) {
            caption(dc, "Datos de " + Fmt.ago(fetched, now), k.sc(224), pal.amber);
        }
    }

    // -------------------------------------------------------------------------
    // 3 · Otros límites (antes "Superficies"): additional + code review + otras
    // -------------------------------------------------------------------------

    //! Cada límite es un bloque de tres renglones con aire entre bloques:
    //! nombre + % (misma línea base), barra, y reinicio (o duración) tenue.
    function drawOther(dc as Graphics.Dc, snap as Lang.Dictionary, now as Lang.Number) as Void {
        var pal = k.pal;
        k.title(dc, "Otros límites", k.sc(Y_TITLE));
        var items = [] as Lang.Array;
        var a = snap["a"] as Lang.Array or Null;
        if (a != null) {
            for (var i = 0; i < a.size(); i++) {
                items.add(addDur(a[i] as Lang.Dictionary));
            }
        }
        var cr = dict(snap, "cr");
        if (cr != null) {
            items.add({ "n" => "Code review", "p" => cr["p"], "r" => cr["r"],
                        "sec" => null, "d" => true });
        }
        var o = snap["o"] as Lang.Array or Null;
        if (o != null) {
            for (var i = 0; i < o.size(); i++) {
                // el nombre de estas ventanas ya dice la duración ("Ventana 2 h")
                var oc = addDur(o[i] as Lang.Dictionary);
                oc["d"] = false;
                items.add(oc);
            }
        }
        if (items.size() == 0) {
            k.para(dc, "Sin otros límites", k.fSmall, k.sc(104), k.hSmall, 2, pal.dim);
            return;
        }

        var rw = k.sc(176);
        var rx = k.cx - rw / 2;
        var n = items.size();
        var shown = (n > 3) ? 3 : n;
        var y0 = k.sc((n > 3) ? 86 : 90);
        var pitch = k.sc((n > 3) ? 48 : 54);
        for (var i = 0; i < shown; i++) {
            var it = items[i] as Lang.Dictionary;
            var p = num(it["p"] as Lang.Numeric or Null);
            var pt = Fmt.pct(p);
            var ptw = dc.getTextWidthInPixels(pt, k.fBody);
            var space = rw - ptw - k.sc(8);
            var raw = it["n"] as Lang.String or Null;
            var name = k.fit(dc, shortName((raw == null) ? "?" : raw), k.fBody, space);
            var base = y0 + i * pitch;

            k.text(dc, rx, base, k.fBody, name, pal.text, Graphics.TEXT_JUSTIFY_LEFT);
            k.text(dc, rx + rw, base, k.fBody, pt, pal.text, Graphics.TEXT_JUSTIFY_RIGHT);

            // duración del ciclo detrás del nombre, si el nombre no la lleva ya
            var sec = it["sec"] as Lang.Numeric or Null;
            var withDur = it["d"];
            if (withDur instanceof Lang.Boolean && (withDur as Lang.Boolean) && sec != null) {
                var nw = dc.getTextWidthInPixels(name, k.fBody);
                var dt = " · " + UsageStore.durationName(sec.toNumber());
                if (nw + dc.getTextWidthInPixels(dt, k.fSmall) < space) {
                    k.text(dc, rx + nw, base, k.fSmall, dt, pal.dim, Graphics.TEXT_JUSTIFY_LEFT);
                }
            }

            k.bar(dc, rx, base + k.sc(7), rw, k.sc1(4), p, pal.level(null, p));

            var r = it["r"] as Lang.Numeric or Null;
            if (r != null) {
                k.text(dc, rx, base + k.sc(27), k.fSmall,
                       k.fit(dc, "Restablece " + Fmt.resetWhen(r.toNumber(), now), k.fSmall, rw),
                       pal.dim, Graphics.TEXT_JUSTIFY_LEFT);
            } else if (sec != null) {
                k.text(dc, rx, base + k.sc(27), k.fSmall,
                       "Cada " + UsageStore.durationName(sec.toNumber()), pal.dim,
                       Graphics.TEXT_JUSTIFY_LEFT);
            }
        }
        if (n > shown) {
            caption(dc, "y " + (n - shown) + " más", k.sc(230), pal.dim);
        }
    }

    //! Copia el límite adicional con la marca "d" (lleva duración detrás del
    //! nombre): no se muta el diccionario de la instantánea, que está en caché.
    private function addDur(e as Lang.Dictionary) as Lang.Dictionary {
        return { "n" => e["n"], "p" => e["p"], "r" => e["r"], "sec" => e["sec"], "d" => true };
    }

    // -------------------------------------------------------------------------
    // 4/5 · Proyección (sesión 5 h / semana 7 d)
    // -------------------------------------------------------------------------

    function drawProj(dc as Graphics.Dc, snap as Lang.Dictionary, now as Lang.Number,
                      week as Lang.Boolean) as Void {
        var pal = k.pal;
        k.title(dc, week ? "Semana · 7 d" : "Sesión · 5 h", k.sc(Y_TITLE));
        var e = dict(snap, week ? "w" : "s");
        if (e == null) {
            k.para(dc, week ? "Sin ventana semanal" : "Sin ventana de 5 h", k.fSmall,
                k.sc(104), k.hSmall, 2, pal.dim);
            return;
        }
        var p = num(e["p"] as Lang.Numeric or Null);
        var r = (e["r"] == null) ? null : num(e["r"] as Lang.Numeric or Null);
        var pace = paceFor(week, p, r, now);

        var proj = (pace == null) ? p.toFloat() : (pace["proj"] as Lang.Numeric).toFloat();
        var lv = (proj >= 100) ? 2 : ((proj >= 80) ? 1 : 0);
        if (p >= 100) { lv = 2; }

        // héroe: % previsto al reinicio
        var shown = proj.toNumber();
        if (shown > 999) { shown = 999; }
        hero(dc, shown.toString(), k.sc(108), (lv >= 1) ? pal.fill(lv) : pal.text);
        caption(dc, "previsto al reinicio", k.sc(130), pal.dim);

        // barra: uso real + marca del ritmo ideal (tiempo transcurrido)
        var bw = k.sc(172);
        var bx = k.cx - bw / 2;
        var by = k.sc(148);
        var bh = k.sc1(7);
        k.bar(dc, bx, by, bw, bh, p, lv);
        var left = "Usado " + Fmt.pct(p);
        var right = "";
        if (pace != null) {
            var el = (pace["el"] as Lang.Numeric).toFloat();
            var tx = bx + (bw * el).toNumber();
            dc.setColor(pal.text, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(k.sc1(2));
            dc.drawLine(tx, by - k.sc(3), tx, by + bh + k.sc(3));
            dc.setPenWidth(1);
            right = "Ritmo " + Fmt.pct(el * 100);
        }
        var ly = by + bh + k.hSmall;
        k.text(dc, bx, ly, k.fSmall, left, pal.dim, Graphics.TEXT_JUSTIFY_LEFT);
        k.text(dc, bx + bw, ly, k.fSmall, right, pal.dim, Graphics.TEXT_JUSTIFY_RIGHT);

        // veredicto: frase corta (3 líneas máx.), el color solo si hay aviso
        var verdict;
        var vc = pal.text;
        if (p >= 100) {
            verdict = "Límite alcanzado." + ((r == null) ? "" : " Se restablece " + Fmt.resetAt(r, now) + ".");
            vc = pal.fill(2);
        } else if (pace == null) {
            verdict = "Aún sin datos para estimar tu ritmo.";
            vc = pal.dim;
        } else if (pace["ex"] != null) {
            var ex = num(pace["ex"] as Lang.Numeric or Null);
            if (week) {
                verdict = "Se agotará " + Fmt.whenPhrase(ex, now) + ", antes del reinicio.";
            } else {
                verdict = "Se agotará a las " + Fmt.clock(ex) + ", antes del reinicio.";
            }
            vc = pal.fill(2);
        } else if (lv == 1) {
            verdict = "Cuidado: llegarás al reinicio con un " + shown + "%.";
            vc = pal.fill(1);
        } else {
            verdict = "Llegarás al reinicio con un " + shown + "% usado.";
        }
        k.para(dc, verdict, k.fSmall, k.sc(176), k.hSmall, 3, vc);
    }

    // -------------------------------------------------------------------------
    // 6 · Actividad
    // -------------------------------------------------------------------------

    function drawActivity(dc as Graphics.Dc, snap as Lang.Dictionary, now as Lang.Number,
                          hist as Lang.Array) as Void {
        var pal = k.pal;
        k.title(dc, "Actividad", k.sc(Y_TITLE));
        var w = dict(snap, "w");
        var r = (w == null || w["r"] == null) ? null : num(w["r"] as Lang.Numeric or Null);

        var x0 = k.cx - k.sc(80);
        var x1 = k.cx + k.sc(80);
        var yTop = k.sc(78);
        var yBot = k.sc(178);
        var cw = x1 - x0;
        var chh = yBot - yTop;

        // ventana semanal [t0, t1]; los puntos se recalculan solo si cambian los datos
        var t1 = (r != null) ? r : now;
        var ver = UsageStore.version();
        if (ver != mActVer || t1 / 60 != mActMin) {
            var t0 = t1 - UsageMath.WEEK_S;
            var pts = [] as Lang.Array;
            for (var i = 0; i < hist.size(); i++) {
                var smp = hist[i];
                if (!(smp instanceof Lang.Array) || (smp as Lang.Array).size() < 3) {
                    continue;
                }
                var sa = smp as Lang.Array;
                var te = num(sa[0] as Lang.Numeric or Null);
                if (te >= t0 && te <= t1) {
                    pts.add([x0 + (cw * (te - t0).toFloat() / UsageMath.WEEK_S).toNumber(),
                             yBot - (chh * num(sa[2] as Lang.Numeric or Null) / 100.0).toNumber()]);
                }
            }
            mActPts = pts;
            mActVer = ver;
            mActMin = t1 / 60;
        }
        var pts2 = mActPts;

        // sin historial suficiente: solo el título y el aviso (nada de gráfico)
        if (pts2.size() < 2) {
            k.para(dc, "Aún sin historial. Se rellena con cada actualización.", k.fSmall,
                (yTop + yBot) / 2 - k.hSmall, k.hSmall, 3, pal.dim);
            return;
        }

        // rejilla: 0, 50 y 100 %
        dc.setColor(pal.faint, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(1);
        for (var g = 0; g <= 2; g++) {
            var gy = yBot - chh * g / 2;
            dc.drawLine(x0, gy, x1, gy);
        }

        // ritmo ideal (discontinua)
        dc.setColor(pal.dim, Graphics.COLOR_TRANSPARENT);
        var seg = 8;
        for (var i = 0; i < seg; i += 2) {
            dc.drawLine(x0 + cw * i / seg, yBot - chh * i / seg,
                        x0 + cw * (i + 1) / seg, yBot - chh * (i + 1) / seg);
        }

        // curva real
        dc.setColor(pal.brand, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(k.sc1(3));
        for (var i = 1; i < pts2.size(); i++) {
            var a = pts2[i - 1] as Lang.Array;
            var b = pts2[i] as Lang.Array;
            dc.drawLine(a[0] as Lang.Number, a[1] as Lang.Number, b[0] as Lang.Number, b[1] as Lang.Number);
        }
        dc.setPenWidth(1);
        var last = pts2[pts2.size() - 1] as Lang.Array;
        dc.fillCircle(last[0] as Lang.Number, last[1] as Lang.Number, k.sc1(4));

        // etiquetas del eje
        var ay = yBot + k.sc(12);
        k.text(dc, x0, ay, k.fSmall, "Hace 7 d", pal.dim, Graphics.TEXT_JUSTIFY_LEFT);
        k.text(dc, x1, ay, k.fSmall, "Reinicio", pal.dim, Graphics.TEXT_JUSTIFY_RIGHT);

        // leyenda
        var ly = ay + k.sc(24);
        dc.setColor(pal.brand, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(k.sc1(3));
        dc.drawLine(k.cx - k.sc(78), ly - k.sc(4), k.cx - k.sc(64), ly - k.sc(4));
        dc.setPenWidth(1);
        k.text(dc, k.cx - k.sc(58), ly, k.fSmall, "Real", pal.text, Graphics.TEXT_JUSTIFY_LEFT);
        dc.setColor(pal.dim, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(k.cx + k.sc(2), ly - k.sc(4), k.cx + k.sc(8), ly - k.sc(4));
        dc.drawLine(k.cx + k.sc(12), ly - k.sc(4), k.cx + k.sc(18), ly - k.sc(4));
        k.text(dc, k.cx + k.sc(24), ly, k.fSmall, "Ideal", pal.dim, Graphics.TEXT_JUSTIFY_LEFT);
    }

    // -------------------------------------------------------------------------
    // 7 · Reinicios (reset credits disponibles, solo lectura)
    // -------------------------------------------------------------------------

    function drawResets(dc as Graphics.Dc, snap as Lang.Dictionary, now as Lang.Number) as Void {
        var pal = k.pal;
        var gs = snap["g"] as Lang.Array or Null;
        var gc = snap["gc"] as Lang.Numeric or Null;
        var count = (gc == null) ? ((gs == null) ? 0 : gs.size()) : gc.toNumber();
        k.title(dc, (count > 0) ? "Reinicios · " + count : "Reinicios", k.sc(Y_TITLE));
        if (gs == null || gs.size() == 0) {
            k.para(dc, (count > 0) ? "Tienes " + count + " reinicio(s) disponible(s)" : "No tienes reinicios disponibles",
                k.fSmall, k.sc(110), k.hSmall, 3, pal.dim);
            return;
        }
        var n = (gs.size() > 3) ? 3 : gs.size();
        var cw = k.sc(188);
        var cx0 = k.cx - cw / 2;
        var pad = k.sc(12);
        // con una o dos tarjetas hay sitio: más altas y centradas en el hueco
        var ch = k.sc((n >= 3) ? 46 : 56);
        var gap = k.sc(8);
        var total = n * ch + (n - 1) * gap;
        var y = k.sc(74) + (((n >= 3) ? 0 : (k.sc(162) - total) / 2));
        for (var i = 0; i < n; i++) {
            var g = gs[i] as Lang.Dictionary;
            k.card(dc, cx0, y, cw, ch);
            var name = resetTitle(g["l"] as Lang.String or Null);
            k.text(dc, cx0 + pad, y + ch * 2 / 5, k.fBody,
                   k.fit(dc, name, k.fBody, cw - 2 * pad), pal.text, Graphics.TEXT_JUSTIFY_LEFT);
            var cap;
            if (g["e"] != null) {
                cap = "Caduca " + Fmt.expiry(num(g["e"] as Lang.Numeric or Null), now);
            } else {
                cap = "Disponible";
            }
            k.text(dc, cx0 + pad, y + ch * 4 / 5, k.fSmall,
                   k.fit(dc, cap, k.fSmall, cw - 2 * pad), pal.dim, Graphics.TEXT_JUSTIFY_LEFT);
            y += ch + gap;
        }
    }
}
