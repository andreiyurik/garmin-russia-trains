const assert = require("node:assert/strict");
const { test } = require("node:test");
const { compactDay, FLAG_EXPRESS, offsetOf, packTrain, terminalOf, toMinutes } = require("../src/compact.js");
const { searchAll, UpstreamError } = require("../src/yandex.js");

const seg = (dep, arr, durMin, express_type = null, extra = {}) => ({
  departure: `2026-10-07T${dep}:00+03:00`,
  arrival: `2026-10-07T${arr}:00+03:00`,
  duration: durMin * 60,
  has_transfers: false,
  thread: { express_type },
  ...extra,
});

test("toMinutes reads the station's wall clock", () => {
  assert.equal(toMinutes("2026-10-07T00:00:00+03:00"), 0);
  assert.equal(toMinutes("2026-10-07T08:42:00+03:00"), 522);
  assert.equal(toMinutes("2026-10-07T23:59:00+03:00"), 1439);
  assert.equal(toMinutes("2026-10-16T05:47:00+05:00"), 347, "Yekaterinburg time, not Moscow");
});

test("offsetOf reads the UTC offset in minutes", () => {
  assert.equal(offsetOf("2026-10-16T05:47:00+05:00"), 300);
  assert.equal(offsetOf("2026-10-16T05:47:00+02:00"), 120);
  assert.equal(offsetOf("2026-10-16T05:47:00+12:00"), 720);
  assert.equal(offsetOf("2026-10-16T05:47:00-03:30"), -210);
  assert.equal(offsetOf("2026-10-16T05:47:00Z"), 0);
  assert.equal(offsetOf("2026-10-16T05:47:00"), null);
  assert.equal(offsetOf(undefined), null);
});

test("compactDay reports both stations' offsets from any segment", () => {
  const ekb = (dep, arr, offA, offB) => ({
    departure: `2026-10-16T${dep}:00${offA}`,
    arrival: `2026-10-16T${arr}:00${offB}`,
    has_transfers: false,
    thread: { title: "Кузино — Екатеринбург-П" },
  });
  const both = compactDay([ekb("05:47", "06:49", "+05:00", "+05:00")], []);
  assert.equal(both.za, 300);
  assert.equal(both.zb, 300);
  assert.deepEqual(both.ab, [packTrain(347, 0, 1, 0)]);

  // Only the way back runs: its arrival is in A's zone, its departure in B's.
  const back = compactDay([], [ekb("18:00", "19:00", "+04:00", "+05:00")]);
  assert.equal(back.za, 300);
  assert.equal(back.zb, 240);

  const none = compactDay([], []);
  assert.ok(!("za" in none) && !("zb" in none), "no trains, no offsets");
});

test("terminalOf takes the last part of the thread title", () => {
  assert.equal(terminalOf({ title: "Москва (Курский вокзал) — Петушки" }), "Петушки");
  assert.equal(terminalOf({ short_title: "Одинцово — Лобня", title: "x" }), "Лобня");
  assert.equal(terminalOf({ title: "Кольцевой" }), "Кольцевой");
  assert.equal(terminalOf(undefined), "");
});

test("packTrain keeps every field in its own bits", () => {
  const x = packTrain(1439, 2, 255, 255);
  assert.equal(x & 0x7ff, 1439);
  assert.equal((x >> 11) & 3, 2);
  assert.equal((x >> 13) & 0xff, 255);
  assert.equal((x >> 21) & 0xff, 255);
  assert.ok(x < 2 ** 31, "fits a signed 32-bit Monkey C Number");
});

test("compactDay sorts, flags express, drops transfers, shares a string table", () => {
  const day = compactDay(
    [
      seg("09:03", "09:26", 23, null, { departure_platform: "2", thread: { title: "Одинцово — Лобня" } }),
      seg("08:51", "09:08", 17, "express", { departure_platform: "2", thread: { express_type: "express", title: "Одинцово — Беговая" } }),
      seg("08:00", "09:00", 60, null, { has_transfers: true }),
    ],
    [seg("18:10", "18:33", 23, null, { departure_platform: null, thread: { title: "Лобня — Одинцово" } })],
  );
  // Strings are numbered in input order; rows are then sorted by time.
  assert.deepEqual(day.s, ["", "Лобня", "2", "Беговая", "Одинцово"]);
  assert.deepEqual(day.ab, [packTrain(531, FLAG_EXPRESS, 3, 2), packTrain(543, 0, 1, 2)]);
  assert.deepEqual(day.ba, [packTrain(1090, 0, 4, 0)]);
});

test("searchAll follows pagination", async () => {
  const calls = [];
  const fakeFetch = async (url) => {
    const offset = Number(url.searchParams.get("offset"));
    calls.push(offset);
    const n = offset === 0 ? 100 : 30;
    return Response.json({
      pagination: { total: 130, limit: 100, offset },
      segments: Array.from({ length: n }, () => seg("10:00", "10:20", 20)),
    });
  };
  const all = await searchAll("k", "s1", "s2", "2026-10-07", fakeFetch);
  assert.equal(all.length, 130);
  assert.deepEqual(calls, [0, 100]);
});


test("searchAll asks for station-local times, not Moscow time", async () => {
  let asked;
  await searchAll("k", "s1", "s2", "2026-10-07", async (url) => {
    asked = url;
    return Response.json({ pagination: { total: 0 }, segments: [] });
  });
  assert.equal(asked.searchParams.get("result_timezone"), null);
});

test("searchAll treats a missing segments list as no trains", async () => {
  const all = await searchAll("k", "s1", "s2", "2026-10-07", async () => Response.json({}));
  assert.deepEqual(all, []);
});

test("UpstreamError never carries the API key", async () => {
  // Yandex echoes the whole request URL, key included, in its error body.
  const body = JSON.stringify({
    error: {
      text: "Не нашли объект по yandex коду s9623390",
      http_code: 404,
      request: "http://api.rasp.yandex-net.ru/v3.0/search/?apikey=SECRET-KEY-123&format=json&from=s1",
    },
  });
  const err = await searchAll("SECRET-KEY-123", "s1", "s9623390", "2026-10-07", async () => new Response(body, { status: 404 }))
    .then(() => null, (e) => e);
  assert.ok(err instanceof UpstreamError);
  assert.equal(err.status, 404);
  assert.equal(err.missingCode, "s9623390");
  assert.ok(!err.message.includes("SECRET-KEY-123"), err.message);
});

test("searchAll turns network failures and timeouts into UpstreamError", async () => {
  const err = await searchAll("k", "s1", "s2", "2026-10-07", async () => {
    throw new DOMException("timed out", "TimeoutError");
  }).then(() => null, (e) => e);
  assert.ok(err instanceof UpstreamError);
  assert.equal(err.status, 0);
});
