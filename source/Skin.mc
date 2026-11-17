using Toybox.Lang;
using Toybox.Graphics;
using Toybox.WatchUi;
using Toybox.Math;

//! Medidas, fuentes y primitivas de dibujo compartidas por todas las pantallas.
//! Diseño base 260x260 (centro 130,130); todo se escala con sc() por resolución.
//! Las fuentes son BMFont (tools/gen_fonts.py) ya generadas al tamaño de cada
//! resolución, así que aquí NO se escalan.
class Skin {
    var pal as Pal;
    var cx as Lang.Number;
    var cy as Lang.Number;
    var s as Lang.Float;
    var rSafe as Lang.Number;           //!< radio seguro del cristal
    var fHero as Graphics.FontType;     //!< serif, solo cifras (grande)
    var fTitle as Graphics.FontType;    //!< serif, títulos
    var fBody as Graphics.FontType;     //!< sans, etiquetas
    var fSmall as Graphics.FontType;    //!< sans, secundario
    var hSmall as Lang.Number;
    var hBody as Lang.Number;
    private const MEMO_MAX = 24;
    private var mFitMemo as Lang.Dictionary = {};   //!< texto -> [font, maxW, recortado]
    private var mWrapMemo as Lang.Dictionary = {};  //!< texto -> [font, y, lineH, maxLines, líneas]

    function initialize(dc as Graphics.Dc) {
        pal = new Pal();
        var w = dc.getWidth();
        var h = dc.getHeight();
        cx = w / 2;
        cy = h / 2;
        s = ((w < h) ? w : h) / 260.0;
        rSafe = ((w < h) ? w : h) / 2 - sc(6);
        fHero = WatchUi.loadResource(Rez.Fonts.SerifHero) as Graphics.FontType;
        fTitle = WatchUi.loadResource(Rez.Fonts.SerifTitle) as Graphics.FontType;
        fBody = WatchUi.loadResource(Rez.Fonts.SansBody) as Graphics.FontType;
        fSmall = WatchUi.loadResource(Rez.Fonts.SansSmall) as Graphics.FontType;
        hSmall = dc.getFontHeight(fSmall);
        hBody = dc.getFontHeight(fBody);
    }

    function sc(v as Lang.Numeric) as Lang.Number {
        return (v * s + 0.5).toNumber();
    }

    function sc1(v as Lang.Numeric) as Lang.Number {
        var r = sc(v);
        return (r < 1) ? 1 : r;
    }

    //! Semicuerda útil del círculo para una franja [y, y+hgt]. Sale 0 si queda fuera.
    function half(y as Lang.Number, hgt as Lang.Number) as Lang.Number {
        var a = y - cy;
        var b = y + hgt - cy;
        if (a < 0) { a = -a; }
        if (b < 0) { b = -b; }
        var d = (a > b) ? a : b;
        if (d >= rSafe) { return 0; }
        return Math.sqrt((rSafe * rSafe - d * d).toFloat()).toNumber();
    }

    //! Recorta con "…" si no cabe. El recorte (lo caro) se memoiza por texto.
    function fit(dc as Graphics.Dc, txt as Lang.String, font as Graphics.FontType,
                 maxW as Lang.Number) as Lang.String {
        if (maxW <= 0 || dc.getTextWidthInPixels(txt, font) <= maxW) {
            return txt;
        }
        var hit = mFitMemo[txt] as Lang.Array or Null;
        if (hit != null && hit[0] == font && hit[1] == maxW) {
            return hit[2] as Lang.String;
        }
        var cut = txt;
        while (cut.length() > 1 && dc.getTextWidthInPixels(cut + "…", font) > maxW) {
            var t = cut.substring(0, cut.length() - 1);
            if (t == null) { break; }
            cut = t;
        }
        var res = cut + "…";
        if (mFitMemo.size() >= MEMO_MAX) {
            mFitMemo = {};
        }
        mFitMemo[txt] = [font, maxW, res];
        return res;
    }

