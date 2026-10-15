import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.Timer;
import Toybox.WatchUi;

//! Main widget view.
//!          Одинцово
//!        ▸ Беговая
//!   08:42 ЭКС        4 мин     <- first train the user can catch, large
//!   ▸ Лобня · пл. 2
//!   08:51           13 мин
//!   09:03           25 мин
//!   мин до выхода · 05:12      <- or "· UTC+5" when the station is in another zone
//! Times are the station's (as on its departure board). Minutes are "until you should leave" when WalkMinutes > 0, otherwise until
//! departure. Missed trains are gray. Light-on-dark and system fonts with
//! numbers first, per the UX guidelines for MIP screens.
class TrainsView extends WatchUi.View {
    private const ROWS = 4;
    private const HURRY_MINUTES = 2;

    private var _flipped as Boolean = false;
    private var _status as String = "";
    private var _timer as Timer.Timer = new Timer.Timer();

    public function initialize() {
        View.initialize();
    }

    public function onShow() as Void {
        // Minutes change once a minute; a 30 s tick keeps them current.
        _timer.start(method(:tick), 30000, true);
    }

    public function onHide() as Void {
        _timer.stop();
    }

    public function tick() as Void {
        WatchUi.requestUpdate();
    }

    public function flip() as Void {
        _flipped = !_flipped;
        WatchUi.requestUpdate();
    }

    public function setStatus(status as String) as Void {
        _status = status;
        WatchUi.requestUpdate();
    }

    public function onUpdate(dc as Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        if (!Schedule.isConfigured()) {
            drawCentered(dc, cx, h / 2, Graphics.FONT_SMALL,
                WatchUi.loadResource($.Rez.Strings.NoStations) as String, Graphics.COLOR_WHITE);
            return;
        }

        // One clock reading per frame keeps every row consistent.
        var toWork = Departures.direction(_flipped);
        var now = Departures.nowMinutes(toWork);
        var titles = Departures.titles(toWork);
        drawCentered(dc, cx, h * 13 / 100, Graphics.FONT_XTINY, titles[0], Graphics.COLOR_LT_GRAY);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        Draw.arrowTextCentered(dc, cx, h * 22 / 100, Graphics.FONT_TINY, titles[1]);

        var trains = Departures.upcoming(toWork, ROWS, now);
        var err = Departures.error();
        if (trains == null && err != null) {
            // Nothing to show: the reason gets the middle of the screen.
            drawCentered(dc, cx, h * 45 / 100, Graphics.FONT_TINY, err[0], Graphics.COLOR_ORANGE);
            drawCentered(dc, cx, h * 57 / 100, Graphics.FONT_SMALL, err[1], Graphics.COLOR_WHITE);
        } else if (trains == null || trains.size() == 0) {
            var msg = trains == null ? $.Rez.Strings.NoData : $.Rez.Strings.NoTrains;
            drawCentered(dc, cx, h / 2, Graphics.FONT_SMALL,
                WatchUi.loadResource(msg) as String, Graphics.COLOR_WHITE);
        } else {
            drawTrains(dc, w, h, trains, now);
        }

        if (trains != null || err == null || _status.length() > 0) {
            drawCentered(dc, cx, h * 87 / 100, Graphics.FONT_XTINY, footer(err, toWork), Graphics.COLOR_LT_GRAY);
        }
    }

