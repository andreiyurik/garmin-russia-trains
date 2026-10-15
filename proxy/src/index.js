// Request logic between the watch and Yandex Rasp, shared by the Cloudflare
// Worker entry point (worker.js).
//
//   GET <worker-url>?a=<station>&b=<station>&date=YYYY-MM-DD
//     -> {"v":3,"date":"…","a":"Одинцово","b":"Беговая",
//         "ab":[packedTrain,…],"ba":[…],"s":["","Беговая","2",…],
//         "za":180,"zb":180}                       (see compact.js)
//     404 {"error":"station","which":"a"|"b","q":"…","reason":"notfound"}
//     404 {"error":"station",…,"reason":"ambiguous","options":["Заводская, Ижевск",…]}
//     503 {"error":"limit"}    the Yandex daily limit is used up and nothing is cached
//     502 {"error":"upstream","status":…}
//   GET <worker-url>?q=<text>
//     -> {"stations":[{code,title,direction,region,settlement,input},…]}
//
// Watches ask every hour, Yandex allows a limited number of requests per key a
// day, so days are cached for everyone: in the isolate's memory and in Workers
// KV (the Cache API does not work on *.workers.dev). A route is one entry for
// both directions. Old entries are kept as a fallback for when Yandex fails.
const { compactDay } = require("./compact.js");
const { resolvePair, searchStations } = require("./stations.js");
const { searchAll, UpstreamError } = require("./yandex.js");

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const MAX_DAYS_AHEAD = 30;
const FRESH_MS = 12 * 60 * 60 * 1000;
const KEEP_SECONDS = 3 * 24 * 60 * 60; // stale fallback; the date is over by then
const MEMORY_MAX = 500;
const MSK_MS = 3 * 60 * 60 * 1000;
const LIMIT_KEY = "limit";

// A Worker isolate is reused between requests, so a module-level Map is a
// best-effort warm cache (it may be dropped at any time; that only costs a refetch).
const MEMORY = new Map();
const inflight = new WeakMap(); // memory -> Map(key -> Promise), one fetch per route at a time

async function handleRequest(params, { apiKey, fetchImpl = fetch, now = Date.now(), kv, memory = MEMORY, db } = {}) {
  if (params.q !== undefined) {
    return json(200, { stations: searchStations(params.q, db) });
  }

  const date = params.date ?? "";
  if (!isAllowedDate(date, now)) return json(400, { error: "date" });
  const resolved = resolvePair(params.a, params.b, db);
  if (resolved.error) return json(404, { error: "station", ...resolved.error });
  const { a, b } = resolved;

  // Keyed on resolved codes in a fixed order, so "Одинцово"/"одинцово" and the
  // way back share one entry.
  const swap = a.code > b.code;
  const [lo, hi] = swap ? [b, a] : [a, b];
  const key = `day/${lo.code}/${hi.code}/${date}`;
  const entry = await cached(key, memory, kv, now);
  if (entry && now - entry.at < FRESH_MS) return json(200, orient(entry.body, swap));

  try {
    const fresh = await once(memory, key, () => fetchDay(lo, hi, date, key, { apiKey, fetchImpl, now, kv, memory }));
    return json(200, orient(fresh.body, swap));
  } catch (e) {
    if (!(e instanceof UpstreamError)) throw e;
    console.error(e.message);
    if (e.missingCode === a.code || e.missingCode === b.code) {
      const which = e.missingCode === a.code ? "a" : "b";
      return json(404, { error: "station", which, q: String(params[which]), reason: "notfound" });
    }
    if (entry) return json(200, orient(entry.body, swap));
    if (e.limited) return json(503, { error: "limit" });
    return json(502, { error: "upstream", status: e.status });
  }
}

