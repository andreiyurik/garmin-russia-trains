import Toybox.Application.Properties;
import Toybox.Application.Storage;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;
import Toybox.Test;
import Toybox.Time;
import Toybox.Time.Gregorian;

//! Schedule storage, response validation and Fetcher.handle (no network).

(:test)
function testDateOfPadsMonthAndDay(logger as Logger) as Boolean {
    var moment = Gregorian.moment({ :year => 2026, :month => 1, :day => 5, :hour => 12 });
    return check(logger, Schedule.dateOf(moment).equals("2026-01-05"), Schedule.dateOf(moment));
}

(:test)
function testIsValidAcceptsProxyResponse(logger as Logger) as Boolean {
    return check(logger, Schedule.isValid(sampleDay()), "sample day")
        && check(logger, Schedule.isValid(dayWithTrains([] as Array<Number>)), "no trains is still valid");
}

(:test)
function testIsValidRejectsBrokenResponses(logger as Logger) as Boolean {
    var wrongVersion = sampleDay();
    wrongVersion["v"] = 2;
    var noStrings = sampleDay();
    noStrings.remove("s");
    var badMinute = sampleDay();
    badMinute["ab"] = [packTrain(1440, 0, 0, 0)];
    var badIndex = sampleDay();
    badIndex["ba"] = [packTrain(1090, 0, 99, 0)];
    var negative = sampleDay();
    negative["ab"] = [-1];
    var notNumber = sampleDay();
    notNumber["ab"] = ["08:42"];
    var noTitle = sampleDay();
    noTitle.remove("a");
    return check(logger, !Schedule.isValid(wrongVersion), "old format")
        && check(logger, !Schedule.isValid(noStrings), "missing string table")
        && check(logger, !Schedule.isValid(badMinute), "departure past midnight")
        && check(logger, !Schedule.isValid(badIndex), "string index out of range")
        && check(logger, !Schedule.isValid(negative), "negative minute")
        && check(logger, !Schedule.isValid(notNumber), "string in train array")
        && check(logger, !Schedule.isValid(noTitle), "missing station title");
}

(:test)
function testSaveLoadIsTiedToRouteAndFormat(logger as Logger) as Boolean {
    resetState();
    var date = Schedule.dateString(0);
    Schedule.save(date, sampleDay(), NOW_SECONDS);
    var loaded = check(logger, Schedule.load(date) != null, "loads after save");

    Properties.setValue("WorkStation", "Лобня");
    var otherRoute = check(logger, Schedule.load(date) == null, "new stations ignore old cache");

    Properties.setValue("WorkStation", "Беговая");
    var old = sampleDay();
    old["v"] = 2;
    old["r"] = Schedule.routeKey();
    Storage.setValue("d:" + date, old as Dictionary<Storage.KeyType, Storage.ValueType>);
    var oldFormat = check(logger, Schedule.load(date) == null, "old format ignored");
    return loaded && otherRoute && oldFormat;
}

(:test)
function testNextDateToFetch(logger as Logger) as Boolean {
    resetState();
    var today = Schedule.dateString(0);
    var ok = check(logger, today.equals(Schedule.nextDateToFetch(NOW_SECONDS)), "empty cache: today");

    for (var i = 0; i < Schedule.DAYS_AHEAD; i++) {
        Schedule.save(Schedule.dateString(i), sampleDay(), NOW_SECONDS);
    }
    ok = check(logger, Schedule.nextDateToFetch(NOW_SECONDS) == null, "all fresh: nothing") && ok;
    ok = check(logger, Schedule.nextDateToFetch(NOW_SECONDS + Schedule.STALE_SECONDS) == null,
        "exactly 12 h old is still fresh") && ok;
    ok = check(logger, today.equals(Schedule.nextDateToFetch(NOW_SECONDS + Schedule.STALE_SECONDS + 1)),
        "older than 12 h: refetch today") && ok;

    Storage.deleteValue("d:" + Schedule.dateString(2));
    ok = check(logger, Schedule.dateString(2).equals(Schedule.nextDateToFetch(NOW_SECONDS)),
        "missing day after tomorrow") && ok;

    Properties.setValue("HomeStation", "");
    ok = check(logger, Schedule.nextDateToFetch(NOW_SECONDS) == null, "not configured: nothing") && ok;
    return ok;
}

