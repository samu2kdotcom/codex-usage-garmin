using Toybox.Lang;
using Toybox.Time;

//! Datos de ejemplo (solo en builds DEMO=1: monkey.jungle excluye (:demo)).
//! Mismo formato que la instantánea que UsageStore guarda en Storage
//! (ver SPEC.md, "Instantánea"): cuenta Plus con ventanas de 5 h y semanal,
//! límite adicional de Spark, code review, reinicios y spend control.
//! Para ver el caso free basta con quitar "s", "a", "cr", "o", "g"/"gc" y
//! dejar solo "w" (una sola ventana; el anillo de Uso pasa a la semanal).
(:glance, :demo)
module DemoData {

    function snapshot() as Lang.Dictionary {
        var now = Time.now().value();
        return {
            "s" => { "p" => 34, "r" => now + 2 * 3600 + 18 * 60, "sv" => null, "sec" => 18000 },
            "w" => { "p" => 71, "r" => now + 3 * 86400 + 4 * 3600, "sv" => null, "sec" => 604800 },
            "o" => [
                { "n" => "Ventana 2 h", "p" => 12, "r" => now + 40 * 60, "sec" => 7200 }
            ],
            "a" => [
                { "n" => "GPT-Codex-Spark", "p" => 18, "r" => now + 3 * 86400 + 4 * 3600, "sec" => 604800 }
            ],
            "cr" => { "p" => 4, "r" => now + 3 * 86400 + 4 * 3600 },
            "g" => [
                { "id" => "RateLimitResetCredit_demo1", "l" => "Full reset (Weekly + 5 hr)",
                  "t" => "codex_rate_limits", "e" => now + 25 * 86400, "st" => "available" },
                { "id" => "RateLimitResetCredit_demo2", "l" => "Full reset (Weekly + 5 hr)",
                  "t" => "codex_rate_limits", "e" => now + 11 * 86400, "st" => "available" }
            ],
            "gc" => 2,
            "x" => { "on" => true, "bal" => 12.0, "unl" => false, "rc" => false,
                     "sc" => false, "scp" => 60, "scr" => now + 4 * 86400 },
            "pl" => "plus",
            "al" => true,
            "aid" => "acct_demo"
        };
    }

    //! Histórico de muestras [epoch, % sesión, % semana], de más antigua a más nueva.
    function history() as Lang.Array {
        var now = Time.now().value();
        var start = now - 4 * 86400 - 2 * 3600;
        var out = [];
        var w = [3, 9, 18, 26, 31, 44, 52, 58, 63, 71, 76, 80, 84, 88];
        for (var i = 0; i < w.size(); i++) {
            out.add([start + i * (now - start) / (w.size() - 1), (i * 23) % 60, w[i]]);
        }
        return out;
    }
}
