using Toybox.Lang;
using Toybox.Time;
using Toybox.Time.Gregorian;

//! Fechas y textos en español (hora local del reloj).
(:glance)
module Fmt {
    const DAYS_S = ["dom", "lun", "mar", "mié", "jue", "vie", "sáb"];
    const DAYS_L = ["domingo", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado"];
    const MONTHS = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"];

    function pad2(n as Lang.Number) as Lang.String {
        return (n < 10) ? "0" + n : n.toString();
    }

    function info(e as Lang.Number) as Gregorian.Info {
        return Gregorian.info(new Time.Moment(e), Time.FORMAT_SHORT);
    }

    //! "22:19"
    function clock(e as Lang.Number) as Lang.String {
        var i = info(e);
        return pad2(i.hour) + ":" + pad2(i.min);
    }

    //! Días de calendario (local) de e respecto a now: 0 hoy, 1 mañana, -1 ayer.
    function dayDiff(e as Lang.Number, now as Lang.Number) as Lang.Number {
        var a = info(e);
        var b = info(now);
        var ma = e - (a.hour * 3600 + a.min * 60 + a.sec);
        var mb = now - (b.hour * 3600 + b.min * 60 + b.sec);
        var d = ma - mb;
        return ((d + ((d >= 0) ? 43200 : -43200)) / 86400);
    }

    //! "a las 22:19" (próximas horas) o "el mié, 20:59".
    function resetWhen(e as Lang.Number, now as Lang.Number) as Lang.String {
        if (e <= now) {
            return "ahora";
        }
        if (e - now < 72000 || dayDiff(e, now) <= 0) {
            return "a las " + clock(e);
        }
        return "el " + DAYS_S[(info(e).day_of_week as Lang.Number) - 1] + ", " + clock(e);
    }

    //! Para frases: "a las 20:59" (hoy / próximas horas) o "el mié a las 20:59".
    function resetAt(e as Lang.Number, now as Lang.Number) as Lang.String {
        if (e <= now) {
            return "ahora";
        }
        if (e - now < 72000 || dayDiff(e, now) <= 0) {
            return "a las " + clock(e);
        }
        return "el " + DAYS_S[(info(e).day_of_week as Lang.Number) - 1] + " a las " + clock(e);
    }

    function part(hour as Lang.Number) as Lang.String {
        if (hour < 6) { return "de madrugada"; }
        if (hour < 13) { return "por la mañana"; }
        if (hour < 20) { return "por la tarde"; }
        return "por la noche";
    }

    //! "hoy a las 10:40", "mañana por la mañana", "el miércoles por la noche".
    function whenPhrase(e as Lang.Number, now as Lang.Number) as Lang.String {
        var i = info(e);
        var d = dayDiff(e, now);
        if (d <= 0) { return "hoy a las " + pad2(i.hour) + ":" + pad2(i.min); }
        if (d == 1) { return "mañana " + part(i.hour); }
        return "el " + DAYS_L[(i.day_of_week as Lang.Number) - 1] + " " + part(i.hour);
    }

    //! "del miércoles", "de hoy", "de mañana" (tras "reinicio").
    function resetDay(e as Lang.Number, now as Lang.Number) as Lang.String {
        var d = dayDiff(e, now);
        if (d <= 0) { return "de hoy"; }
        if (d == 1) { return "de mañana"; }
        return "del " + DAYS_L[(info(e).day_of_week as Lang.Number) - 1];
    }

    //! "el 10 dic" (lejos) o "el 17 nov, 8:59" (a menos de 7 días).
    function expiry(e as Lang.Number, now as Lang.Number) as Lang.String {
        var i = info(e);
        var s = "el " + i.day + " " + MONTHS[(i.month as Lang.Number) - 1];
        if (e - now < 604800) {
            s += ", " + i.hour + ":" + pad2(i.min);
        }
        return s;
    }

    //! "ahora", "hace 3 min", "hace 2 h", "hace 5 d".
    function ago(e as Lang.Number or Null, now as Lang.Number) as Lang.String {
        if (e == null) {
            return "sin datos";
        }
        var s = now - e;
        if (s < 60) { return "ahora"; }
        if (s < 3600) { return "hace " + (s / 60) + " min"; }
        if (s < 86400) { return "hace " + (s / 3600) + " h"; }
        return "hace " + (s / 86400) + " d";
    }

    //! "92 %" (separado con espacio, como en la app de Claude).
    function pct(p as Lang.Numeric) as Lang.String {
        return p.toNumber() + " %";
    }
}
