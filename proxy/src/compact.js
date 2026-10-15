// Converts Yandex Rasp `search` segments into the compact form sent to the watch.
//
// Connect IQ limits drive the format: BLE runs at ~400-800 bytes/s and the
// glance and background processes have 32 KB each (a dense MCD day as nested
// arrays ran the fenix 6 glance out of memory). So each train is ONE number:
//
//   bits  0-10  departure, minutes since midnight (0..1439)
//   bits 11-12  flags (1 = express, 2 = aeroexpress)
//   bits 13-20  terminal: index into the day's string table `s`
//   bits 21-28  platform: index into `s` (0 = "")
//
// Strings repeat all day (same terminals and platforms), so they live once in
// `s` and trains refer to them by index.

const FLAG_EXPRESS = 1;
const FLAG_AEROEXPRESS = 2;
const MAX_STRINGS = 256; // 8-bit indexes

// "2026-10-07T08:42:00+03:00" -> 522 (minutes since local midnight).
// Yandex gives each time in its station's own zone, so this is the wall clock
// of that station, as on its departure board.
function toMinutes(iso) {
  const hh = Number(iso.slice(11, 13));
  const mm = Number(iso.slice(14, 16));
  if (!Number.isInteger(hh) || !Number.isInteger(mm)) {
    throw new Error(`Bad time: ${iso}`);
  }
  return hh * 60 + mm;
}

// "…+05:00" -> 300: minutes east of UTC, or null without an offset.
function offsetOf(iso) {
  const m = /(?:([+-])(\d{2}):(\d{2})|Z)$/.exec(String(iso ?? ""));
  if (!m) return null;
  if (!m[1]) return 0;
  const minutes = Number(m[2]) * 60 + Number(m[3]);
  return m[1] === "-" ? -minutes : minutes;
}

function flagsOf(thread) {
  switch (thread?.express_type) {
    case "express":
      return FLAG_EXPRESS;
    case "aeroexpress":
      return FLAG_AEROEXPRESS;
    default:
      return 0;
  }
}

// "Москва (Курский вокзал) — Петушки" -> "Петушки"
function terminalOf(thread) {
  const title = thread?.short_title || thread?.title || "";
  const parts = title.split(/\s+[—–-]\s+/);
  return parts[parts.length - 1].trim();
}

function packTrain(departure, flags, terminal, platform) {
  return departure | (flags << 11) | (terminal << 13) | (platform << 21);
}

class StringTable {
  constructor() {
    this.list = [""];
    this.index = new Map([["", 0]]);
  }
  id(value) {
    const s = String(value ?? "").trim();
    if (!this.index.has(s)) {
      if (this.list.length >= MAX_STRINGS) throw new Error("String table overflow");
      this.index.set(s, this.list.length);
      this.list.push(s);
    }
    return this.index.get(s);
  }
}

function compactSegments(segments, table) {
  return segments
    .filter((s) => !s.has_transfers && s.departure)
    .map((s) => ({
      dep: toMinutes(s.departure),
      packed: packTrain(toMinutes(s.departure), flagsOf(s.thread), table.id(terminalOf(s.thread)), table.id(s.departure_platform)),
    }))
    .sort((x, y) => x.dep - y.dep)
    .map((t) => t.packed);
}

// UTC offsets of both stations (za, zb), so the watch can tell the time at the
// station: A -> B segments depart in A's zone and arrive in B's, and the way
// back the other way round. Omitted when no segment carries them.
function zonesOf(abSegments, baSegments) {
  const first = (list) => list.find((x) => x !== null) ?? null;
  const za = first([...abSegments.map((s) => offsetOf(s.departure)), ...baSegments.map((s) => offsetOf(s.arrival))]);
  const zb = first([...baSegments.map((s) => offsetOf(s.departure)), ...abSegments.map((s) => offsetOf(s.arrival))]);
  return { ...(za !== null && { za }), ...(zb !== null && { zb }) };
}

// Both directions of a day with their shared string table.
function compactDay(abSegments, baSegments) {
  const table = new StringTable();
  const ab = compactSegments(abSegments, table);
  const ba = compactSegments(baSegments, table);
  return { ab, ba, s: table.list, ...zonesOf(abSegments, baSegments) };
}

module.exports = { FLAG_EXPRESS, FLAG_AEROEXPRESS, toMinutes, offsetOf, flagsOf, terminalOf, packTrain, compactDay };
