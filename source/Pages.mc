using Toybox.Lang;
using Toybox.Graphics;
using Toybox.Math;
using Toybox.Time;

//! Las 7 pantallas del ciclo (la 2.ª del SPEC, "Límites semanales", se reparte
//! en tarjetas + "Por superficie"). Todas dibujan con Skin; ninguna toca la red.
class Pages {
    private var k as Skin;
    private const RING_START = 225;     // arco de 270 grados con el hueco abajo
    private const RING_SWEEP = 270;

    // Geometría fija del anillo y la cabecera (calculada una vez)
    private var mRingR as Lang.Number;
    private var mPen as Lang.Number;
    private var mCapR as Lang.Number;
    private var mP0 as Lang.Array<Lang.Number>;
    private var mP1 as Lang.Array<Lang.Number>;
    private var mTrackEnd as Lang.Number;
    private var mHeadX0 as Lang.Number;
    private var mHeadSz as Lang.Number;
    private var mPctW as Lang.Number;       //!< ancho de "%" en la fuente de título

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
        mHeadSz = k.sc(20);
        mPctW = dc.getTextWidthInPixels("%", k.fTitle);
        mHeadX0 = k.cx - (mHeadSz + k.sc(6) + dc.getTextWidthInPixels("Codex", k.fTitle)) / 2;
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

    private function modelName(m as Lang.Dictionary) as Lang.String {
        var n = m["n"] as Lang.String or Null;
        return (n == null) ? "Modelo" : n;
    }

    private function surfaceName(n as Lang.String) as Lang.String {
        if (n.equals("Other")) { return "Otros"; }
        if (n.equals("Chat")) { return "Chats"; }
        return n;
    }

    private function ringPoint(a as Lang.Number, r as Lang.Number) as Lang.Array<Lang.Number> {
        var rad = Math.toRadians(a);
        return [k.cx + (r * Math.cos(rad)).toNumber(), k.cy - (r * Math.sin(rad)).toNumber()] as Lang.Array<Lang.Number>;
    }

    private function arcEnd(sweep as Lang.Number) as Lang.Number {
        var e = (RING_START - sweep) % 360;
        return (e < 0) ? e + 360 : e;
    }

    // -------------------------------------------------------------------------
    // Estados sin datos
    // -------------------------------------------------------------------------

    //! Spark + titular serif + párrafo (login, sin datos, cargando, error).
    function drawNotice(dc as Graphics.Dc, head as Lang.String, msg as Lang.String,
                        msgColor as Lang.Number) as Void {
        var sp = k.sc(50);
        Logo.draw(dc, k.cx, k.cy - k.sc(52), sp, k.pal.brand);
        k.title(dc, head, k.cy + k.sc(18));
        k.para(dc, msg, k.fSmall, k.cy + k.sc(30), k.hSmall, 3, msgColor);
    }

    // -------------------------------------------------------------------------
    // 1 · Principal "Uso"
    // -------------------------------------------------------------------------

