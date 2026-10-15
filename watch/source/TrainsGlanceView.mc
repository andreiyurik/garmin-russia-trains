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
    // The glance area runs under the round bezel on its right end.
    private const BEZEL_PERCENT = 12;

    public function initialize() {
        GlanceView.initialize();
    }

    public function onUpdate(dc as Dc) as Void {
        var h = dc.getHeight();
        var font = Graphics.FONT_GLANCE;

        if (!Schedule.isConfigured()) {
            var text = Graphics.fitTextToArea(WatchUi.loadResource($.Rez.Strings.NoStations) as String, font,
                usableWidth(dc), h, true);
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(0, h / 2, font, text, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
            return;
        }

        var toWork = Departures.direction(false);
        var now = Departures.nowMinutes(toWork);
        var walk = Schedule.walkMinutes();
        // From now + walk: trains the user can no longer catch are left out.
        var trains = Departures.upcoming(toWork, 2, now + walk);
        var err = trains == null ? Departures.error() : null;
        if (err != null) {
            // Nothing to show: the problem takes both lines ("Specify the station:" / "Перово, Москва?").
            drawLine(dc, h / 4, [fitted(dc, err[0]), Graphics.COLOR_ORANGE]);
            drawLine(dc, 3 * h / 4, [fitted(dc, err[1]), Graphics.COLOR_WHITE]);
            return;
        }

        var size = Draw.arrowSize(dc, font);
        var indent = size + size / 2 + 2;
        var dest = Draw.fit(dc, Departures.shorterTitles(Departures.titles(toWork)[1]), [font], usableWidth(dc) - indent);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        Draw.arrow(dc, 0, h / 4, size);
        dc.drawText(indent, h / 4, font, dest[0], Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        drawLine(dc, 3 * h / 4, secondLine(dc, trains, now, walk));
    }

    //! [text, color, ...] for Draw.pieces: "через 3 мин · 15:05, далее 15:11",
    //! shortened when the glance is narrow.
    private function secondLine(dc as Dc, trains as Array<Array>?, now as Number, walk as Number) as Array {
        var gray = Graphics.COLOR_LT_GRAY;
        if (trains == null || trains.size() == 0) {
            var none = trains == null ? $.Rez.Strings.NoData : $.Rez.Strings.NoTrains;
            return [fitted(dc, WatchUi.loadResource(none) as String), gray];
        }

        var dep = trains[0][Departures.DEP] as Number;
        var leave = Departures.leaveIn(dep, now, walk);
        var urgency = Departures.urgency(leave);
        var color = urgency == Departures.CALM ? Graphics.COLOR_WHITE : Graphics.COLOR_ORANGE;
        var caption = [] as Array<Object?>;
        var minutes;
        if (urgency == Departures.NOW) {
            minutes = WatchUi.loadResource(walk > 0 ? $.Rez.Strings.LeaveNow : $.Rez.Strings.Departing) as String;
        } else {
            caption = [WatchUi.loadResource(walk > 0 ? $.Rez.Strings.LeaveIn : $.Rez.Strings.In) + " ", gray] as Array<Object?>;
            minutes = Departures.duration(leave, WatchUi.loadResource($.Rez.Strings.Hour) as String,
                WatchUi.loadResource($.Rez.Strings.Min) as String);
        }
        var time = [" · " + Departures.hhmm(dep), gray] as Array<Object?>;
        var then = [] as Array<Object?>;
        if (trains.size() > 1) {
            then = [", " + WatchUi.loadResource($.Rez.Strings.Then) + " "
                + Departures.hhmm(trains[1][Departures.DEP] as Number), gray] as Array<Object?>;
        }

        // Longest first: "then …" goes first, then the time, then the caption
        // ("выход через 3 мин" says more than "3 мин · 08:28"); the minutes
        // always stay. (addAll changes the array it is called on, so every
        // option is built from fresh copies.)
        var shortest = [minutes, color] as Array<Object?>;
        var noTime = caption.slice(0, null).addAll(shortest);
        var full = noTime.slice(0, null).addAll(time);
        var options = [full.slice(0, null).addAll(then), full, noTime, shortest.slice(0, null).addAll(time), shortest]
            as Array<Array>;
        for (var i = 0; i < options.size() - 1; i++) {
            if (Draw.piecesWidth(dc, Graphics.FONT_GLANCE, options[i]) <= usableWidth(dc)) {
                return options[i];
            }
        }
        return options[options.size() - 1];
    }

    private function fitted(dc as Dc, text as String) as String {
        return Draw.fit(dc, [text], [Graphics.FONT_GLANCE], usableWidth(dc))[0];
    }

    private function usableWidth(dc as Dc) as Number {
        return dc.getWidth() * (100 - BEZEL_PERCENT) / 100;
    }

    private function drawLine(dc as Dc, y as Number, parts as Array) as Void {
        Draw.pieces(dc, 0, y, Graphics.FONT_GLANCE, parts, false);
    }
}