(:test)
function testPruneDropsPastDays(logger as Logger) as Boolean {
    resetState();
    Schedule.save(Schedule.dateString(-1), sampleDay(), NOW_SECONDS);
    Schedule.save(Schedule.dateString(0), sampleDay(), NOW_SECONDS);
    Schedule.prune();
    return check(logger, Storage.getValue("d:" + Schedule.dateString(-1)) == null, "yesterday deleted")
        && check(logger, Schedule.load(Schedule.dateString(0)) != null, "today kept");
}

(:test)
function testErrorLifecycle(logger as Logger) as Boolean {
    resetState();
    Schedule.saveError(Schedule.ERROR_PHONE, "-104");
    var saved = Schedule.lastError();
    var ok = check(logger, saved != null && (saved["k"] as Number) == Schedule.ERROR_PHONE, "error stored");

    Properties.setValue("HomeStation", "Лобня");
    ok = check(logger, Schedule.lastError() == null, "error belongs to the old stations") && ok;

    Properties.setValue("HomeStation", "Одинцово");
    Schedule.save(Schedule.dateString(0), sampleDay(), NOW_SECONDS);
    ok = check(logger, Schedule.lastError() == null, "a successful save clears it") && ok;
    return ok;
}

(:test)
function testHandleStoresValidResponse(logger as Logger) as Boolean {
    resetState();
    var date = Schedule.dateString(0);
    var code = Fetcher.handle(date, 200, sampleDay(), NOW_SECONDS);
    var day = Schedule.load(date);
    return check(logger, code == 200, "returns 200")
        && check(logger, day != null && ((day as Dictionary)["t"] as Number) == NOW_SECONDS, "saved with fetch time")
        && check(logger, Schedule.lastError() == null, "no error");
}

(:test)
function testHandleClassifiesErrors(logger as Logger) as Boolean {
    resetState();
    var date = Schedule.dateString(0);
    var ok = true;

    var code = Fetcher.handle(date, 200, { "v" => 9 }, NOW_SECONDS);
    ok = check(logger, code == Communications.INVALID_HTTP_BODY_IN_NETWORK_RESPONSE, "bad body code") && ok;
    ok = check(logger, Schedule.load(date) == null, "bad body not saved") && ok;
    ok = expectError(logger, Schedule.ERROR_SERVER, "bad body") && ok;

    Fetcher.handle(date, 404, { "error" => "station", "which" => "a", "q" => "Одинцвоо" }, NOW_SECONDS);
    ok = expectError(logger, Schedule.ERROR_STATION, "station") && ok;
    ok = check(logger, "Одинцвоо".equals((Schedule.lastError() as Dictionary)["d"] as Object?), "names the station") && ok;

    Fetcher.handle(date, Communications.BLE_CONNECTION_UNAVAILABLE, null, NOW_SECONDS);
    ok = expectError(logger, Schedule.ERROR_PHONE, "no phone") && ok;

    Fetcher.handle(date, 502, { "error" => "upstream" }, NOW_SECONDS);
    ok = expectError(logger, Schedule.ERROR_SERVER, "502") && ok;

    Fetcher.handle(date, Communications.NETWORK_RESPONSE_TOO_LARGE, null, NOW_SECONDS);
    ok = expectError(logger, Schedule.ERROR_SERVER, "too large is not a connection problem") && ok;
    return ok;
}

(:test)
function testHandleKeepsOldScheduleOnError(logger as Logger) as Boolean {
    resetState();
    var date = Schedule.dateString(0);
    Fetcher.handle(date, 200, sampleDay(), NOW_SECONDS);
    Fetcher.handle(date, Communications.NETWORK_REQUEST_TIMED_OUT, null, NOW_SECONDS + 3600);
    var day = Schedule.load(date);
    return check(logger, day != null && ((day as Dictionary)["t"] as Number) == NOW_SECONDS, "old schedule still there")
        && expectError(logger, Schedule.ERROR_PHONE, "timeout");
}