async function fetchDay(lo, hi, date, key, { apiKey, fetchImpl, now, kv, memory }) {
  const until = Math.max(memory.get(LIMIT_KEY) ?? 0, Number(await kvGet(kv, LIMIT_KEY, "text")) || 0);
  if (now < until) {
    memory.set(LIMIT_KEY, until);
    throw Object.assign(new UpstreamError(429, "daily limit, waiting for Moscow midnight"), { limited: true });
  }
  let ab, ba;
  try {
    [ab, ba] = await Promise.all([
      searchAll(apiKey, lo.code, hi.code, date, fetchImpl),
      searchAll(apiKey, hi.code, lo.code, date, fetchImpl),
    ]);
  } catch (e) {
    if (e instanceof UpstreamError && isLimit(e)) {
      e.limited = true;
      // Assumed to reset at 00:00 MSK like other Yandex quotas; one try a day after that.
      const reset = nextMoscowMidnight(now);
      memory.set(LIMIT_KEY, reset);
      await kvPut(kv, LIMIT_KEY, String(reset), Math.max(60, Math.ceil((reset - now) / 1000)));
    }
    throw e;
  }
  const entry = { at: now, body: { v: 3, date, a: lo.title, b: hi.title, ...compactDay(ab, ba) } };
  remember(memory, key, entry);
  await kvPut(kv, key, JSON.stringify(entry), KEEP_SECONDS);
  return entry;
}

// The newer of the memory and KV entries; KV only when memory is not fresh.
async function cached(key, memory, kv, now) {
  const mem = memory.get(key);
  if (mem && now - mem.at < FRESH_MS) return mem;
  const stored = await kvGet(kv, key, "json");
  if (stored && (!mem || stored.at > mem.at)) {
    remember(memory, key, stored);
    return stored;
  }
  return mem ?? null;
}

function remember(memory, key, entry) {
  if (!memory.has(key) && memory.size >= MEMORY_MAX) memory.delete(memory.keys().next().value);
  memory.set(key, entry);
}

function once(memory, key, fetchFn) {
  if (!inflight.has(memory)) inflight.set(memory, new Map());
  const running = inflight.get(memory);
  if (!running.has(key)) running.set(key, fetchFn().finally(() => running.delete(key)));
  return running.get(key);
}

// Entries are stored lo -> hi; the way back swaps the directions.
function orient(body, swap) {
  if (!swap) return body;
  const { a, b, ab, ba, za, zb, ...rest } = body;
  return {
    ...rest,
    a: b,
    b: a,
    ab: ba,
    ba: ab,
    ...(zb !== undefined && { za: zb }),
    ...(za !== undefined && { zb: za }),
  };
}

// KV is a cache: when it is down or over its free write limit, carry on without it.
async function kvGet(kv, key, type) {
  if (!kv) return null;
  try {
    return await kv.get(key, type);
  } catch (e) {
    console.error(`KV get: ${e.message}`);
    return null;
  }
}

async function kvPut(kv, key, value, ttlSeconds) {
  if (!kv) return;
  try {
    await kv.put(key, value, { expirationTtl: ttlSeconds });
  } catch (e) {
    console.error(`KV put: ${e.message}`);
  }
}

function isLimit(e) {
  return e.status === 429 || (e.status === 403 && /limit|лимит|превыш/i.test(e.message));
}

function nextMoscowMidnight(now) {
  const day = 86_400_000;
  return (Math.floor((now + MSK_MS) / day) + 1) * day - MSK_MS;
}

// Dates are station-local, from Kaliningrad (UTC+2) to Kamchatka (UTC+12).
function isAllowedDate(date, now) {
  if (!DATE_RE.test(date)) return false;
  const day = Date.parse(`${date}T00:00:00Z`);
  if (Number.isNaN(day)) return false;
  const diffDays = (day - now) / 86_400_000;
  return diffDays > -2 && diffDays < MAX_DAYS_AHEAD;
}

function json(statusCode, body) {
  return {
    statusCode,
    headers: { "Content-Type": "application/json; charset=utf-8" },
    body: JSON.stringify(body),
  };
}

module.exports.handleRequest = handleRequest;
