import Toybox.Application;
import Toybox.Application.Properties;
import Toybox.Application.Storage;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.Time.Gregorian;

//! Settings and the on-device schedule cache.
//!
//! Each day as returned by the proxy (v3), in three Storage entries:
//!   "d:YYYY-MM-DD"     {"a": title, "b": title, "s": [strings], "za": minutes, "zb": minutes,
//!                       "v": 3, "r": routeKey, "t": fetchedAtEpochSeconds}
//!   "d:YYYY-MM-DD:ab"  [packedTrain, ...]   trains from A to B
//!   "d:YYYY-MM-DD:ba"  [packedTrain, ...]
//! so the glance loads one direction, not the whole day: the densest route
//! (Мытищи - Ярославский вокзал, 536 trains) as one value ran the fenix 6
//! glance out of memory. Days saved before the split keep "ab"/"ba" inside
//! the day entry and are still read.
//! Departure minutes are the station's wall clock; za/zb are the stations' UTC
//! offsets (proxies before all-Russia support did not send them: the device's
//! zone is used then). The last known offsets are kept in "z" as
//! {"r": routeKey, "a": minutes, "b": minutes}, so dates and "now" are the
//! station's even when the watch is in another time zone.
//! A packed train is one Number (layout in Departures and proxy compact.js).
//! The last failed fetch is kept in "err" as {"k": kind, "d": detail, "r": routeKey}
//! so the views can explain it.
//! Storage limits (Persisting Data docs): 8 KB per value, 128 KB total;
//! one day for one route is ~0.5-5 KB.
(:background, :glance)
module Schedule {
    const DAYS_AHEAD = 3;
    const STALE_SECONDS = 12 * 60 * 60;
    const FORMAT = 3;
    // Russia spans UTC+2..+12; anything outside UTC-12..+14 is broken data.
    const MIN_OFFSET = -12 * 60;
    const MAX_OFFSET = 14 * 60;
    // Flags only mark express kinds (proxy compact.js): 0 = regular train.
    const FLAG_EXPRESS = 1;
    const FLAG_AEROEXPRESS = 2;

    // Kinds of the last fetch error.
    enum {
        ERROR_PHONE = 1,   // no phone / Bluetooth / timeout: try again later
        ERROR_SERVER = 2,  // the proxy answered with an error or bad data
        ERROR_STATION = 3, // a station name was not found; detail = the name
        ERROR_AMBIGUOUS = 4, // several stations have this name; detail = what to type
        ERROR_LIMIT = 5    // the proxy is out of Yandex requests for today
    }

    // A stored train is one Number (see proxy compact.js):
    // bits 0-10 departure minute, 11-12 flags, 13-20 terminal, 21-28 platform.
    function departureOf(train as Number) as Number {
        return train & 0x7FF;
    }

    function flagsOf(train as Number) as Number {
        return (train >> 11) & 0x3;
    }

    function terminalOf(train as Number) as Number {
        return (train >> 13) & 0xFF;
    }

    function platformOf(train as Number) as Number {
        return (train >> 21) & 0xFF;
    }

    function home() as String {
        return Properties.getValue("HomeStation") as String;
    }

    function work() as String {
        return Properties.getValue("WorkStation") as String;
    }

    function switchHour() as Number {
        return Properties.getValue("SwitchHour") as Number;
    }

    function walkMinutes() as Number {
        return Properties.getValue("WalkMinutes") as Number;
    }

    function hideExpress() as Boolean {
        return Properties.getValue("HideExpress") as Boolean;
    }

    function proxyUrl() as String {
        return Properties.getValue("ProxyUrl") as String;
    }

    function isConfigured() as Boolean {
        return home().length() > 0 && work().length() > 0;
    }

    //! Cached days are tied to the stations they were fetched for.
    function routeKey() as String {
        return home() + "|" + work();
    }

    //! "2026-10-07" for today + dayOffset at Home (station A): the date the
    //! days are fetched and stored under.
    function dateString(dayOffset as Number) as String {
        return dateFor(dayOffset, true);
    }

    //! Today + dayOffset at the departure station of a direction.
    function dateFor(dayOffset as Number, toWork as Boolean) as String {
        return dateAt(Time.now().value(), utcOffset(toWork), dayOffset);
    }

    //! The date at epoch + offsetSeconds, plus dayOffset days.
    function dateAt(epoch as Number, offsetSeconds as Number, dayOffset as Number) as String {
        var moment = new Time.Moment(epoch + offsetSeconds + dayOffset * Gregorian.SECONDS_PER_DAY);
        var info = Gregorian.utcInfo(moment, Time.FORMAT_SHORT);
        return Lang.format("$1$-$2$-$3$", [
            info.year,
            (info.month as Number).format("%02d"),
            info.day.format("%02d")
        ]);
    }