    private function drawTrains(dc as Dc, w as Number, h as Number, trains as Array<Array>, now as Number) as Void {
        var left = w * 18 / 100;
        var right = w * 82 / 100;
        var y = h * 35 / 100;
        var line = h * 10 / 100;
        var minLabel = WatchUi.loadResource($.Rez.Strings.Min) as String;
        var hourLabel = WatchUi.loadResource($.Rez.Strings.Hour) as String;
        var walk = Schedule.walkMinutes();
        var featured = Departures.firstCatchable(trains, now, walk);

        for (var i = 0; i < trains.size(); i++) {
            var train = trains[i];
            var dep = train[Departures.DEP] as Number;
            var leave = Departures.leaveIn(dep, now, walk);
            var missed = leave < 0;
            var big = i == featured;
            var font = big ? Graphics.FONT_MEDIUM : Graphics.FONT_SMALL;
            var timeColor = missed ? Graphics.COLOR_DK_GRAY : (big ? Graphics.COLOR_WHITE : Graphics.COLOR_LT_GRAY);

            var time = Departures.hhmm(dep);
            dc.setColor(timeColor, Graphics.COLOR_TRANSPARENT);
            dc.drawText(left, y, font, time, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);

            var flags = train[Departures.FLAGS] as Number;
            if (flags != 0) {
                var label = flags == Schedule.FLAG_AEROEXPRESS ? $.Rez.Strings.Aeroexpress : $.Rez.Strings.Express;
                dc.setColor(missed ? Graphics.COLOR_DK_GRAY : Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
                dc.drawText(left + dc.getTextWidthInPixels(time, font) + 6, y, Graphics.FONT_XTINY,
                    WatchUi.loadResource(label) as String,
                    Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
            }

            var minutes = missed ? WatchUi.loadResource($.Rez.Strings.Missed) as String
                : Departures.duration(leave, hourLabel, minLabel);
            var minColor = missed ? Graphics.COLOR_DK_GRAY
                : (leave <= HURRY_MINUTES ? Graphics.COLOR_ORANGE : Graphics.COLOR_WHITE);
            dc.setColor(minColor, Graphics.COLOR_TRANSPARENT);
            dc.drawText(right, y, big ? Graphics.FONT_SMALL : Graphics.FONT_XTINY, minutes,
                Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);

            if (big) {
                y += line;
                dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
                drawDetails(dc, left, y, train);
            }
            y += line;
        }
    }

    //! "▸ Лобня · пл. 2" under the featured train.
    private function drawDetails(dc as Dc, x as Number, y as Number, train as Array) as Void {
        var font = Graphics.FONT_XTINY;
        var terminal = train[Departures.TERMINAL] as String;
        var platform = train[Departures.PLATFORM] as String;
        if (platform.length() > 0 && platform.toNumber() != null) {
            platform = WatchUi.loadResource($.Rez.Strings.Platform) + " " + platform;
        }
        var text = terminal;
        if (platform.length() > 0) {
            text = terminal.length() > 0 ? terminal + " · " + platform : platform;
        }
        if (text.length() == 0) {
            return;
        }
        var size = dc.getFontHeight(font) / 3;
        if (terminal.length() > 0) {
            Draw.arrow(dc, x, y, size);
            x += size + size / 2 + 2;
        }
        dc.drawText(x, y, font, text, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    //! Status of a running refresh, else the last error's title (the screen is
    //! narrow at the bottom), else what the minutes mean and when the schedule
    //! was fetched, or, when the station is in another time zone than the
    //! watch, that zone ("UTC+3"): the times on screen are the station's.
    private function footer(err as [String, String]?, toWork as Boolean) as String {
        if (_status.length() > 0) {
            return _status;
        }
        if (err != null) {
            return err[0];
        }
        var label = Schedule.walkMinutes() > 0 ? $.Rez.Strings.UntilLeave : $.Rez.Strings.Scheduled;
        var text = WatchUi.loadResource(label) as String;
        var zone = Departures.foreignZone(toWork);
        if (zone != null) {
            return text + " · " + zone;
        }
        var day = Schedule.load(Schedule.dateString(0));
        if (day != null) {
            var info = Gregorian.info(new Time.Moment(day["t"] as Number), Time.FORMAT_SHORT);
            text += " · " + info.hour.format("%02d") + ":" + info.min.format("%02d");
        }
        return text;
    }

    private function drawCentered(dc as Dc, x as Number, y as Number, font as FontType,
                                  text as String, color as ColorType) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y, font, text, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }
}
