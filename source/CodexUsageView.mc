using Toybox.Lang;
using Toybox.WatchUi;
using Toybox.Graphics;
using Toybox.Time;

//! Vista principal del widget: un solo View con un ciclo de pantallas.
//!   0 Uso (anillo de la sesión 5 h o de la semana en free)
//!   1 Límites semanales   2 Otros límites
//!   3 Proyección · Sesión (5 h)   4 Proyección · Semana (7 d)
//!   5 Actividad                   6 Reinicios
//! DOWN/UP recorren el ciclo (con vuelta), START refresca (o muestra cómo
//! iniciar sesión), MENU (fr955: mantener UP) abre el menú, BACK sale. Sin
//! sesión o sin datos solo hay una pantalla (aviso).
class CodexUsageView extends WatchUi.View {

    private const PAGES = 7;

    private var mSkin as Skin or Null;
    private var mPages as Pages or Null;
    private var mPage as Lang.Number = 0;
    private var mLoginMsg as Lang.String or Null;   //!< último fallo de login

    function initialize() {
        View.initialize();
    }

    function onLayout(dc as Graphics.Dc) as Void {
        mSkin = new Skin(dc);
        mPages = new Pages(mSkin as Skin, dc);
    }

    function onShow() as Void {
        if (!UsageStore.needsLogin()) {
            UsageStore.sync(false, method(:onSynced));
        }
    }

    function onSynced(ok as Lang.Boolean) as Void {
        WatchUi.requestUpdate();
    }

    function onLogin(ok as Lang.Boolean, err as Lang.String or Null) as Void {
        mLoginMsg = ok ? null : err;
        mPage = 0;
        if (ok) {
            UsageStore.sync(true, method(:onSynced));
        }
        WatchUi.requestUpdate();
    }

    // --- acciones del delegate ----------------------------------------------

    private function pageCount() as Lang.Number {
        return (UsageStore.needsLogin() || UsageStore.snapshot() == null) ? 1 : PAGES;
    }

    function step(d as Lang.Number) as Void {
        var n = pageCount();
        mPage = ((mPage + d) % n + n) % n;
        WatchUi.requestUpdate();
    }

    //! START / SELECT: inicia sesión si falta; si no, refresca ya.
    function act() as Void {
        if (UsageStore.needsLogin()) {
            login();
        } else {
            UsageStore.sync(true, method(:onSynced));
            WatchUi.requestUpdate();
        }
    }

    function login() as Void {
        mLoginMsg = null;
        CodexAuth.startLogin(method(:onLogin));
        WatchUi.requestUpdate();
    }

    function logout() as Void {
        CodexAuth.logout();
        mPage = 0;
        mLoginMsg = null;
        WatchUi.requestUpdate();
    }

    function openMenu() as Void {
        var m = new WatchUi.Menu2({ :title => "Codex" });
        if (!UsageStore.needsLogin()) {
            m.addItem(new WatchUi.MenuItem("Actualizar", null, :refresh, {}));
        }
        if (CodexAuth.hasCredentials()) {
            m.addItem(new WatchUi.MenuItem("Cerrar sesión", null, :logout, {}));
        } else if (UsageStore.needsLogin()) {
            m.addItem(new WatchUi.MenuItem("Cómo iniciar sesión", null, :login, {}));
        }
        WatchUi.pushView(m, new CodexMenuDelegate(self), WatchUi.SLIDE_UP);
    }

    // --- pintado ---------------------------------------------------------------

    function onUpdate(dc as Graphics.Dc) as Void {
        var sk = mSkin as Skin;
        var pg = mPages as Pages;
        var pal = sk.pal;
        if (dc has :setAntiAlias) {
            dc.setAntiAlias(true);
        }
        dc.setColor(pal.text, pal.bg);
        dc.clear();

        var now = Time.now().value();
        if (UsageStore.needsLogin()) {
            // v1: la sesión se crea en el portátil (device code) y se hornea en
            // un build personal (SPEC.md, "Autenticación · Vía 1").
            var msg = "Sesión: ejecuta scripts/codex-login.py en el portátil y scripts/bake-personal.sh";
            var col = pal.dim;
            if (mLoginMsg != null) {
                msg = mLoginMsg;
                col = pal.amber;
            }
            pg.drawNotice(dc, "Sin sesión", msg, col);
            return;
        }

        var snap = UsageStore.snapshot();
        var err = UsageStore.lastError();
        var busy = UsageStore.isBusy();
        if (snap == null) {
            if (busy) {
                pg.drawNotice(dc, "Cargando…", "Obteniendo tu uso", pal.dim);
            } else if (err != null) {
                pg.drawNotice(dc, "Sin datos", err, pal.amber);
            } else {
                pg.drawNotice(dc, "Sin datos", "Pulsa START para actualizar", pal.dim);
            }
            return;
        }

        if (mPage >= PAGES) {
            mPage = 0;
        }
        var fetched = UsageStore.fetchEpoch();
        switch (mPage) {
            case 0:
                var status = null;
                var warn = false;
                if (busy) {
                    status = "Actualizando…";
                } else if (err != null) {
                    status = err + " · " + Fmt.ago(fetched, now);
                    warn = true;
                }
                pg.drawMain(dc, snap, now, status, warn);
                break;
            case 1:
                pg.drawWeekly(dc, snap, now, fetched);
                break;
            case 2:
                pg.drawOther(dc, snap, now);
                break;
            case 3:
                pg.drawProj(dc, snap, now, false);
                break;
            case 4:
                pg.drawProj(dc, snap, now, true);
                break;
            case 5:
                pg.drawActivity(dc, snap, now, UsageStore.history());
                break;
            default:
                pg.drawResets(dc, snap, now);
                break;
        }
        sk.dots(dc, mPage, PAGES);
    }
}

//! Entrada del widget. La vista activa se obtiene con getCurrentView() (el
//! delegate lo crea CodexUsageApp sin argumentos).
class CodexUsageDelegate extends WatchUi.BehaviorDelegate {

    function initialize() {
        BehaviorDelegate.initialize();
    }

    private function view() as CodexUsageView or Null {
        var vs = WatchUi.getCurrentView();
        if (vs != null && vs.size() > 0 && (vs[0] instanceof CodexUsageView)) {
            return vs[0] as CodexUsageView;
        }
        return null;
    }

    function onNextPage() as Lang.Boolean {
        var v = view();
        if (v != null) { v.step(1); }
        return true;
    }

    function onPreviousPage() as Lang.Boolean {
        var v = view();
        if (v != null) { v.step(-1); }
        return true;
    }

    function onSelect() as Lang.Boolean {
        var v = view();
        if (v != null) { v.act(); }
        return true;
    }

    function onMenu() as Lang.Boolean {
        var v = view();
        if (v != null) { v.openMenu(); }
        return true;
    }
}

//! Menú: Actualizar / Cerrar sesión / Cómo iniciar sesión.
class CodexMenuDelegate extends WatchUi.Menu2InputDelegate {

    private var mView as CodexUsageView;

    function initialize(v as CodexUsageView) {
        Menu2InputDelegate.initialize();
        mView = v;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        WatchUi.popView(WatchUi.SLIDE_DOWN);
        if (id == :refresh) {
            mView.act();
        } else if (id == :logout) {
            mView.logout();
        } else if (id == :login) {
            mView.login();
        }
    }
}
