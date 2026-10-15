import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! Glance (API 3.1.0): where to and how soon, minutes first.
//!   ▸ Одинцово
//!   через 3 мин · 15:05, далее 15:11
//! Uses the system glance font (FONT_GLANCE, API 3.1.8) like built-in glances;
//! the minutes are white (orange when it's time to go), the rest gray.
//! On fenix 6 the glance is redrawn by the system, not live (Glances docs),
//! so it only reads Storage and draws.
(:glance)
class TrainsGlanceView extends WatchUi.GlanceView {
    // Trains within the walk to the station are skipped (see TrainsView).
    private const MISSED_ROOM = 20;
    // The glance area runs under the round bezel on its right end.
    private const BEZEL_PERCENT = 12;

    public function initialize() {
        GlanceView.initialize();
    }

    public function onUpdate(dc as Dc) as Void {
        var h = dc.getHeight();
        var font = Graphics.FONT_GLANCE;

        if (!Schedule.isConfigured()) {
            drawLine(dc, h / 2, [WatchUi.loadResource($.Rez.Strings.NoStations) as String, Graphics.COLOR_WHITE]);
            return;
        }

        var toWork = Departures.direction(false);
        var now = Departures.nowMinutes(toWork);
        var size = Draw.arrowSize(dc, font);
        var indent = size + size / 2 + 2;
        var dest = Draw.fit(dc, Departures.shorterTitles(Departures.titles(toWork)[1]), [font], usableWidth(dc) - indent);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        Draw.arrow(dc, 0, h / 4, size);
        dc.drawText(indent, h / 4, font, dest[0], Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        drawLine(dc, 3 * h / 4, secondLine(dc, toWork, now));
    }

    //! [text, color, ...] for Draw.pieces.
    private function secondLine(dc as Dc, toWork as Boolean, now as Number) as Array {
        var gray = Graphics.COLOR_LT_GRAY;
        var walk = Schedule.walkMinutes();
        var all = Departures.upcoming(toWork, 2 + MISSED_ROOM, now);
        if (all == null) {
            var err = Departures.error();
            return err != null
                ? [err[0] + " ", Graphics.COLOR_ORANGE, err[1], Graphics.COLOR_WHITE]
                : [WatchUi.loadResource($.Rez.Strings.NoData) as String, gray];
        }
        var trains = Departures.forScreen(all, now, walk, 2);
        all = null;
        if (trains.size() == 0) {
            return [WatchUi.loadResource($.Rez.Strings.NoTrains) as String, gray];
        }

        var dep = trains[0][Departures.DEP] as Number;
        var leave = Departures.leaveIn(dep, now, walk);
        var urgency = Departures.urgency(leave);
        var color = urgency == Departures.CALM ? Graphics.COLOR_WHITE : Graphics.COLOR_ORANGE;
        var parts;
        if (urgency == Departures.NOW) {
            parts = [WatchUi.loadResource(walk > 0 ? $.Rez.Strings.LeaveNow : $.Rez.Strings.Departing) as String, color];
        } else {
            var caption = WatchUi.loadResource(walk > 0 ? $.Rez.Strings.LeaveIn : $.Rez.Strings.In) as String;
            parts = [caption + " ", gray,
                     Departures.duration(leave, WatchUi.loadResource($.Rez.Strings.Hour) as String,
                         WatchUi.loadResource($.Rez.Strings.Min) as String), color];
        }
        parts.addAll([" · " + Departures.hhmm(dep), gray]);

        // ", далее 15:11" only when there is room for it.
        if (trains.size() > 1) {
            var then = ", " + WatchUi.loadResource($.Rez.Strings.Then) + " "
                + Departures.hhmm(trains[1][Departures.DEP] as Number);
            if (Draw.piecesWidth(dc, Graphics.FONT_GLANCE, parts) + dc.getTextWidthInPixels(then, Graphics.FONT_GLANCE)
                <= usableWidth(dc)) {
                parts.addAll([then, gray]);
            }
        }
        return parts;
    }

    private function usableWidth(dc as Dc) as Number {
        return dc.getWidth() * (100 - BEZEL_PERCENT) / 100;
    }

    private function drawLine(dc as Dc, y as Number, parts as Array) as Void {
        Draw.pieces(dc, 0, y, Graphics.FONT_GLANCE, parts, false);
    }
}