    function drawMain(dc as Graphics.Dc, snap as Lang.Dictionary, now as Lang.Number,
                      status as Lang.String or Null, warn as Lang.Boolean) as Void {
        var pal = k.pal;
        var s = dict(snap, "s");
        var pct = (s == null) ? 0 : num(s["p"] as Lang.Numeric or Null);
        var lv = (s == null) ? 0 : lvOf(s);
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

        // cabecera: spark + "Codex"
        var hb = k.sc(63);
        var sz = mHeadSz;
        Logo.draw(dc, mHeadX0 + sz / 2, hb - k.sc(8), sz, pal.brand);
        k.text(dc, mHeadX0 + sz + k.sc(6), hb, k.fTitle, "Codex", pal.text, Graphics.TEXT_JUSTIFY_LEFT);

        // héroe: % de la sesión en serif grande
        var base = k.sc(118);
        var n = pct.toString();
        var nw = dc.getTextWidthInPixels(n, k.fHero);
        var hx = k.cx - (nw + k.sc(3) + mPctW) / 2;
        k.text(dc, hx, base, k.fHero, n, pal.text, Graphics.TEXT_JUSTIFY_LEFT);
        k.text(dc, hx + nw + k.sc(3), base, k.fTitle, "%", pal.dim, Graphics.TEXT_JUSTIFY_LEFT);

        // etiqueta + reinicio
        var ly = k.sc(124);
        var label = (status != null) ? status : "Sesión actual";
        var lc = (status != null) ? (warn ? pal.amber : pal.dim) : pal.dim;
        dc.setColor(lc, Graphics.COLOR_TRANSPARENT);
        dc.drawText(k.cx, ly, k.fSmall, k.fit(dc, label, k.fSmall, 2 * k.half(ly, k.hSmall)), Graphics.TEXT_JUSTIFY_CENTER);
        if (s != null && s["r"] != null) {
            var rs = "Se restablece " + Fmt.resetWhen(num(s["r"] as Lang.Numeric or Null), now);
            var ry = ly + k.hSmall;
            dc.setColor(pal.text, Graphics.COLOR_TRANSPARENT);
            dc.drawText(k.cx, ry, k.fSmall, k.fit(dc, rs, k.fSmall, 2 * k.half(ry, k.hSmall) - k.sc(8)), Graphics.TEXT_JUSTIFY_CENTER);
        }

        // límites semanales compactos
        var rows = [] as Lang.Array;
        var w = dict(snap, "w");
        if (w != null) { rows.add(["Semana", num(w["p"] as Lang.Numeric or Null), lvOf(w)]); }
        var ms = snap["m"] as Lang.Array or Null;
        if (ms != null && ms.size() > 0) {
            var m0 = ms[0] as Lang.Dictionary;
            rows.add([modelName(m0), num(m0["p"] as Lang.Numeric or Null), lvOf(m0)]);
        }
        var rw = k.sc(132);
        var rx = k.cx - rw / 2;
        var ry0 = k.sc(168);
        var pitch = k.hSmall + k.sc(7);
        for (var i = 0; i < rows.size(); i++) {
            var row = rows[i] as Lang.Array;
            var y = ry0 + i * pitch;
            dc.setColor(pal.dim, Graphics.COLOR_TRANSPARENT);
            dc.drawText(rx, y, k.fSmall, k.fit(dc, row[0] as Lang.String, k.fSmall, rw - k.sc(40)), Graphics.TEXT_JUSTIFY_LEFT);
            dc.setColor(pal.text, Graphics.COLOR_TRANSPARENT);
            dc.drawText(rx + rw, y, k.fSmall, Fmt.pct(row[1] as Lang.Number), Graphics.TEXT_JUSTIFY_RIGHT);
            k.bar(dc, rx, y + k.hSmall + k.sc(1), rw, k.sc1(4), row[1] as Lang.Number, row[2] as Lang.Number);
        }
    }

    // -------------------------------------------------------------------------
    // 2 · Límites semanales (tarjetas)
    // -------------------------------------------------------------------------