    //! UTC offset in seconds of the departure station (A toward work, B back),
    //! or the device's when the proxy has not told it yet.
    function utcOffset(toWork as Boolean) as Number {
        var zones = Storage.getValue("z");
        if (zones instanceof Dictionary && routeKey().equals(zones["r"])) {
            var minutes = zones[toWork ? "a" : "b"];
            if (minutes instanceof Number) {
                return minutes * 60;
            }
        }
        return System.getClockTime().timeZoneOffset;
    }

    function dateOf(moment as Time.Moment) as String {
        var info = Gregorian.info(moment, Time.FORMAT_SHORT);
        return Lang.format("$1$-$2$-$3$", [
            info.year,
            (info.month as Number).format("%02d"),
            info.day.format("%02d")
        ]);
    }

    //! The day entry (titles, strings, offsets, fetch time) if it belongs to
    //! the current stations, else null. Trains: trains().
    function load(date as String) as Dictionary? {
        var day = Storage.getValue("d:" + date);
        if (!(day instanceof Dictionary)) {
            return null;
        }
        var version = day["v"];
        if (version instanceof Number && version == FORMAT && routeKey().equals(day["r"])) {
            return day as Dictionary;
        }
        return null;
    }

    //! The trains of one direction of a loaded day.
    function trains(date as String, day as Dictionary, toWork as Boolean) as Array<Number> {
        var key = toWork ? "ab" : "ba";
        var list = Storage.getValue("d:" + date + ":" + key);
        if (!(list instanceof Array)) {
            list = day[key]; // saved before the split
        }
        return list instanceof Array ? list as Array<Number> : [] as Array<Number>;
    }

    //! Checks a proxy response before it is stored, so a changed or broken
    //! response becomes an error message instead of a crash in the views.
    function isValid(day as Dictionary) as Boolean {
        var version = day["v"];
        var strings = day["s"];
        if (!(version instanceof Number) || version != FORMAT
            || !(day["a"] instanceof String) || !(day["b"] instanceof String)
            || !(strings instanceof Array)) {
            return false;
        }
        for (var i = 0; i < strings.size(); i++) {
            if (!(strings[i] instanceof String)) {
                return false;
            }
        }
        return isValidTrains(day["ab"] as Object?, strings.size())
            && isValidTrains(day["ba"] as Object?, strings.size())
            && isValidOffset(day["za"] as Object?)
            && isValidOffset(day["zb"] as Object?);
    }

    //! Optional: absent is fine, otherwise minutes east of UTC.
    function isValidOffset(offset as Object?) as Boolean {
        return offset == null
            || (offset instanceof Number && offset >= MIN_OFFSET && offset <= MAX_OFFSET);
    }

    function isValidTrains(trains as Object?, stringCount as Number) as Boolean {
        if (!(trains instanceof Array)) {
            return false;
        }
        for (var i = 0; i < trains.size(); i++) {
            var train = trains[i];
            if (!(train instanceof Number) || train < 0
                || departureOf(train) >= 24 * 60
                || terminalOf(train) >= stringCount
                || platformOf(train) >= stringCount) {
                return false;
            }
        }
        return true;
    }

    function save(date as String, day as Dictionary, now as Number) as Void {
        if (day["za"] instanceof Number && day["zb"] instanceof Number) {
            Storage.setValue("z", { "r" => routeKey(), "a" => day["za"] as Number, "b" => day["zb"] as Number });
        }
        // Trains first: a day entry is only trusted (route, fetch time) once
        // its trains are written, should the system stop the background here.
        var key = "d:" + date;
        Storage.setValue(key + ":ab", day["ab"] as Array<Storage.ValueType>);
        Storage.setValue(key + ":ba", day["ba"] as Array<Storage.ValueType>);
        day.remove("ab");
        day.remove("ba");
        day["r"] = routeKey();
        day["t"] = now;
        Storage.setValue(key, day as Dictionary<Storage.KeyType, Storage.ValueType>);
        Storage.deleteValue("err");
    }

    function saveError(kind as Number, detail as String) as Void {
        Storage.setValue("err", { "k" => kind, "d" => detail, "r" => routeKey() });
    }

    //! The last error for the current stations, or null.
    function lastError() as Dictionary? {
        var err = Storage.getValue("err");
        if (err instanceof Dictionary && routeKey().equals(err["r"])) {
            return err as Dictionary;
        }
        return null;
    }

    //! First date in [today, today + DAYS_AHEAD) that is missing or stale, or null.
    //! now: epoch seconds (Time.now().value()).
    function nextDateToFetch(now as Number) as String? {
        if (!isConfigured()) {
            return null;
        }
        for (var i = 0; i < DAYS_AHEAD; i++) {
            var date = dateString(i);
            var day = load(date);
            if (day == null || now - (day["t"] as Number) > STALE_SECONDS) {
                return date;
            }
        }
        return null;
    }

    //! Drops the past week's days; older ones were pruned on earlier runs.
    function prune() as Void {
        for (var i = 1; i <= 7; i++) {
            var key = "d:" + dateString(-i);
            Storage.deleteValue(key);
            Storage.deleteValue(key + ":ab");
            Storage.deleteValue(key + ":ba");
        }
    }
}
