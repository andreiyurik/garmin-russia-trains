import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! Glance (API 3.1.0): destination and the next train the user can catch.
//!   ▸ Беговая
//!   08:42 · выход 4 мин
//! Uses the system glance font (FONT_GLANCE, API 3.1.8) like built-in glances.
//! On fenix 6 the glance is redrawn by the system, not live (Glances docs),
//! so it only reads Storage and draws.
(:glance)
class TrainsGlanceView extends WatchUi.GlanceView {

    public function initialize() {
        GlanceView.initialize();
    }

    public function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var h = dc.getHeight();

        if (!Schedule.isConfigured()) {
            drawLine(dc, h / 2, Graphics.FONT_GLANCE, WatchUi.loadResource($.Rez.Strings.NoStations) as String);
            return;
        }

        var toWork = Departures.direction(false);
        var now = Departures.nowMinutes(toWork);
        var size = dc.getFontHeight(Graphics.FONT_GLANCE) / 3;
        Draw.arrow(dc, 0, h / 4, size);
        dc.drawText(size + size / 2 + 2, h / 4, Graphics.FONT_GLANCE, Departures.titles(toWork)[1],
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        drawLine(dc, 3 * h / 4, Graphics.FONT_GLANCE, secondLine(toWork, now));
    }

    private function secondLine(toWork as Boolean, now as Number) as String {
        var trains = Departures.upcoming(toWork, 6, now);
        if (trains == null) {
            var err = Departures.error();
            return err != null ? err[0] + " " + err[1] : WatchUi.loadResource($.Rez.Strings.NoData) as String;
        }
        var walk = Schedule.walkMinutes();
        var i = Departures.firstCatchable(trains, now, walk);
        if (i < 0) {
            return WatchUi.loadResource($.Rez.Strings.NoTrains) as String;
        }
        var dep = trains[i][Departures.DEP] as Number;
        var mins = Departures.duration(Departures.leaveIn(dep, now, walk),
            WatchUi.loadResource($.Rez.Strings.Hour) as String, WatchUi.loadResource($.Rez.Strings.Min) as String);
        if (walk > 0) {
            mins = WatchUi.loadResource($.Rez.Strings.LeaveIn) + " " + mins;
        }
        return Departures.hhmm(dep) + " · " + mins;
    }

    private function drawLine(dc as Dc, y as Number, font as FontType, text as String) as Void {
        dc.drawText(0, y, font, text, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
    }
}
