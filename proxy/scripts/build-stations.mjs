#!/usr/bin/env node
// Builds src/stations.json from the Yandex `stations_list` method (~35 MB).
// Keeps every Russian railway stop:
//   {"regions": [title, …],
//    "rows": [[yandexCode, title, direction, regionIndex, settlement, lat, lon], …]}
// sorted by title (stations.js relies on this order to keep the answers the
// Moscow-only list gave). Coordinates are rounded to ~100 m, null when missing.
//
// Usage: YANDEX_API_KEY=… node scripts/build-stations.mjs [stations_list.json]
// Docs: https://yandex.ru/dev/rasp/doc/ru/reference/stations-list
import { readFile, writeFile } from "node:fs/promises";

async function load(file) {
  if (file) return JSON.parse(await readFile(file, "utf8"));
  const key = process.env.YANDEX_API_KEY;
  if (!key) {
    console.error("Set YANDEX_API_KEY");
    process.exit(1);
  }
  const url = new URL("https://api.rasp.yandex-net.ru/v3.0/stations_list/");
  url.search = new URLSearchParams({ apikey: key, format: "json", lang: "ru_RU" });
  const res = await fetch(url);
  // The body echoes the key on errors: report the status only.
  if (!res.ok) throw new Error(`stations_list: HTTP ${res.status}`);
  return res.json();
}

const data = await load(process.argv[2]);

const RAIL_TYPES = new Set(["train", "suburban"]);
const coord = (x) => (x === "" || x == null || !Number.isFinite(Number(x)) ? null : Math.round(Number(x) * 1000) / 1000);
const regions = [];
const rows = [];
for (const country of data.countries) {
  if (country.title !== "Россия") continue;
  for (const region of country.regions) {
    const regionIndex = regions.push(region.title ?? "") - 1;
    for (const settlement of region.settlements) {
      for (const st of settlement.stations) {
        const code = st.codes?.yandex_code;
        if (!code || !RAIL_TYPES.has(String(st.transport_type).toLowerCase())) continue;
        rows.push([code, st.title, st.direction ?? "", regionIndex, settlement.title ?? "", coord(st.latitude), coord(st.longitude)]);
      }
    }
  }
}
rows.sort((x, y) => x[1].localeCompare(y[1], "ru"));

if (rows.length < 10000) throw new Error(`Only ${rows.length} stations: is stations_list complete?`);

const out = new URL("../src/stations.json", import.meta.url);
await writeFile(out, JSON.stringify({ regions, rows }) + "\n");
console.log(`Wrote ${rows.length} stations in ${regions.length} regions to ${out.pathname}`);
