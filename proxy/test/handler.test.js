const assert = require("node:assert/strict");
const { test } = require("node:test");
const { handleRequest } = require("../src/index.js");
const { DB } = require("./fixtures.js");

const NOW = Date.parse("2026-10-07T09:00:00+03:00");
const HOUR = 3_600_000;

// Workers KV stand-in: get(key, "json") and put(key, string, options).
function fakeKv() {
  const store = new Map();
  return {
    store,
    puts: 0,
    async get(key, type) {
      const v = store.get(key);
      if (v === undefined) return null;
      return type === "json" ? JSON.parse(v) : v;
    },
    async put(key, value, options) {
      this.puts++;
      assert.equal(typeof value, "string");
      assert.ok(options?.expirationTtl >= 60, "every entry expires");
      store.set(key, value);
    },
  };
}

// Yandex stand-in: one train each way, Moscow time unless `offset` is given.
function fakeYandex({ offset = "+03:00", status = 200, body } = {}) {
  const yandex = async (url) => {
    yandex.calls++;
    if (status !== 200) return new Response(body ?? "{}", { status });
    const from = url.searchParams.get("from");
    const dep = from === "s112" || from === "s113" ? "08:42" : "18:10";
    return Response.json({
      pagination: { total: 1 },
      segments: [{
        departure: `2026-10-07T${dep}:00${offset}`,
        arrival: `2026-10-07T23:00:00${offset}`,
        has_transfers: false,
        thread: { title: "x — y" },
      }],
    });
  };
  yandex.calls = 0;
  return yandex;
}

const ctx = (extra) => ({ apiKey: "k", now: NOW, db: DB, memory: new Map(), kv: fakeKv(), ...extra });
const get = async (params, c) => {
  const res = await handleRequest({ date: "2026-10-07", ...params }, c);
  return { status: res.statusCode, body: JSON.parse(res.body) };
};

test("validates the date", async () => {
  const c = ctx({ fetchImpl: fakeYandex() });
  assert.equal((await get({ a: "Одинцово", b: "Беговая", date: "bad" }, c)).status, 400);
  assert.equal((await get({ a: "Одинцово", b: "Беговая", date: "2027-01-01" }, c)).status, 400);
  // Kamchatka is already on the 8th when it is the 7th in Moscow.
  assert.equal((await get({ a: "Одинцово", b: "Беговая", date: "2026-10-08" }, c)).status, 200);
});

test("answers v3 with the resolved titles, trains and offsets", async () => {
  const { status, body } = await get({ a: "Одинцово", b: "Беговая" }, ctx({ fetchImpl: fakeYandex() }));
  assert.equal(status, 200);
  assert.equal(body.v, 3);
  assert.equal(body.a, "Одинцово");
  assert.equal(body.b, "Беговая");
  assert.deepEqual(body.ab.map((t) => t & 0x7ff), [522]);
  assert.deepEqual(body.ba.map((t) => t & 0x7ff), [1090]);
  assert.equal(body.za, 180);
  assert.equal(body.zb, 180);
});

test("station-local times for Yekaterinburg", async () => {
  const c = ctx({ fetchImpl: fakeYandex({ offset: "+05:00" }) });
  const { body } = await get({ a: "Первоуральск", b: "Екатеринбург-Пасс." }, c);
  assert.deepEqual(body.ab.map((t) => t & 0x7ff), [522]);
  assert.equal(body.za, 300);
});

test("an empty day is a valid answer", async () => {
  const empty = async () => Response.json({ pagination: { total: 0 } });
  const { status, body } = await get({ a: "Одинцово", b: "Беговая" }, ctx({ fetchImpl: empty }));
  assert.equal(status, 200);
  assert.deepEqual([body.ab, body.ba, body.s], [[], [], [""]]);
});

test("station errors: not found and ambiguous (old watches read error/q)", async () => {
  const c = ctx({ fetchImpl: fakeYandex() });
  const missing = await get({ a: "Нет", b: "Беговая" }, c);
  assert.equal(missing.status, 404);
  assert.deepEqual(missing.body, { error: "station", which: "a", q: "Нет", reason: "notfound" });

  const amb = await get({ a: "Заводская", b: "Перово" }, c);
  assert.equal(amb.status, 404);
  assert.equal(amb.body.error, "station");
  assert.equal(amb.body.reason, "ambiguous");
  assert.equal(amb.body.q, "Перово");
  assert.deepEqual(amb.body.options, ["Перово, Москва", "Перово, Краснодарский край"]);
});

test("an unknown station code from Yandex becomes a station error", async () => {
  const body = JSON.stringify({ error: { text: "Не нашли объект по yandex коду s999", request: "?apikey=k" } });
  const { status, body: res } = await get({ a: "s101", b: "s999" }, ctx({ fetchImpl: fakeYandex({ status: 404, body }) }));
  assert.equal(status, 404);
  assert.deepEqual(res, { error: "station", which: "b", q: "s999", reason: "notfound" });
});