    //! Texto por LÍNEA BASE (las fuentes tienen mucho aire sobre las cifras).
    function text(dc as Graphics.Dc, x as Lang.Number, base as Lang.Number,
                  font as Graphics.FontType, txt as Lang.String, color as Lang.Number,
                  just as Lang.Number) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, base - Graphics.getFontAscent(font), font, txt, just);
    }

    //! Título serif centrado en la línea base; la cuerda se mide sobre la TINTA
    //! (altura de versal), no sobre toda la celda. Si no cabe, baja a la sans.
    function title(dc as Graphics.Dc, txt as Lang.String, base as Lang.Number) as Void {
        var f = fTitle;
        var ink = Graphics.getFontAscent(f) * 7 / 10;
        var avail = 2 * half(base - ink, ink + sc(2));
        if (dc.getTextWidthInPixels(txt, f) > avail) {
            f = fBody;
        }
        text(dc, cx, base, f, fit(dc, txt, f, avail), pal.text, Graphics.TEXT_JUSTIFY_CENTER);
    }

    //! Elige la primera fuente de la lista que quepa (o recorta con la última).
    function pick(dc as Graphics.Dc, txt as Lang.String, maxW as Lang.Number) as Graphics.FontType {
        if (dc.getTextWidthInPixels(txt, fBody) <= maxW) {
            return fBody;
        }
        return fSmall;
    }

    //! Tarjeta redondeada: relleno en AMOLED, contorno en MIP.
    function card(dc as Graphics.Dc, x as Lang.Number, y as Lang.Number,
                  cw as Lang.Number, ch as Lang.Number) as Void {
        var r = sc(10);
        if (pal.amoled) {
            dc.setColor(pal.card, Graphics.COLOR_TRANSPARENT);
            dc.fillRoundedRectangle(x, y, cw, ch, r);
        } else {
            dc.setColor(pal.line, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(1);
            dc.drawRoundedRectangle(x, y, cw, ch, r);
        }
    }

    //! Barra fina redondeada con pista del mismo tono. lv = severidad (0/1/2) o -1 = marca.
    function bar(dc as Graphics.Dc, x as Lang.Number, y as Lang.Number, bw as Lang.Number,
                 bh as Lang.Number, pct as Lang.Numeric, lv as Lang.Number) as Void {
        var r = bh / 2;
        var track = (lv < 0) ? pal.faint : pal.track(lv);
        var fill = (lv < 0) ? pal.brand : pal.fill(lv);
        dc.setColor(track, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(x, y, bw, bh, r);
        var fw = (bw * pct / 100.0).toNumber();
        if (fw < bh && pct > 0) { fw = bh; }
        if (fw > bw) { fw = bw; }
        if (fw > 0) {
            dc.setColor(fill, Graphics.COLOR_TRANSPARENT);
            dc.fillRoundedRectangle(x, y, fw, bh, r);
        }
    }

    //! Parte `txt` en líneas que quepan en la cuerda de cada renglón.
    function wrap(dc as Graphics.Dc, txt as Lang.String, font as Graphics.FontType,
                  yTop as Lang.Number, lineH as Lang.Number, maxLines as Lang.Number,
                  pad as Lang.Number) as Lang.Array<Lang.String> {
        var out = [] as Lang.Array<Lang.String>;
        var line = "";
        var rest = txt;
        while (rest.length() > 0) {
            var sp = rest.find(" ");
            var word = (sp == null) ? rest : rest.substring(0, sp);
            rest = (sp == null) ? "" : rest.substring(sp + 1, rest.length());
            if (word == null || rest == null) { break; }
            var y = yTop + out.size() * lineH;
            var avail = 2 * half(y, lineH) - 2 * pad;
            var cand = (line.length() == 0) ? word : line + " " + word;
            if (line.length() > 0 && dc.getTextWidthInPixels(cand, font) > avail) {
                out.add(line);
                if (out.size() >= maxLines) {
                    line = "";
                    rest = "";
                    break;
                }
                line = word;
            } else {
                line = cand;
            }
        }
        if (line.length() > 0 && out.size() < maxLines) {
            out.add(line);
        }
        return out;
    }

    //! Párrafo centrado; devuelve la Y bajo la última línea.
    function para(dc as Graphics.Dc, txt as Lang.String, font as Graphics.FontType,
                  yTop as Lang.Number, lineH as Lang.Number, maxLines as Lang.Number,
                  color as Lang.Number) as Lang.Number {
        var hit = mWrapMemo[txt] as Lang.Array or Null;
        var lines;
        if (hit != null && hit[0] == font && hit[1] == yTop && hit[2] == lineH && hit[3] == maxLines) {
            lines = hit[4] as Lang.Array<Lang.String>;
        } else {
            lines = wrap(dc, txt, font, yTop, lineH, maxLines, sc(2));
            if (mWrapMemo.size() >= MEMO_MAX) {
                mWrapMemo = {};
            }
            mWrapMemo[txt] = [font, yTop, lineH, maxLines, lines];
        }
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        for (var i = 0; i < lines.size(); i++) {
            dc.drawText(cx, yTop + i * lineH, font, lines[i], Graphics.TEXT_JUSTIFY_CENTER);
        }
        return yTop + lines.size() * lineH;
    }

    //! Indicador de pantalla: puntos discretos abajo.
    function dots(dc as Graphics.Dc, idx as Lang.Number, n as Lang.Number) as Void {
        var d = sc1(4);
        var gap = sc(9);
        var y = cy * 2 - sc(20);
        var x0 = cx - ((n - 1) * gap) / 2;
        for (var i = 0; i < n; i++) {
            dc.setColor((i == idx) ? pal.brand : pal.faint, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(x0 + i * gap, y, (i == idx) ? d : ((d > 2) ? d - 1 : 1));
        }
    }
}
