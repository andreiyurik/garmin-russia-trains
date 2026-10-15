import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.Timer;
import Toybox.WatchUi;

//! Main widget view. One question, answered at a glance: can I make it?
//!            Лобня
//!         ▸ Одинцово
//!           через                <- "выход через" when WalkMinutes > 0
//!           3 мин                <- biggest thing on screen; orange when it's time to go
//!     15:05 ЭКС · пл. 1
//!          ▸ Одинцово             <- where the train goes
//!     15:11         9 мин
//!     15:20        18 мин
//!      обновлено 14:48            <- or "время UTC+5" when the station is in another zone
//! Trains the user can no longer catch are not shown. Times are the station's
//! (as on its departure board). Light-on-dark and system fonts, numbers
//! first, centered for round screens, per the UX guidelines for MIP screens.
class TrainsView extends WatchUi.View {
    private const ROWS = 3; // the train to catch and two after it
    // Trains within the walk to the station are skipped: fetch enough of them
    // for a dense line (a train every 3 min, a 60 min walk).
    private const MISSED_ROOM = 25;
    private const MARGIN = 6;

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
        var h = dc.getHeight();
        var cx = dc.getWidth() / 2;
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        if (!Schedule.isConfigured()) {
            drawMessage(dc, h / 2, Graphics.FONT_SMALL, $.Rez.Strings.NoStations, Graphics.COLOR_WHITE);
            return;
        }

        // One clock reading per frame keeps every row consistent.
        var toWork = Departures.direction(_flipped);
        var now = Departures.nowMinutes(toWork);
        drawHeader(dc, cx, h, Departures.titles(toWork));

        var walk = Schedule.walkMinutes();
        var all = Departures.upcoming(toWork, ROWS + MISSED_ROOM, now);
        var trains = all != null ? Departures.forScreen(all, now, walk, ROWS) : null;
        all = null;
        var err = Departures.error();
        if (trains == null && err != null) {
            // Nothing to show: the reason gets the middle of the screen.
            drawText(dc, cx, h * 44 / 100, [err[0]], [Graphics.FONT_TINY, Graphics.FONT_XTINY], Graphics.COLOR_ORANGE);
            drawText(dc, cx, h * 56 / 100, [err[1]], [Graphics.FONT_SMALL, Graphics.FONT_TINY], Graphics.COLOR_WHITE);
        } else if (trains == null || trains.size() == 0) {
            drawMessage(dc, h / 2, Graphics.FONT_SMALL,
                trains == null ? $.Rez.Strings.NoData : $.Rez.Strings.NoTrains, Graphics.COLOR_WHITE);
        } else {
            drawHero(dc, cx, h, trains[0], now, walk);
            for (var i = 1; i < trains.size(); i++) {
                drawRow(dc, cx, h * (63 + 9 * i) / 100, trains[i], now, walk);
            }
        }

