using Toybox.Application;
using Toybox.WatchUi;
using Toybox.Lang;

//! Entrada del widget. (:glance) porque devuelve getGlanceView(); el aviso de
//! glance se silencia SOLO aquí (getInitialView construye vistas que no
//! existen en el proceso de glance de 64 KB).
(:glance, :typecheck(disableGlanceCheck))
class CodexUsageApp extends Application.AppBase {

    function initialize() {
        AppBase.initialize();
    }

    function getInitialView() {
        // Solo proceso principal (no glance): receptor del login OAuth.
        CodexAuth.register();
        return [new CodexUsageView(), new CodexUsageDelegate()];
    }

    function getGlanceView() {
        return [new CodexGlanceView()];
    }
}
