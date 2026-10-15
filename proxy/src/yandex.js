// Yandex Rasp API v3.0 client.
// Docs: https://yandex.ru/dev/rasp/doc/ru/reference/schedule-point-point
const BASE = "https://api.rasp.yandex-net.ru/v3.0";
const PAGE = 100; // documented maximum for `limit`
// The watch gives up on a background request after ~30 s; a stuck page must
// fail early enough for a stale cache entry to be served instead.
const TIMEOUT_MS = 8000;

// status 0 = no usable answer (network error, timeout, broken JSON). The message is safe to log:
// Yandex error bodies echo the request URL with the API key.
class UpstreamError extends Error {
  constructor(status, body) {
    const text = redact(body);
    super(`Yandex API ${status}: ${text.slice(0, 300)}`);
    this.status = status;
    // "Не нашли объект по yandex коду s9623390": a station code Yandex lacks.
    this.missingCode = /yandex коду (s\d+)/.exec(text)?.[1] ?? null;
  }
}

function redact(text) {
  return String(text).replace(/apikey=[^&"\s]*/gi, "apikey=***");
}

// All suburban segments between two stations on a date, following pagination.
// Times come in each station's own zone (no result_timezone).
async function searchAll(apiKey, from, to, date, fetchImpl = fetch) {
  const segments = [];
  for (let offset = 0; ; offset += PAGE) {
    const url = new URL(`${BASE}/search/`);
    url.search = new URLSearchParams({
      apikey: apiKey,
      format: "json",
      lang: "ru_RU",
      from,
      to,
      date,
      transport_types: "suburban",
      limit: String(PAGE),
      offset: String(offset),
    });
    let res, body;
    try {
      res = await fetchImpl(url, { signal: AbortSignal.timeout(TIMEOUT_MS) });
      if (!res.ok) throw new UpstreamError(res.status, await res.text());
      body = await res.json();
    } catch (e) {
      if (e instanceof UpstreamError) throw e;
      throw new UpstreamError(0, `${e.name}: ${e.message}`);
    }
    segments.push(...(body?.segments ?? []));
    const total = body?.pagination?.total ?? 0;
    if (offset + PAGE >= total) return segments;
  }
}

module.exports = { UpstreamError, searchAll };
