// Request logic between the watch and Yandex Rasp, shared by the Cloudflare
// Worker entry point (worker.js).
//
//   GET <worker-url>?a=<station>&b=<station>&date=YYYY-MM-DD
//     -> {"v":3,"date":"…","a":"Одинцово","b":"Беговая",
//         "ab":[packedTrain,…],"ba":[…],"s":["","Беговая","2",…]}   (see compact.js)
//     404 {"error":"station","which":"a"|"b","q":"…"} when a name is not found
//   GET <worker-url>?q=<text>
//     -> {"stations":[{code,title,direction},…]}  (check what a name resolves to)
const { compactDay } = require("./compact.js");
const { resolveStation, searchStations } = require("./stations.js");
const { searchAll, UpstreamError } = require("./yandex.js");

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const MAX_DAYS_AHEAD = 30;
const TTL_MS = 6 * 60 * 60 * 1000;
const CACHE_MAX = 500;

// A Worker isolate is reused between requests, so a module-level Map is a
// best-effort warm cache (it may be dropped at any time; that only costs a refetch).
const cache = new Map();

async function handleRequest(params, { apiKey, fetchImpl = fetch, now = Date.now() }) {
  if (params.q !== undefined) {
    return json(200, { stations: searchStations(params.q) });
  }

  const date = params.date ?? "";
  if (!isAllowedDate(date, now)) return json(400, { error: "date" });
  const a = resolveStation(params.a);
  if (!a) return json(404, { error: "station", which: "a", q: params.a ?? "" });
  const b = resolveStation(params.b);
  if (!b) return json(404, { error: "station", which: "b", q: params.b ?? "" });

  // Keyed on resolved codes so "Одинцово" and "одинцово" share one entry.
  const key = `${a.code}/${b.code}/${date}`;
  const hit = cache.get(key);
  if (hit && now - hit.at < TTL_MS) return json(200, hit.body);

  let ab, ba;
  try {
    [ab, ba] = await Promise.all([
      searchAll(apiKey, a.code, b.code, date, fetchImpl),
      searchAll(apiKey, b.code, a.code, date, fetchImpl),
    ]);
  } catch (e) {
    if (e instanceof UpstreamError) {
      console.error(e.message);
      return json(502, { error: "upstream", status: e.status });
    }
    throw e;
  }

  const body = { v: 3, date, a: a.title, b: b.title, ...compactDay(ab, ba) };
  if (cache.size >= CACHE_MAX) cache.delete(cache.keys().next().value);
  cache.set(key, { at: now, body });
  return json(200, body);
}

function isAllowedDate(date, now) {
  if (!DATE_RE.test(date)) return false;
  const day = Date.parse(`${date}T00:00:00+03:00`);
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
