using Toybox.Lang;
using Toybox.WatchUi;
using Toybox.Graphics;
using Toybox.Application.Storage;
using Toybox.Time;

//! Glance: spark + "Codex", y barras de Sesión y Semana. Solo lee Storage (o
//! DemoData en builds DEMO) y usa fuentes de sistema: el proceso de glance tiene
//! 64 KB. El Dc de la glance es solo su área (176x93 en fr955): todo relativo.
(:glance)
class CodexGlanceView extends WatchUi.GlanceView {

    private var mPal as Pal or Null;
    private var mSnap as Lang.Dictionary or Null = null;
    private var mFetched as Lang.Number or Null = null;
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
            mFetched = Time.now().value() - 180;
            return;
        }
        var v = Storage.getValue("cx_snap");
        mSnap = (v instanceof Lang.Dictionary) ? (v as Lang.Dictionary) : null;
        v = Storage.getValue("cx_fetch");
        mFetched = (v instanceof Lang.Number) ? (v as Lang.Number) : null;
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

        var fHead = Graphics.FONT_GLANCE;
        var fRow = Graphics.FONT_XTINY;
        var hHead = dc.getFontHeight(fHead);
        var hRow = dc.getFontHeight(fRow);
        var pad = w / 22;
        var rowH = (h - hHead - 2) / 2;
        if (rowH > hRow + 4) { rowH = hRow + 4; }
        var top = (h - (hHead + 2 + 2 * rowH)) / 2;
        if (top < 0) { top = 0; }

        // cabecera: spark + Codex + edad
        var sz = hHead * 3 / 4;
        Logo.draw(dc, pad + sz / 2, top + hHead / 2, sz, pal.brand);
        dc.setColor(pal.text, Graphics.COLOR_TRANSPARENT);
        dc.drawText(pad + sz + pad / 2 + 2, top, fHead, "Codex", Graphics.TEXT_JUSTIFY_LEFT);

        var sn = mSnap;
        var now = Time.now().value();
        if (sn == null) {
            dc.setColor(pal.dim, Graphics.COLOR_TRANSPARENT);
            dc.drawText(pad, top + hHead + 2 + (2 * rowH - hRow) / 2, fRow, "Abre la app", Graphics.TEXT_JUSTIFY_LEFT);
            return;
        }
        var age = Fmt.ago(mFetched, now);
        var headEnd = pad + sz + pad / 2 + 2 + dc.getTextWidthInPixels("Codex", fHead);
        if (headEnd + pad + dc.getTextWidthInPixels(age, fRow) <= w - pad) {
            dc.setColor(pal.dim, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w - pad, top + (hHead - hRow) / 2 + 1, fRow, age, Graphics.TEXT_JUSTIFY_RIGHT);
        }

        // Sesión 5 h y semana; en free solo hay semanal (un solo renglón).
        var s0 = sn["s"] as Lang.Dictionary or Null;
        var w0 = sn["w"] as Lang.Dictionary or Null;
        var lw = dc.getTextWidthInPixels("Semana", fRow);
        for (var i = 0; i < 2; i++) {
            var e = null as Lang.Dictionary or Null;
            var lab = "Semana";
            if (i == 0) {
                if (s0 != null) {
                    e = s0;
                    lab = "Sesión";
                } else {
                    e = w0;
                }
            } else if (s0 != null) {
                e = w0;
            }
            if (e == null) { continue; }
            var p = (e["p"] as Lang.Numeric).toNumber();
            var lv = pal.level(e["sv"] as Lang.String or Null, p);
            var y = top + hHead + 2 + i * rowH;
            var pt = p + "%";
            var ptw = dc.getTextWidthInPixels("100%", fRow);
            dc.setColor(pal.dim, Graphics.COLOR_TRANSPARENT);
            dc.drawText(pad, y, fRow, lab, Graphics.TEXT_JUSTIFY_LEFT);
            dc.setColor(pal.text, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w - pad, y, fRow, pt, Graphics.TEXT_JUSTIFY_RIGHT);
            var bx = pad + lw + pad;
            var bw = w - pad - ptw - pad - bx;
            var bh = (hRow / 5 < 4) ? 4 : hRow / 5;
            var by = y + (hRow - bh) / 2 + 1;
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
}
