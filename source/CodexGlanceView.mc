using Toybox.Lang;
using Toybox.WatchUi;
using Toybox.Graphics;
using Toybox.Application.Storage;
using Toybox.Time;

//! Glance: barras de Sesión y Semana y la hora del próximo reinicio, en tres
//! renglones clave/valor. Solo lee Storage (o DemoData en builds DEMO) y usa
//! fuentes de sistema: el proceso de glance tiene 64 KB. El Dc de la glance es
//! solo su área (176x93 en fr955): todo va relativo.
//! El isotipo NO se dibuja aquí: el listado de glances ya muestra el icono de
//! la app a la izquierda, y repetirlo era ruido (y el trazado es caro).
(:glance)
class CodexGlanceView extends WatchUi.GlanceView {

    private var mPal as Pal or Null;
    private var mSnap as Lang.Dictionary or Null = null;
    private var mLoaded as Lang.Boolean = false;

    function initialize() {
        GlanceView.initialize();
    }

    //! Storage se lee una vez por aparición de la glance (onShow), no por frame.
    function onShow() as Void {
        mLoaded = false;
    }

    private function load() as Void {
        mLoaded = true;
        if (BuildFlags.isDemo()) {
            mSnap = demoSnap();
            return;
        }
        var v = Storage.getValue("cx_snap");
        mSnap = (v instanceof Lang.Dictionary) ? (v as Lang.Dictionary) : null;
    }

    (:demo)
    private function demoSnap() as Lang.Dictionary or Null { return DemoData.snapshot(); }
    (:prod)
    private function demoSnap() as Lang.Dictionary or Null { return null; }

    function onUpdate(dc as Graphics.Dc) as Void {
        if (mPal == null) {
            mPal = new Pal();
        }
        var pal = mPal as Pal;
        if (!mLoaded) {
            load();
        }
        var w = dc.getWidth();
        var h = dc.getHeight();
        dc.setColor(pal.text, Graphics.COLOR_TRANSPARENT);
        dc.clear();

        var f = Graphics.FONT_XTINY;
        var hRow = dc.getFontHeight(f);
        var pad = w / 22;
        var sn = mSnap;

        // Renglones: etiqueta, % (o -1 si el renglón no lleva barra) y valor.
        var labels = [] as Lang.Array;
        var pcts = [] as Lang.Array;
        var vals = [] as Lang.Array;
        var lvs = [] as Lang.Array;
        var s0 = (sn == null) ? null : (sn["s"] as Lang.Dictionary or Null);
        var w0 = (sn == null) ? null : (sn["w"] as Lang.Dictionary or Null);
        if (s0 != null) {
            var p = (s0["p"] as Lang.Numeric).toNumber();
            labels.add("Sesión");
            pcts.add(p);
            vals.add(p + "%");
            lvs.add(pal.level(s0["sv"] as Lang.String or Null, p));
        }
        if (w0 != null) {
            var p = (w0["p"] as Lang.Numeric).toNumber();
            labels.add("Semana");
            pcts.add(p);
            vals.add(p + "%");
            lvs.add(pal.level(w0["sv"] as Lang.String or Null, p));
        }
        var main = (s0 != null) ? s0 : w0;
        var now = Time.now().value();
        if (main != null && main["r"] != null) {
            var r = (main["r"] as Lang.Numeric).toNumber();
            labels.add("Restablece");
            pcts.add(-1);
            vals.add((r <= now) ? "ahora" : Fmt.clock(r));
            lvs.add(0);
        }

        var n = labels.size();
        if (n == 0) {
            dc.setColor(pal.dim, Graphics.COLOR_TRANSPARENT);
            dc.drawText(pad, (h - hRow) / 2, f, "Abre la app", Graphics.TEXT_JUSTIFY_LEFT);
            return;
        }

        var rowH = h / n;
        var lw = dc.getTextWidthInPixels("Semana", f);   // barra alineada en todos
        var ptw = dc.getTextWidthInPixels("100%", f);
        for (var i = 0; i < n; i++) {
            var y = i * rowH + (rowH - hRow) / 2;
            var p = pcts[i] as Lang.Number;
            if (p >= 0) {
                var bx = pad + lw + pad / 2 + 2;
                var bw = w - pad - ptw - pad / 2 - bx;
                if (bw > 0) {                       // firmware viejo lanza con ancho <= 0
                    var bh = (hRow / 5 < 4) ? 4 : hRow / 5;
                    var by = y + (hRow - bh) / 2 + 1;
                    var lv = lvs[i] as Lang.Number;
                    dc.setColor(pal.track(lv), Graphics.COLOR_TRANSPARENT);
                    dc.fillRoundedRectangle(bx, by, bw, bh, bh / 2);
                    var fw = (bw * p / 100.0).toNumber();
                    if (fw < bh && p > 0) { fw = bh; }
                    if (fw > bw) { fw = bw; }
                    if (fw > 0) {
                        dc.setColor(pal.fill(lv), Graphics.COLOR_TRANSPARENT);
                        dc.fillRoundedRectangle(bx, by, fw, bh, bh / 2);
                    }
                }
            }
            dc.setColor(pal.dim, Graphics.COLOR_TRANSPARENT);
            dc.drawText(pad, y, f, labels[i] as Lang.String, Graphics.TEXT_JUSTIFY_LEFT);
            dc.setColor(pal.text, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w - pad, y, f, vals[i] as Lang.String, Graphics.TEXT_JUSTIFY_RIGHT);
        }
    }
}