(:test)
function testIsConnectionError(logger as Logger) as Boolean {
    var connection = [
        Communications.BLE_ERROR, Communications.BLE_HOST_TIMEOUT, Communications.BLE_SERVER_TIMEOUT,
        Communications.BLE_NO_DATA, Communications.BLE_REQUEST_CANCELLED, Communications.BLE_QUEUE_FULL,
        Communications.BLE_REQUEST_TOO_LARGE, Communications.BLE_UNKNOWN_SEND_ERROR,
        Communications.BLE_CONNECTION_UNAVAILABLE, Communications.NETWORK_REQUEST_TIMED_OUT,
        Communications.REQUEST_CONNECTION_DROPPED
    ] as Array<Number>;
    var other = [
        200, 404, 500, Communications.UNKNOWN_ERROR, Communications.INVALID_HTTP_BODY_IN_NETWORK_RESPONSE,
        Communications.NETWORK_RESPONSE_TOO_LARGE, Communications.NETWORK_RESPONSE_OUT_OF_MEMORY,
        Communications.SECURE_CONNECTION_REQUIRED
    ] as Array<Number>;
    var ok = true;
    for (var i = 0; i < connection.size(); i++) {
        ok = check(logger, Fetcher.isConnectionError(connection[i]), "connection: " + connection[i]) && ok;
    }
    for (var i = 0; i < other.size(); i++) {
        ok = check(logger, !Fetcher.isConnectionError(other[i]), "not connection: " + other[i]) && ok;
    }
    return ok;
}

function expectError(logger as Logger, kind as Number, what as String) as Boolean {
    var err = Schedule.lastError();
    return check(logger, err != null && (err["k"] as Number) == kind, what + ": error kind " + kind);
}

(:test)
function testIsValidChecksStationZones(logger as Logger) as Boolean {
    var zoned = sampleDay();
    zoned["za"] = 300;
    zoned["zb"] = -210;
    var text = sampleDay();
    text["za"] = "+05:00";
    var far = sampleDay();
    far["zb"] = 24 * 60;
    return check(logger, Schedule.isValid(zoned), "offsets in minutes")
        && check(logger, !Schedule.isValid(text), "offset must be a number")
        && check(logger, !Schedule.isValid(far), "offset out of range");
}

(:test)
function testSaveRemembersStationZonesPerRoute(logger as Logger) as Boolean {
    resetState();
    var device = System.getClockTime().timeZoneOffset;
    var ok = check(logger, Schedule.utcOffset(true) == device, "nothing known: device zone");

    var day = sampleDay();
    day["za"] = 300;
    day["zb"] = 420;
    Schedule.save(Schedule.dateString(0), day, NOW_SECONDS);
    ok = check(logger, Schedule.utcOffset(true) == 300 * 60, "toward work: zone of A") && ok;
    ok = check(logger, Schedule.utcOffset(false) == 420 * 60, "back home: zone of B") && ok;

    // A day from an older proxy has no zones: the known ones stay.
    Schedule.save(Schedule.dateString(1), sampleDay(), NOW_SECONDS);
    ok = check(logger, Schedule.utcOffset(true) == 300 * 60, "kept after a day without zones") && ok;

    Properties.setValue("WorkStation", "Лобня");
    ok = check(logger, Schedule.utcOffset(true) == device, "other stations: device zone again") && ok;
    return ok;
}

(:test)
function testDateAtUsesTheStationZone(logger as Logger) as Boolean {
    // 2026-10-15 20:30 UTC: already the 16th in Yekaterinburg (+5), still the 15th in Kaliningrad (+2).
    var epoch = Gregorian.moment({ :year => 2026, :month => 10, :day => 15, :hour => 20, :minute => 30 }).value();
    return check(logger, Schedule.dateAt(epoch, 5 * 3600, 0).equals("2026-10-16"), "Yekaterinburg")
        && check(logger, Schedule.dateAt(epoch, 2 * 3600, 0).equals("2026-10-15"), "Kaliningrad")
        && check(logger, Schedule.dateAt(epoch, 5 * 3600, 1).equals("2026-10-17"), "tomorrow")
        && check(logger, Schedule.dateAt(epoch, 12 * 3600, -1).equals("2026-10-15"), "yesterday in Kamchatka");
}

