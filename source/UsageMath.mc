using Toybox.Lang;

//! Cálculos puros (sin Storage ni red) sobre los límites de uso.
module UsageMath {

    const SESSION_S = 18000;   // ventana de sesión: 5 h
    const WEEK_S = 604800;     // ventana semanal: 7 d

    //! Ritmo medio desde el inicio de la ventana (resets - windowSec).
    //! Devuelve null si falta resets/pct o la ventana acaba de empezar
    //! (transcurrido < 2 %).
    //! { "el" => Float 0..1 transcurrido, "proj" => Float % previsto al reset
    //!   (puede pasar de 100), "ex" => Number epoch en que llegará a 100 %
    //!   (null si no llega antes del reset; con pct >= 100, ya: nowEpoch),
    //!   "left" => Float % restante }
    function pace(pct as Lang.Numeric or Null, resetsEpoch as Lang.Number or Null,
                  windowSec as Lang.Number, nowEpoch as Lang.Number) as Lang.Dictionary or Null {
        if (pct == null || resetsEpoch == null || windowSec <= 0) {
            return null;
        }
        var p = pct.toFloat();
        var start = resetsEpoch - windowSec;
        var elapsed = (nowEpoch - start).toFloat();
        var el = elapsed / windowSec.toFloat();
        if (el < 0.0) {
            el = 0.0;
        }
        if (el > 1.0) {
            el = 1.0;
        }
        if (el < 0.02) {
            return null;
        }
        var proj = p / el;
        var ex = null;
        if (p >= 100.0) {
            ex = nowEpoch;
        } else if (p > 0.0) {
            // Ritmo constante: p % en `elapsed` s -> 100 % a elapsed*100/p s desde el inicio.
            var hit = start + (elapsed * 100.0 / p).toNumber();
            if (hit <= resetsEpoch) {
                ex = hit;
            }
        }
        return {
            "el" => el,
            "proj" => proj,
            "ex" => ex,
            "left" => 100.0 - p
        };
    }
}
