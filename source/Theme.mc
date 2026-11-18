using Toybox.Lang;
using Toybox.Graphics;
using Toybox.System;
using Toybox.Math;

// =============================================================================
// PIEL ChatGPT (modo oscuro) — dos paletas.
//
// AMOLED (fr265, fr965, fr970; ancho >= 400): hex de la interfaz de ChatGPT tal
// cual (#212121 de fondo, #2F2F2F de tarjeta, #ECECEC de texto principal).
//
// MIP de 64 colores (fr955, fr255, fr255m, fēnix 7/7S/7X; 8 bpp ARGB2222): cada
// canal solo vale 00/55/AA/FF y el hardware cuantiza al más cercano, así que se
// eligen a mano los colores exactos de la paleta:
//
//   ChatGPT            uso                    MIP (paleta)
//   -----------------  ---------------------  ---------------------------------
//   #212121 fondo      fondo                  #000000 negro
//   #2F2F2F tarjeta    tarjeta                sin relleno: contorno #555555
//                                             (el gris más oscuro de la paleta
//                                             sería una tarjeta casi blanca)
//   #ECECEC texto      titulares y cifras     #FFFFFF
//   #9E9E9E gris       secundario             #AAAAAA
//   #10A37F teal       marca, anillo, puntos  #00AA55 (el mismo teal llevado a
//                                             los niveles 00/55/AA/FF)
//   #EF4146 crítico    barra crítica          #FF0000 / pista #550000
//   #10A37F normal     barra normal           #00AA55 / pista #005500
//   #E9A23B ámbar      barra de aviso         #FFAA00 / pista #555500
//
// La severidad no cambia: normal = teal de marca, aviso = ámbar, crítico = rojo.
// =============================================================================
(:glance)
class Pal {
    var amoled as Lang.Boolean;
    var bg as Lang.Number;
    var card as Lang.Number;
    var line as Lang.Number;     //!< contorno de tarjeta (MIP) / trazos tenues
    var text as Lang.Number;
    var dim as Lang.Number;
    var faint as Lang.Number;    //!< pista del anillo, puntos del indicador
    var brand as Lang.Number;
    var red as Lang.Number;
    var redT as Lang.Number;
    var ok as Lang.Number;
    var okT as Lang.Number;
    var amber as Lang.Number;
    var amberT as Lang.Number;

    function initialize() {
        amoled = System.getDeviceSettings().screenWidth >= 400;
        if (amoled) {
            bg = 0x212121;
            card = 0x2F2F2F;
            line = 0x424242;
            text = 0xECECEC;
            dim = 0x9E9E9E;
            faint = 0x4F4F4F;
            brand = 0x10A37F;
            red = 0xEF4146;
            redT = 0x3E1B1E;
            ok = 0x10A37F;
            okT = 0x0E3B31;
            amber = 0xE9A23B;
            amberT = 0x3D2C12;
        } else {
            bg = 0x000000;
            card = 0x000000;
            line = 0x555555;
            text = 0xFFFFFF;
            dim = 0xAAAAAA;
            faint = 0x555555;
            brand = 0x00AA55;
            red = 0xFF0000;
            redT = 0x550000;
            ok = 0x00AA55;
            okT = 0x005500;
            amber = 0xFFAA00;
            amberT = 0x555500;
        }
    }

    //! Severidad efectiva: la de la API si viene; si no, por porcentaje.
    //! 0 normal, 1 aviso, 2 crítico.
    function level(sv as Lang.String or Null, pct as Lang.Numeric) as Lang.Number {
        if (sv != null) {
            if (sv.equals("critical")) { return 2; }
            if (sv.equals("warning")) { return 1; }
            return (pct >= 100) ? 2 : 0;
        }
        if (pct >= 90) { return 2; }
        if (pct >= 70) { return 1; }
        return 0;
    }

    function fill(lv as Lang.Number) as Lang.Number {
        return (lv >= 2) ? red : ((lv == 1) ? amber : ok);
    }

    function track(lv as Lang.Number) as Lang.Number {
        return (lv >= 2) ? redT : ((lv == 1) ? amberT : okT);
    }
}

//! Marca de OpenAI (blossom 2025) como polígonos: nítida a cualquier tamaño.
//! El símbolo tiene simetría de orden 6, así que los trozos de UN sexto (que
//! genera tools/gen_logo.py en LogoMark.mc) se dibujan seis veces, girados 60°.
(:glance)
module Logo {
    function draw(dc as Graphics.Dc, cx as Lang.Number, cy as Lang.Number,
                  size as Lang.Number, color as Lang.Number) as Void {
        var k = size.toFloat() / LogoMark.SIZE;
        var off = 0;
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        for (var p = 0; p < LogoMark.NP; p++) {
            var n = LogoMark.N[p];
            var fx = LogoMark.CX[p] - 100.0;
            var fy = LogoMark.CY[p] - 100.0;
            for (var r = 0; r < 6; r++) {
                var a = r * 1.0471976;          // 60° en radianes
                var ca = Math.cos(a);
                var sa = Math.sin(a);
                // puntos del trozo ya girados y escalados
                var xs = new [n];
                var ys = new [n];
                for (var i = 0; i < n; i++) {
                    var px = LogoMark.PTS[off + 2 * i] - 100.0;
                    var py = LogoMark.PTS[off + 2 * i + 1] - 100.0;
                    xs[i] = (cx + ((px * ca - py * sa) * k)).toNumber();
                    ys[i] = (cy + ((px * sa + py * ca) * k)).toNumber();
                }
                var fcx = (cx + ((fx * ca - fy * sa) * k)).toNumber();
                var fcy = (cy + ((fx * sa + fy * ca) * k)).toNumber();
                // fillPolygon de Garmin abanica desde pts[0] y falla con polígonos
                // cóncavos: se rellena por tramos cortos desde el centro del trozo.
                for (var j = 0; j < n; j += LogoMark.STEP) {
                    var pts = [[fcx, fcy]] as Lang.Array<Graphics.Point2D>;
                    for (var q = 0; q <= LogoMark.STEP; q++) {
                        var m = (j + q) % n;
                        pts.add([xs[m], ys[m]] as Graphics.Point2D);
                    }
                    dc.fillPolygon(pts);
                }
            }
            off += 2 * n;
        }
    }
}