(:test)
function testHandleExplainsAmbiguousStationsAndLimits(logger as Logger) as Boolean {
    resetState();
    var date = Schedule.dateString(0);
    Fetcher.handle(date, 404, {
        "error" => "station", "which" => "b", "q" => "Перово", "reason" => "ambiguous",
        "options" => ["Перово, Москва", "Перово, Краснодарский край"]
    }, NOW_SECONDS);
    var ok = expectError(logger, Schedule.ERROR_AMBIGUOUS, "ambiguous");
    ok = check(logger, "Перово, Москва?".equals((Schedule.lastError() as Dictionary)["d"] as Object?),
        "suggests what to type") && ok;

    Fetcher.handle(date, 404, { "error" => "station", "q" => "Перово", "reason" => "ambiguous", "options" => [] },
        NOW_SECONDS);
    ok = check(logger, "Перово".equals((Schedule.lastError() as Dictionary)["d"] as Object?), "no options: the name") && ok;

    Fetcher.handle(date, 503, { "error" => "limit" }, NOW_SECONDS);
    ok = expectError(logger, Schedule.ERROR_LIMIT, "limit") && ok;

    Fetcher.handle(date, 404, { "error" => "station", "q" => "Нет", "reason" => "notfound" }, NOW_SECONDS);
    ok = expectError(logger, Schedule.ERROR_STATION, "not found") && ok;
    return ok;
}

(:test)
function testDenseDayFitsStorageAndGlanceMemory(logger as Logger) as Boolean {
    resetState();
    // The busiest real route (Мытищи - Ярославский вокзал, live, Oct 2026) has
    // 264 + 272 trains and 21 strings; this is ~20% more trains and twice the strings.
    var trains = [] as Array<Number>;
    for (var i = 0; i < 330; i++) {
        trains.add(packTrain(i * 1439 / 330, i % 3, i % 32 + 1, i % 15 + 33));
    }
    var strings = [""] as Array<String>;
    for (var i = 1; i < 48; i++) {
        strings.add(i <= 32 ? "Сергиев Посад " + i : (i - 32).toString());
    }
    var day = { "v" => 3, "a" => "Одинцово", "b" => "Беговая", "ab" => trains, "ba" => trains,
                "s" => strings, "za" => 180, "zb" => 180 } as Dictionary;
    var ok = check(logger, Schedule.isValid(day), "valid");
    Schedule.save(Schedule.dateString(0), day, NOW_SECONDS);
    day = null;
    trains = null;
    strings = null;

    // What the glance holds: one day entry and one direction.
    var date = Schedule.dateString(0);
    var before = System.getSystemStats().usedMemory;
    var loaded = Schedule.load(date);
    var oneWay = loaded != null ? Schedule.trains(date, loaded, true) : null;
    var used = System.getSystemStats().usedMemory - before;
    logger.debug("dense day, one direction in memory: " + used + " bytes");
    ok = check(logger, oneWay != null && oneWay.size() == 330, "saved and loaded") && ok;
    // The glance has ~28 KB for code and data together, the code takes ~16 KB.
    ok = check(logger, used < 6 * 1024, "under 6 KB: " + used) && ok;
    loaded = null;
    oneWay = null;
    var next = Departures.upcoming(true, 6, 600);
    ok = check(logger, next != null && next.size() == 6, "upcoming works") && ok;
    return ok;
}

(:test)
function testDaysAreStoredPerDirection(logger as Logger) as Boolean {
    resetState();
    var date = Schedule.dateString(0);
    Schedule.save(date, sampleDay(), NOW_SECONDS);
    var day = Schedule.load(date) as Dictionary;
    var ok = check(logger, !day.hasKey("ab") && !day.hasKey("ba"), "day entry without trains");
    ok = check(logger, Schedule.trains(date, day, true).size() == 2, "trains to work") && ok;
    ok = check(logger, (Schedule.trains(date, day, false)[0] as Number) == packTrain(1090, 0, 2, 0), "trains back") && ok;

    Schedule.prune();
    Schedule.save(Schedule.dateString(-1), sampleDay(), NOW_SECONDS);
    Schedule.prune();
    ok = check(logger, Storage.getValue("d:" + Schedule.dateString(-1) + ":ab") == null, "prune drops the trains too") && ok;
    return ok;
}

(:test)
function testDaysSavedBeforeTheSplitAreRead(logger as Logger) as Boolean {
    resetState();
    var date = Schedule.dateString(0);
    var old = sampleDay();
    old["r"] = Schedule.routeKey();
    old["t"] = NOW_SECONDS;
    Storage.setValue("d:" + date, old as Dictionary<Storage.KeyType, Storage.ValueType>);
    var trains = Departures.upcoming(true, 5, 0);
    return check(logger, trains != null && trains.size() == 2, "old single-entry day still shows trains");
}
