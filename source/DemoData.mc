using Toybox.Lang;
using Toybox.Time;

//! Datos de ejemplo (solo en builds DEMO=1: monkey.jungle excluye (:demo)).
//! Mismo formato que la instantánea que UsageStore guarda en Storage
//! (ver SPEC.md, "Instantánea"). Calcados de una respuesta real de
//! /api/oauth/usage (sesión 6 %, semana 92 % crítica, Fable 7 %).
(:glance, :demo)
module DemoData {

    function snapshot() as Lang.Dictionary {
        var now = Time.now().value();
        return {
            "s" => { "p" => 64, "r" => now + 2 * 3600 + 18 * 60, "sv" => "normal" },
            "w" => { "p" => 92, "r" => now + 2 * 86400 + 22 * 3600, "sv" => "critical" },
            "m" => [
                { "n" => "Fable", "p" => 7, "r" => now + 2 * 86400 + 22 * 3600, "sv" => "normal" }
            ],
            "b" => [
                { "n" => "Codex", "p" => 96 },
                { "n" => "Cowork", "p" => 4 },
                { "n" => "Chats", "p" => 0 },
                { "n" => "Other", "p" => 0 }
            ],
            "g" => [
                { "l" => "Restablecimiento completo", "t" => "full", "left" => 1, "tot" => 1,
                  "e" => now + 25 * 86400, "u" => true, "pz" => false },
                { "l" => "Reinicio de Fable", "t" => "weekly", "left" => 1, "tot" => 1,
                  "e" => now + 36 * 3600, "u" => true, "pz" => false }
            ],
            "x" => { "on" => false, "p" => null }
        };
    }

    //! Histórico de muestras [epoch, % sesión, % semana], de más antigua a más nueva.
    function history() as Lang.Array {
        var now = Time.now().value();
        var start = now - 4 * 86400 - 2 * 3600;
        var out = [];
        var w = [3, 9, 18, 26, 31, 44, 52, 58, 63, 71, 77, 84, 88, 92];
        for (var i = 0; i < w.size(); i++) {
            out.add([start + i * (now - start) / (w.size() - 1), (i * 37) % 100, w[i]]);
        }
        return out;
    }
}
