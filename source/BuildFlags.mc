using Toybox.Lang;

//! Bandera de compilación: monkey.jungle excluye (:demo) y demo.jungle excluye
//! (:prod). Solo una de las dos funciones existe en cada .prg.
(:glance)
module BuildFlags {
    (:prod)
    function isDemo() as Lang.Boolean { return false; }

    (:demo)
    function isDemo() as Lang.Boolean { return true; }
}