    function drawWeekly(dc as Graphics.Dc, snap as Lang.Dictionary, now as Lang.Number,
                        fetched as Lang.Number or Null) as Void {
        var pal = k.pal;
        k.title(dc, "Esta semana", k.sc(50));
        var items = [] as Lang.Array;
        var w = dict(snap, "w");
        if (w != null) { items.add(["Todos los modelos", w]); }
        var ms = snap["m"] as Lang.Array or Null;
        if (ms != null) {
            for (var i = 0; i < ms.size() && items.size() < 3; i++) {
                var m = ms[i] as Lang.Dictionary;
                items.add(["Solo " + modelName(m), m]);
            }
        }
        var compact = items.size() >= 3;
        var cw = k.sc(196);
        var cx0 = k.cx - cw / 2;
        var pad = k.sc(10);
        var ch = compact ? k.sc(38) : k.sc(68);
        var gapY = k.sc(4);
        var y = k.sc(60);
        // una sola fuente de etiqueta para todas las tarjetas: la grande si caben todas
        var lfAll = k.fBody;
        for (var i = 0; i < items.size(); i++) {
            var itl = items[i] as Lang.Array;
            if (compact || dc.getTextWidthInPixels(itl[0] as Lang.String, k.fBody) > cw - 2 * pad - k.sc(48)) {
                lfAll = k.fSmall;
            }
        }
        for (var i = 0; i < items.size(); i++) {
            var it = items[i] as Lang.Array;
            var e = it[1] as Lang.Dictionary;
            var p = num(e["p"] as Lang.Numeric or Null);
            var lv = lvOf(e);
            k.card(dc, cx0, y, cw, ch);
            var iw = cw - 2 * pad;
            var lf = lfAll;
            var pt = Fmt.pct(p);
            if (!compact && lf == k.fBody) { pt += " usado"; }
            var ptw = dc.getTextWidthInPixels(pt, k.fSmall);
            var ly = y + (compact ? k.sc(3) : k.sc(7));
            dc.setColor(pal.text, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx0 + pad, ly, lf, k.fit(dc, it[0] as Lang.String, lf, iw - ptw - k.sc(6)), Graphics.TEXT_JUSTIFY_LEFT);
            dc.setColor(pal.dim, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx0 + cw - pad, ly + (compact ? 0 : k.sc(3)), k.fSmall, pt, Graphics.TEXT_JUSTIFY_RIGHT);
            if (compact) {
                k.bar(dc, cx0 + pad, y + ch - k.sc(10), iw, k.sc1(5), p, lv);
            } else {
                k.bar(dc, cx0 + pad, y + k.sc(36), iw, k.sc1(6), p, lv);
                if (e["r"] != null) {
                    dc.setColor(pal.dim, Graphics.COLOR_TRANSPARENT);
                    dc.drawText(cx0 + pad, y + k.sc(45), k.fSmall,
                        k.fit(dc, "Restablece " + Fmt.resetWhen(num(e["r"] as Lang.Numeric or Null), now), k.fSmall, iw), Graphics.TEXT_JUSTIFY_LEFT);
                }
            }
            y += ch + gapY;
        }
        // compacto: un solo reinicio para todas; si no, la edad del dato
        var foot = (fetched == null) ? "" : Fmt.ago(fetched, now);
        if (compact && w != null && w["r"] != null) {
            foot = "Restablece " + Fmt.resetWhen(num(w["r"] as Lang.Numeric or Null), now);
        }
        dc.setColor(pal.dim, Graphics.COLOR_TRANSPARENT);
        var fy = y + k.sc(1);
        dc.drawText(k.cx, fy, k.fSmall, k.fit(dc, foot, k.fSmall, 2 * k.half(fy, k.hSmall)), Graphics.TEXT_JUSTIFY_CENTER);
    }

    // -------------------------------------------------------------------------
    // 3 · Por superficie
    // -------------------------------------------------------------------------

    function drawSurface(dc as Graphics.Dc, snap as Lang.Dictionary) as Void {
        var pal = k.pal;
        k.title(dc, "Superficies", k.sc(50));
        var bs = snap["b"] as Lang.Array or Null;
        if (bs == null || bs.size() == 0) {
            k.para(dc, "Sin desglose por superficie", k.fSmall, k.cy - k.hSmall, k.hSmall, 2, pal.dim);
            return;
        }
        var rw = k.sc(172);
        var rx = k.cx - rw / 2;
        var pitch = k.sc(38);
        var n = (bs.size() > 4) ? 4 : bs.size();
        var y = k.sc(64);
        for (var i = 0; i < n; i++) {
            var b = bs[i] as Lang.Dictionary;
            var p = num(b["p"] as Lang.Numeric or Null);
            var pt = Fmt.pct(p);
            var ptw = dc.getTextWidthInPixels(pt, k.fBody);
            dc.setColor(pal.text, Graphics.COLOR_TRANSPARENT);
            dc.drawText(rx, y, k.fBody, k.fit(dc, surfaceName((b["n"] as Lang.String or Null) == null ? "?" : b["n"] as Lang.String), k.fBody, rw - ptw - k.sc(6)), Graphics.TEXT_JUSTIFY_LEFT);
            dc.setColor(pal.dim, Graphics.COLOR_TRANSPARENT);
            dc.drawText(rx + rw, y, k.fBody, pt, Graphics.TEXT_JUSTIFY_RIGHT);
            k.bar(dc, rx, y + k.hBody + k.sc(1), rw, k.sc1(5), p, -1);
            y += pitch;
        }
    }