        if (trains != null || err == null || _status.length() > 0) {
            drawText(dc, cx, h * 90 / 100, [footer(err, toWork)], [Graphics.FONT_XTINY], Graphics.COLOR_LT_GRAY);
        }
    }

    //! "Лобня" over "▸ Одинцово"; long terminal names get shorter forms.
    private function drawHeader(dc as Dc, cx as Number, h as Number, titles as [String, String]) as Void {
        drawText(dc, cx, h * 12 / 100, Departures.shorterTitles(titles[0]), [Graphics.FONT_XTINY], Graphics.COLOR_LT_GRAY);
        var y = h * 21 / 100;
        var arrow = Draw.arrowSize(dc, Graphics.FONT_TINY) * 2;
        var fitted = Draw.fit(dc, Departures.shorterTitles(titles[1]), [Graphics.FONT_TINY, Graphics.FONT_XTINY],
            Draw.chord(dc, y, MARGIN) - arrow);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        Draw.arrowTextCentered(dc, cx, y, fitted[1], fitted[0]);
    }

    //! The train to catch: minutes big in the middle, then time, express,
    //! platform and where it goes.
    private function drawHero(dc as Dc, cx as Number, h as Number, train as Array, now as Number, walk as Number) as Void {
        var dep = train[Departures.DEP] as Number;
        var leave = Departures.leaveIn(dep, now, walk);
        var urgency = Departures.urgency(leave);
        var color = urgency == Departures.CALM ? Graphics.COLOR_WHITE : Graphics.COLOR_ORANGE;
        var y = h * 42 / 100;

        if (urgency == Departures.NOW) {
            var label = walk > 0 ? $.Rez.Strings.LeaveNow : $.Rez.Strings.Departing;
            drawText(dc, cx, y, [WatchUi.loadResource(label) as String], [Graphics.FONT_LARGE, Graphics.FONT_MEDIUM], color);
        } else {
            var caption = walk > 0 ? $.Rez.Strings.LeaveIn : $.Rez.Strings.In;
            drawText(dc, cx, h * 30 / 100, [WatchUi.loadResource(caption) as String], [Graphics.FONT_XTINY], Graphics.COLOR_LT_GRAY);
            if (leave < 60) {
                drawNumber(dc, cx, y, leave, color);
            } else {
                drawText(dc, cx, y, [Departures.duration(leave, hourLabel(), minLabel())], [Graphics.FONT_MEDIUM], color);
            }
        }

        // "15:05 ЭКС · пл. 1"; the platform is left out when the line is too wide.
        var flags = train[Departures.FLAGS] as Number;
        var dy = h * 54 / 100;
        var parts = [Departures.hhmm(dep), Graphics.COLOR_WHITE] as Array;
        if (flags != 0) {
            parts.addAll([" " + expressLabel(flags), Graphics.COLOR_YELLOW]);
        }
        var platform = Departures.platformLabel(train[Departures.PLATFORM] as String,
            WatchUi.loadResource($.Rez.Strings.Platform) as String);
        platform = " · " + platform;
        if (platform.length() > 3 && Draw.piecesWidth(dc, Graphics.FONT_TINY, parts)
            + dc.getTextWidthInPixels(platform, Graphics.FONT_TINY) <= Draw.chord(dc, dy, MARGIN)) {
            parts.addAll([platform, Graphics.COLOR_LT_GRAY]);
        }
        Draw.pieces(dc, cx, dy, Graphics.FONT_TINY, parts, true);

        var terminal = train[Departures.TERMINAL] as String;
        if (terminal.length() > 0) {
            var ty = h * 62 / 100;
            var fitted = Draw.fit(dc, Departures.shorterTitles(terminal), [Graphics.FONT_XTINY],
                Draw.chord(dc, ty, MARGIN) - Draw.arrowSize(dc, Graphics.FONT_XTINY) * 2);
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            Draw.arrowTextCentered(dc, cx, ty, fitted[1], fitted[0]);
        }
    }

    //! "3 мин": the number in the large digit font, the unit beside it.
    private function drawNumber(dc as Dc, cx as Number, y as Number, minutes as Number, color as ColorType) as Void {
        var numberFont = Graphics.FONT_NUMBER_MEDIUM;
        var unitFont = Graphics.FONT_SMALL;
        var number = minutes.toString();
        var unit = minLabel();
        var gap = 6;
        var width = dc.getTextWidthInPixels(number, numberFont) + gap + dc.getTextWidthInPixels(unit, unitFont);
        var x = cx - width / 2;
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y, numberFont, number, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        // The unit sits on the digits' baseline rather than their middle.
        var drop = (dc.getFontHeight(numberFont) - dc.getFontHeight(unitFont)) / 4;
        dc.drawText(x + width - dc.getTextWidthInPixels(unit, unitFont), y + drop, unitFont, unit,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    //! A later train: "15:11 ЭКС" left of the middle, "9 мин" right of it.
    private function drawRow(dc as Dc, cx as Number, y as Number, train as Array, now as Number, walk as Number) as Void {
        var font = Graphics.FONT_SMALL;
        var gap = 8;
        var dep = train[Departures.DEP] as Number;
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx - gap, y, font, Departures.hhmm(dep), Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
        var flags = train[Departures.FLAGS] as Number;
        var minutes = Departures.duration(Departures.leaveIn(dep, now, walk), hourLabel(), minLabel());
        var parts = [minutes, Graphics.COLOR_LT_GRAY] as Array;
        if (flags != 0) {
            parts.addAll([" " + expressLabel(flags), Graphics.COLOR_YELLOW]);
        }
        Draw.pieces(dc, cx + gap, y, Graphics.FONT_TINY, parts, false);
    }

    private function expressLabel(flags as Number) as String {
        return WatchUi.loadResource(flags == Schedule.FLAG_AEROEXPRESS ? $.Rez.Strings.Aeroexpress : $.Rez.Strings.Express) as String;
    }

    private function minLabel() as String {
        return WatchUi.loadResource($.Rez.Strings.Min) as String;
    }

    private function hourLabel() as String {
        return WatchUi.loadResource($.Rez.Strings.Hour) as String;
    }

    //! Status of a running refresh, else the last error's title (the screen is
    //! narrow at the bottom), else the station's time zone when it differs
    //! from the watch's ("время UTC+5": the times on screen are the station's),
    //! else when the schedule was fetched.
    private function footer(err as [String, String]?, toWork as Boolean) as String {
        if (_status.length() > 0) {
            return _status;
        }
        if (err != null) {
            return err[0];
        }
        var zone = Departures.foreignZone(toWork);
        if (zone != null) {
            return WatchUi.loadResource($.Rez.Strings.StationTime) + " " + zone;
        }
        var day = Schedule.load(Schedule.dateString(0));
        if (day == null) {
            return "";
        }
        var info = Gregorian.info(new Time.Moment(day["t"] as Number), Time.FORMAT_SHORT);
        return WatchUi.loadResource($.Rez.Strings.UpdatedAt) + " " + info.hour.format("%02d") + ":" + info.min.format("%02d");
    }

    //! One line, centered, in the first font (and form) that fits the round screen there.
    private function drawText(dc as Dc, cx as Number, y as Number, texts as Array<String>, fonts as Array<FontType>,
                              color as ColorType) as Void {
        var fitted = Draw.fit(dc, texts, fonts, Draw.chord(dc, y, MARGIN));
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, y, fitted[1], fitted[0], Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    //! A sentence wrapped to the middle of the screen.
    private function drawMessage(dc as Dc, y as Number, font as FontType, id as ResourceId, color as ColorType) as Void {
        var width = Draw.chord(dc, y, MARGIN * 3);
        var text = Graphics.fitTextToArea(WatchUi.loadResource(id) as String, font, width, dc.getHeight() / 2, true);
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(dc.getWidth() / 2, y, font, text, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }
}
