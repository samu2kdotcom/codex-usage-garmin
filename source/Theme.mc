using Toybox.Lang;
using Toybox.Graphics;
using Toybox.System;

// =============================================================================
// PIEL claude.ai (modo oscuro) — dos paletas.
//
// AMOLED (fr265, fr965, fr970; ancho >= 400): hex de claude.ai tal cual.
//
// MIP de 64 colores (fr955, fr255, fr255m, fēnix 7/7S/7X; 8 bpp ARGB2222): cada
// canal solo vale 00/55/AA/FF y el hardware cuantiza al más cercano, así que se
// eligen a mano los colores exactos de la paleta:
//
//   claude.ai          uso                    MIP (paleta)
//   -----------------  ---------------------  ---------------------------------
//   #1F1E1D fondo      fondo                  #000000 negro
//   #30302E tarjeta    tarjeta                sin relleno: contorno #555555
//                                             (el gris más oscuro de la paleta
//                                             sería una tarjeta casi blanca)
//   #FAF9F5 texto      titulares y cifras     #FFFFFF
//   #9C9A92 gris       secundario             #AAAAAA
//   #D97757 naranja    spark, marca           #FF5500 (el vecino #FF5555 es
//                                             rosa y se confunde con el rojo)
//   #D03A35 crítico    barra crítica          #FF0000 / pista #550000
//   #2C84DB normal     barra normal           #55AAFF / pista #000055
//   ámbar warning      barra de aviso         #FFAA00 / pista #555500
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
    var blue as Lang.Number;
    var blueT as Lang.Number;
    var amber as Lang.Number;
    var amberT as Lang.Number;

    function initialize() {
        amoled = System.getDeviceSettings().screenWidth >= 400;
        if (amoled) {
            bg = 0x1F1E1D;
            card = 0x30302E;
            line = 0x3D3D3A;
            text = 0xFAF9F5;
            dim = 0x9C9A92;
            faint = 0x4A4946;
            brand = 0xD97757;
            red = 0xD03A35;
            redT = 0x4A1C1B;
            blue = 0x2C84DB;
            blueT = 0x14304E;
            amber = 0xE0A526;
            amberT = 0x4B3A12;
        } else {
            bg = 0x000000;
            card = 0x000000;
            line = 0x555555;
            text = 0xFFFFFF;
            dim = 0xAAAAAA;
            faint = 0x555555;
            brand = 0xFF5500;
            red = 0xFF0000;
            redT = 0x550000;
            blue = 0x55AAFF;
            blueT = 0x000055;
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
        return (lv >= 2) ? red : ((lv == 1) ? amber : blue);
    }

    function track(lv as Lang.Number) as Lang.Number {
        return (lv >= 2) ? redT : ((lv == 1) ? amberT : blueT);
    }
}

//! Isotipo (spark) de Claude como polígono: nítido a cualquier tamaño.
(:glance)
module Logo {
    //! fillPolygon de Garmin falla con polígonos cóncavos grandes (sale un abanico),
    //! así que el spark (estrella respecto a su centro) se rellena en abanico:
    //! centro + tramos cortos del contorno.
    const STEP = 4;

    function draw(dc as Graphics.Dc, cx as Lang.Number, cy as Lang.Number,
                  size as Lang.Number, color as Lang.Number) as Void {
        var n = Spark.N;
        var p = Spark.PTS;
        var k = size.toFloat() / Spark.SIZE;
        var xs = new [n];
        var ys = new [n];
        for (var i = 0; i < n; i++) {
            xs[i] = cx + ((p[2 * i] - 100) * k).toNumber();
            ys[i] = cy + ((p[2 * i + 1] - 100) * k).toNumber();
        }
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        for (var i = 0; i < n; i += STEP) {
            var pts = [[cx, cy]] as Lang.Array<Graphics.Point2D>;
            for (var j = i; j <= i + STEP; j++) {
                var m = j % n;
                pts.add([xs[m], ys[m]] as Graphics.Point2D);
            }
            dc.fillPolygon(pts);
        }
    }
}
