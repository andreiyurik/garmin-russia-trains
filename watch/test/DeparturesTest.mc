import Toybox.Application.Properties;
import Toybox.Lang;
import Toybox.Test;
import Toybox.Time;
import Toybox.Time.Gregorian;

//! Departures: train selection, direction, "leave in" and formatting.

(:test)
function testHhmm(logger as Logger) as Boolean {
    return check(logger, Departures.hhmm(522).equals("08:42"), "08:42")
        && check(logger, Departures.hhmm(0).equals("00:00"), "midnight")
        && check(logger, Departures.hhmm(24 * 60 + 5).equals("00:05"), "tomorrow wraps");
}

(:test)
function testUnpackReadsEveryField(logger as Logger) as Boolean {
    var train = packTrain(1439, Schedule.FLAG_EXPRESS, 255, 7);
    return check(logger, Schedule.departureOf(train) == 1439, "departure")
        && check(logger, Schedule.flagsOf(train) == Schedule.FLAG_EXPRESS, "flags")
        && check(logger, Schedule.terminalOf(train) == 255, "terminal")
        && check(logger, Schedule.platformOf(train) == 7, "platform");
}

(:test)
function testDurationUsesHoursForLongWaits(logger as Logger) as Boolean {
    return check(logger, Departures.duration(7, "ч", "мин").equals("7 мин"), "under an hour")
        && check(logger, Departures.duration(0, "ч", "мин").equals("0 мин"), "now")
        && check(logger, Departures.duration(60, "ч", "мин").equals("1 ч"), "whole hour")
        && check(logger, Departures.duration(208, "ч", "мин").equals("3 ч 28 мин"), "hours and minutes");
}

(:test)
function testTowardWorkSwitchesAtSwitchHour(logger as Logger) as Boolean {
    resetState();
    return check(logger, Departures.towardWork(false, 12 * 60 + 59), "12:59 is morning")
        && check(logger, !Departures.towardWork(false, 13 * 60), "13:00 is evening")
        && check(logger, !Departures.towardWork(true, 8 * 60), "START flips morning")
        && check(logger, Departures.towardWork(true, 20 * 60), "START flips evening");
}

(:test)
function testLeaveInAndFirstCatchable(logger as Logger) as Boolean {
    var trains = [[595, 0, "", ""], [605, 0, "", ""], [620, 0, "", ""]] as Array<Array>;
    return check(logger, Departures.leaveIn(600, 590, 5) == 5, "600 - 5 walk - 590")
        && check(logger, Departures.leaveIn(595, 590, 10) == -5, "missed is negative")
        && check(logger, Departures.firstCatchable(trains, 590, 10) == 1, "skips the missed 09:55")
        && check(logger, Departures.firstCatchable(trains, 590, 0) == 0, "no walk: first train")
        && check(logger, Departures.firstCatchable(trains, 615, 10) == -1, "nothing catchable");
}

(:test)
function testCollectResolvesStringsFromMinute(logger as Logger) as Boolean {
    resetState();
    var out = [] as Array<Array>;
    Departures.collect(sampleDay(), sampleDay()["ab"] as Array<Number>, 525, 0, 5, out);
    if (!check(logger, out.size() == 1, "one train after 08:45")) {
        return false;
    }
    var t = out[0];
    return check(logger, (t[Departures.DEP] as Number) == 531, "departure")
        && check(logger, (t[Departures.FLAGS] as Number) == Schedule.FLAG_EXPRESS, "express flag")
        && check(logger, "Беговая".equals(t[Departures.TERMINAL] as String), "terminal")
        && check(logger, "2".equals(t[Departures.PLATFORM] as String), "platform");
}

(:test)
function testCollectBackDirectionShiftAndCount(logger as Logger) as Boolean {
    resetState();
    var out = [] as Array<Array>;
    Departures.collect(sampleDay(), sampleDay()["ba"] as Array<Number>, 0, 24 * 60, 1, out);
    return check(logger, out.size() == 1, "count limits the result")
        && check(logger, (out[0][Departures.DEP] as Number) == 1090 + 24 * 60, "shifted by a day")
        && check(logger, "".equals(out[0][Departures.PLATFORM] as String), "missing platform is empty");
}

(:test)
function testCollectHidesExpress(logger as Logger) as Boolean {
    resetState();
    Properties.setValue("HideExpress", true);
    var out = [] as Array<Array>;
    Departures.collect(sampleDay(), sampleDay()["ab"] as Array<Number>, 0, 0, 5, out);
    return check(logger, out.size() == 1 && (out[0][Departures.DEP] as Number) == 522, "express skipped");
}

(:test)
function testUpcomingContinuesIntoTomorrow(logger as Logger) as Boolean {
    resetState();
    Schedule.save(Schedule.dateString(0), dayWithTrains([600, 1430]), NOW_SECONDS);
    Schedule.save(Schedule.dateString(1), dayWithTrains([330, 360, 390]), NOW_SECONDS);
    var trains = Departures.upcoming(true, 3, 23 * 60 + 50);
    if (!check(logger, trains != null && trains.size() == 3, "three trains")) {
        return false;
    }
    var t = trains as Array<Array>;
    return check(logger, (t[0][Departures.DEP] as Number) == 1430, "last train today")
        && check(logger, (t[1][Departures.DEP] as Number) == 330 + 24 * 60, "first tomorrow")
        && check(logger, (t[2][Departures.DEP] as Number) == 360 + 24 * 60, "second tomorrow");
}