    // -------------------------------------------------------------------------
    // 4/5 · Proyección (sesión 5 h / semana 7 d)
    // -------------------------------------------------------------------------

    function drawProj(dc as Graphics.Dc, snap as Lang.Dictionary, now as Lang.Number,
                      week as Lang.Boolean) as Void {
        var pal = k.pal;
        // cabecera compacta: la cuerda de arriba es estrecha y el veredicto necesita sitio
        k.text(dc, k.cx, k.sc(33), k.fSmall, week ? "Semana · 7 d" : "Sesión · 5 h", pal.dim, Graphics.TEXT_JUSTIFY_CENTER);
        var e = dict(snap, week ? "w" : "s");
        if (e == null) {
            k.para(dc, "Sin datos", k.fSmall, k.cy - k.hSmall, k.hSmall, 2, pal.dim);
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
        var base = k.sc(84);
        var n = shown.toString();
        var nw = dc.getTextWidthInPixels(n, k.fHero);
        var hx = k.cx - (nw + k.sc(3) + mPctW) / 2;
        k.text(dc, hx, base, k.fHero, n, (lv >= 1) ? pal.fill(lv) : pal.text, Graphics.TEXT_JUSTIFY_LEFT);
        k.text(dc, hx + nw + k.sc(3), base, k.fTitle, "%", pal.dim, Graphics.TEXT_JUSTIFY_LEFT);
        var ly = base + k.sc(4);
        dc.setColor(pal.dim, Graphics.COLOR_TRANSPARENT);
        dc.drawText(k.cx, ly, k.fSmall, "previsto al reinicio", Graphics.TEXT_JUSTIFY_CENTER);

        // barra: uso real + marca del ritmo ideal (tiempo transcurrido)
        var bw = k.sc(168);
        var bx = k.cx - bw / 2;
        var by = ly + k.hSmall + k.sc(9);
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
        var cy2 = by + bh + k.sc(5);
        dc.setColor(pal.dim, Graphics.COLOR_TRANSPARENT);
        dc.drawText(bx, cy2, k.fSmall, left, Graphics.TEXT_JUSTIFY_LEFT);
        dc.drawText(bx + bw, cy2, k.fSmall, right, Graphics.TEXT_JUSTIFY_RIGHT);

        // veredicto (hasta 4 líneas; la cuerda se ensancha hacia el centro)
        var verdict;
        var vc = pal.text;
        if (p >= 100) {
            verdict = "Has alcanzado el límite." + ((r == null) ? "" : " Se restablece " + Fmt.resetAt(r, now) + ".");
            vc = pal.fill(2);
        } else if (pace == null) {
            verdict = "Aún no hay datos suficientes para estimar tu ritmo.";
            vc = pal.dim;
        } else if (pace["ex"] != null) {
            var ex = num(pace["ex"] as Lang.Numeric or Null);
            if (week) {
                verdict = "Atención. A este ritmo, se te agotará el límite " + Fmt.whenPhrase(ex, now)
                    + ", antes del reinicio " + Fmt.resetDay(r as Lang.Number, now) + ".";
            } else {
                verdict = "Atención. A este ritmo, se te agotará el límite a las " + Fmt.clock(ex)
                    + ", antes del reinicio.";
            }
            vc = pal.fill(2);
        } else if (lv == 1) {
            verdict = "Cuidado. A este ritmo llegarás al reinicio con un " + shown + " % usado.";
            vc = pal.fill(1);
        } else {
            verdict = "Vas bien. A este ritmo llegarás al reinicio con un " + shown + " % usado.";
        }
        k.para(dc, verdict, k.fSmall, cy2 + k.hSmall + k.sc(4), k.hSmall, 4, vc);
    }

    // -------------------------------------------------------------------------
    // 6 · Actividad
    // -------------------------------------------------------------------------

    function drawActivity(dc as Graphics.Dc, snap as Lang.Dictionary, now as Lang.Number,
                          hist as Lang.Array) as Void {
        var pal = k.pal;
        k.title(dc, "Actividad", k.sc(50));
        var w = dict(snap, "w");
        var r = (w == null || w["r"] == null) ? null : num(w["r"] as Lang.Numeric or Null);

        var x0 = k.cx - k.sc(80);
        var x1 = k.cx + k.sc(80);
        var yTop = k.sc(64);
        var yBot = k.sc(156);
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
        var ay = yBot + k.sc(3);
        dc.setColor(pal.dim, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x0, ay, k.fSmall, "Inicio", Graphics.TEXT_JUSTIFY_LEFT);
        dc.drawText(x1, ay, k.fSmall, "Reinicio", Graphics.TEXT_JUSTIFY_RIGHT);

        // leyenda
        var ly = ay + k.hSmall + k.sc(5);
        dc.setColor(pal.brand, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(k.sc1(3));
        dc.drawLine(k.cx - k.sc(78), ly + k.hSmall / 2, k.cx - k.sc(64), ly + k.hSmall / 2);
        dc.setPenWidth(1);
        dc.setColor(pal.text, Graphics.COLOR_TRANSPARENT);
        dc.drawText(k.cx - k.sc(58), ly, k.fSmall, "Real", Graphics.TEXT_JUSTIFY_LEFT);
        dc.setColor(pal.dim, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(k.cx + k.sc(2), ly + k.hSmall / 2, k.cx + k.sc(8), ly + k.hSmall / 2);
        dc.drawLine(k.cx + k.sc(12), ly + k.hSmall / 2, k.cx + k.sc(18), ly + k.hSmall / 2);
        dc.drawText(k.cx + k.sc(24), ly, k.fSmall, "Ideal", Graphics.TEXT_JUSTIFY_LEFT);
    }

    // -------------------------------------------------------------------------
    // 7 · Restablecimientos de límites
    // -------------------------------------------------------------------------

    function drawResets(dc as Graphics.Dc, snap as Lang.Dictionary, now as Lang.Number) as Void {
        var pal = k.pal;
        k.title(dc, "Reinicios", k.sc(50));
        var gs = snap["g"] as Lang.Array or Null;
        if (gs == null || gs.size() == 0) {
            k.para(dc, "No tienes restablecimientos disponibles", k.fBody, k.cy - k.hBody, k.hBody, 3, pal.dim);
            return;
        }
        var n = (gs.size() > 3) ? 3 : gs.size();
        var compact = n >= 3;
        var cw = k.sc(188);
        var cx0 = k.cx - cw / 2;
        var pad = k.sc(10);
        var ch = compact ? k.sc(46) : k.sc(56);
        var y = k.sc(62);
        for (var i = 0; i < n; i++) {
            var g = gs[i] as Lang.Dictionary;
            k.card(dc, cx0, y, cw, ch);
            var name = (g["l"] as Lang.String or Null);
            if (name == null) { name = "Reinicio"; }
            if (name.find("Restablecimiento") == 0) {
                name = "Reinicio" + name.substring(16, name.length());
            }
            if (num(g["left"] as Lang.Numeric or Null) > 1) { name = name + " ×" + num(g["left"] as Lang.Numeric or Null); }
            var lf = compact ? k.fSmall : k.pick(dc, name, cw - 2 * pad);
            var lh = (lf == k.fBody) ? k.hBody : k.hSmall;
            dc.setColor(pal.text, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx0 + pad, y + k.sc(compact ? 3 : 5), lf, k.fit(dc, name, lf, cw - 2 * pad), Graphics.TEXT_JUSTIFY_LEFT);
            var cap;
            var cc = pal.dim;
            if (g["pz"] == true) {
                cap = "En pausa";
            } else if (g["e"] != null) {
                cap = "Caduca " + Fmt.expiry(num(g["e"] as Lang.Numeric or Null), now);
            } else {
                cap = "Disponible";
            }
            dc.setColor(cc, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx0 + pad, y + k.sc(compact ? 3 : 5) + lh, k.fSmall, k.fit(dc, cap, k.fSmall, cw - 2 * pad), Graphics.TEXT_JUSTIFY_LEFT);
            y += ch + k.sc(4);
        }
    }
}