test("the shared KV cache serves other isolates and the opposite direction", async () => {
  const kv = fakeKv();
  const yandex = fakeYandex();
  const first = await get({ a: "Одинцово", b: "Беговая" }, ctx({ kv, fetchImpl: yandex }));
  assert.equal(yandex.calls, 2);
  assert.equal(kv.puts, 1);

  // A fresh isolate (empty memory), the same route typed differently.
  const again = await get({ a: "одинцово", b: "s101" }, ctx({ kv, fetchImpl: yandex }));
  assert.deepEqual(again.body, first.body);

  // The way back is the same entry with the directions swapped.
  const back = await get({ a: "Беговая", b: "Одинцово" }, ctx({ kv, fetchImpl: yandex }));
  assert.equal(yandex.calls, 2, "no new Yandex requests");
  assert.deepEqual([back.body.a, back.body.b], ["Беговая", "Одинцово"]);
  assert.deepEqual(back.body.ab, first.body.ba);
  assert.deepEqual(back.body.ba, first.body.ab);
  assert.equal(back.body.za, first.body.zb);
});

test("the memory cache avoids KV reads in a warm isolate", async () => {
  const c = ctx({ fetchImpl: fakeYandex() });
  await get({ a: "Одинцово", b: "Беговая" }, c);
  c.kv.get = async () => assert.fail("KV read on a warm isolate");
  await get({ a: "Одинцово", b: "Беговая" }, c);
});

test("entries older than 12 hours are refetched", async () => {
  const kv = fakeKv();
  const yandex = fakeYandex();
  await get({ a: "Одинцово", b: "Беговая" }, ctx({ kv, fetchImpl: yandex }));
  await get({ a: "Одинцово", b: "Беговая" }, ctx({ kv, fetchImpl: yandex, now: NOW + 11 * HOUR }));
  assert.equal(yandex.calls, 2);
  await get({ a: "Одинцово", b: "Беговая" }, ctx({ kv, fetchImpl: yandex, now: NOW + 13 * HOUR }));
  assert.equal(yandex.calls, 4);
});

test("when Yandex fails, a stale entry is served", async () => {
  const kv = fakeKv();
  const fresh = await get({ a: "Одинцово", b: "Беговая" }, ctx({ kv, fetchImpl: fakeYandex() }));
  const later = ctx({ kv, fetchImpl: fakeYandex({ status: 500 }), now: NOW + 20 * HOUR });
  const stale = await get({ a: "Одинцово", b: "Беговая" }, later);
  assert.equal(stale.status, 200);
  assert.deepEqual(stale.body, fresh.body);
});

test("without a stale entry an upstream failure is a 502", async () => {
  const { status, body } = await get({ a: "Одинцово", b: "Беговая" }, ctx({ fetchImpl: fakeYandex({ status: 500 }) }));
  assert.equal(status, 502);
  assert.deepEqual(body, { error: "upstream", status: 500 });
});

test("an exhausted Yandex limit stops upstream calls until Moscow midnight", async () => {
  const kv = fakeKv();
  const limited = fakeYandex({ status: 429 });
  const first = await get({ a: "Одинцово", b: "Беговая" }, ctx({ kv, fetchImpl: limited }));
  assert.equal(first.status, 503);
  assert.deepEqual(first.body, { error: "limit" });
  const callsAtLimit = limited.calls;

  // Another isolate learns about the limit from KV and does not ask Yandex.
  const other = await get({ a: "Первоуральск", b: "Екатеринбург-Пасс." }, ctx({ kv, fetchImpl: limited }));
  assert.equal(other.status, 503);
  assert.equal(limited.calls, callsAtLimit);

  // After 00:00 MSK (21:00 UTC) the next request tries again.
  const ok = fakeYandex();
  const next = await get({ a: "Одинцово", b: "Беговая", date: "2026-10-08" },
    ctx({ kv, fetchImpl: ok, now: Date.parse("2026-10-08T00:01:00+03:00") }));
  assert.equal(next.status, 200);
  assert.equal(ok.calls, 2);
});

test("a broken KV is only a cache miss", async () => {
  const kv = {
    get: async () => { throw new Error("KV down"); },
    put: async () => { throw new Error("KV write limit"); },
  };
  const { status } = await get({ a: "Одинцово", b: "Беговая" }, ctx({ kv, fetchImpl: fakeYandex() }));
  assert.equal(status, 200);
});

test("works without KV (local runs and tests)", async () => {
  const { status } = await get({ a: "Одинцово", b: "Беговая" }, ctx({ kv: undefined, fetchImpl: fakeYandex() }));
  assert.equal(status, 200);
});

test("simultaneous requests for one route share one upstream fetch", async () => {
  const yandex = fakeYandex();
  const c = ctx({ fetchImpl: yandex });
  await Promise.all([get({ a: "Одинцово", b: "Беговая" }, c), get({ a: "Беговая", b: "Одинцово" }, c)]);
  assert.equal(yandex.calls, 2);
});

test("?q= lists matching stations with what to type", async () => {
  const res = await handleRequest({ q: "Заводская" }, ctx({}));
  const { stations } = JSON.parse(res.body);
  assert.deepEqual(stations.map((s) => s.input), ["Заводская, Ижевск", "Заводская, Находка"]);
});