(:test)
function testUpcomingWithoutTodayIsNull(logger as Logger) as Boolean {
    resetState();
    Schedule.save(Schedule.dateString(1), dayWithTrains([330]), NOW_SECONDS);
    return check(logger, Departures.upcoming(true, 3, 600) == null, "no schedule for today");
}

(:test)
function testUpcomingAfterLastTrainWithoutTomorrowIsEmpty(logger as Logger) as Boolean {
    resetState();
    Schedule.save(Schedule.dateString(0), dayWithTrains([600]), NOW_SECONDS);
    var trains = Departures.upcoming(true, 3, 23 * 60);
    return check(logger, trains != null && trains.size() == 0, "empty, not null");
}

(:test)
function testMinutesAtUsesTheStationZone(logger as Logger) as Boolean {
    // 00:47 UTC is 05:47 in Yekaterinburg and 03:47 in Moscow.
    var epoch = Gregorian.moment({ :year => 2026, :month => 10, :day => 16, :hour => 0, :minute => 47 }).value();
    return check(logger, Departures.minutesAt(epoch, 5 * 3600) == 5 * 60 + 47, "Yekaterinburg")
        && check(logger, Departures.minutesAt(epoch, 3 * 3600) == 3 * 60 + 47, "Moscow")
        && check(logger, Departures.minutesAt(epoch + 59, 3 * 3600) == 3 * 60 + 47, "seconds are dropped")
        && check(logger, Departures.minutesAt(epoch, -2 * 3600) == 22 * 60 + 47, "west of UTC: day before");
}

(:test)
function testDatesFollowTheStationZone(logger as Logger) as Boolean {
    resetState();
    var day = dayWithTrains([600]);
    day["za"] = 12 * 60;   // Kamchatka
    day["zb"] = 2 * 60;    // Kaliningrad: not a real trip, but far apart in time
    Schedule.save(Schedule.dateString(0), day, NOW_SECONDS);
    var now = Time.now().value();
    var ok = check(logger, Schedule.dateString(0).equals(Schedule.dateAt(now, 12 * 3600, 0)), "storage days: zone of A");
    ok = check(logger, Schedule.dateFor(1, false).equals(Schedule.dateAt(now, 2 * 3600, 1)), "way back: zone of B") && ok;

    Schedule.save(Schedule.dateString(0), day, NOW_SECONDS);
    ok = check(logger, Departures.upcoming(true, 3, 0) != null, "today found in the station's zone") && ok;
    return ok;
}

(:test)
function testZoneLabel(logger as Logger) as Boolean {
    return check(logger, Departures.zoneLabel(5 * 3600).equals("UTC+5"), "+5")
        && check(logger, Departures.zoneLabel(-(3 * 3600 + 1800)).equals("UTC-3:30"), "-3:30")
        && check(logger, Departures.zoneLabel(0).equals("UTC"), "UTC");
}

(:test)
function testCollectSurvivesMismatchedStrings(logger as Logger) as Boolean {
    resetState();
    var out = [] as Array<Array>;
    Departures.collect(sampleDay(), [packTrain(600, 0, 200, 99)] as Array<Number>, 0, 0, 5, out);
    return check(logger, out.size() == 1 && "".equals(out[0][Departures.TERMINAL] as String)
        && "".equals(out[0][Departures.PLATFORM] as String), "unknown indexes read as empty");
}

(:test)
function testShorterTitles(logger as Logger) as Boolean {
    var a = Departures.shorterTitles("Москва (Ярославский вокзал)");
    var b = Departures.shorterTitles("Одинцово");
    var c = Departures.shorterTitles("Санкт-Петербург (Финляндский вокзал)");
    return check(logger, a.size() == 3, "three forms of a terminal name")
        && check(logger, "Москва (Ярославский вокзал)".equals(a[0]), "full first")
        && check(logger, "Ярославский вокзал".equals(a[1]), "the station inside the city")
        && check(logger, "Ярославский вкз.".equals(a[2]), "abbreviated")
        && check(logger, b.size() == 1 && "Одинцово".equals(b[0]), "short names stay")
        && check(logger, "Финляндский вкз.".equals(c[2]), "Petersburg too");
}

(:test)
function testForScreenSkipsMissedTrains(logger as Logger) as Boolean {
    var trains = [[595, 0, "", ""], [600, 0, "", ""], [605, 0, "", ""], [620, 0, "", ""], [630, 0, "", ""]] as Array<Array>;
    var shown = Departures.forScreen(trains, 590, 12, 3);
    var none = Departures.forScreen(trains, 625, 10, 3);
    return check(logger, shown.size() == 3, "hero and two more")
        && check(logger, (shown[0][Departures.DEP] as Number) == 605, "first catchable leads")
        && check(logger, (shown[2][Departures.DEP] as Number) == 630, "then the next ones")
        && check(logger, none.size() == 0, "nothing catchable: empty");
}

(:test)
function testUrgency(logger as Logger) as Boolean {
    return check(logger, Departures.urgency(15) == Departures.CALM, "plenty of time")
        && check(logger, Departures.urgency(2) == Departures.HURRY, "two minutes: hurry")
        && check(logger, Departures.urgency(0) == Departures.NOW, "now");
}

(:test)
function testPlatformLabel(logger as Logger) as Boolean {
    return check(logger, Departures.platformLabel("2", "пл.").equals("пл. 2"), "bare number gets the label")
        && check(logger, Departures.platformLabel("2 путь", "пл.").equals("2 путь"), "Yandex wording stays")
        && check(logger, Departures.platformLabel("обычно 4 пл 3 путь", "пл.").equals("4 пл 3 путь"), "no 'обычно'")
        && check(logger, Departures.platformLabel("", "пл.").equals(""), "none");
}
