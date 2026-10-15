const assert = require("node:assert/strict");
const { test } = require("node:test");
const { buildIndex, normalize, resolvePair, searchStations, upgrade } = require("../src/stations.js");
const { DB } = require("./fixtures.js");

const pair = (a, b) => {
  const r = resolvePair(a, b, DB);
  return r.error ? r.error : [r.a.code, r.b.code];
};

test("normalize drops station-type words and ё", () => {
  assert.equal(normalize("пл. Беговая"), "беговая");
  assert.equal(normalize("Станция Лесной  Городок"), "лесной городок");
  assert.equal(normalize("Щёлково"), "щелково");
});

test("unique names resolve as before", () => {
  assert.deepEqual(pair("Одинцово", "Беговая"), ["s112", "s101"]);
  assert.deepEqual(pair("одинцово", "бегов"), ["s112", "s101"], "case and prefix");
});

test("a homonym is resolved by the other station", () => {
  assert.deepEqual(pair("Заводская", "Ижевск"), ["s106", "s108"]);
  assert.deepEqual(pair("Находка", "Заводская"), ["s111", "s107"]);
});

test("a qualifier after a comma picks the city, region or direction", () => {
  assert.deepEqual(pair("Заводская, Находка", "Находка"), ["s107", "s111"]);
  assert.deepEqual(pair("Заводская, Удмуртия", "Беговая"), ["s106", "s101"], "region stem");
  assert.deepEqual(pair("Депо, Казанское", "Одинцово"), ["s103", "s112"], "direction");
  assert.deepEqual(pair("Перово, Краснодарский", "Ленинградская"), ["s115", "s109"]);
});

test("old Moscow settings keep their old answer", () => {
  // Both "Перово" are candidates, Moscow is next to Одинцово.
  assert.deepEqual(pair("Перово", "Одинцово"), ["s114", "s112"]);
  // Two Moscow "Депо" are equally plausible: the old resolver took the first.
  assert.deepEqual(pair("Депо", "Одинцово"), ["s102", "s112"]);
  // An exact name 1300 km away loses to the Moscow prefix match next door.
  assert.deepEqual(pair("Ленинградская", "Беговая"), ["s110", "s101"]);
});

test("a closer pair elsewhere does not take over old Moscow settings", () => {
  // Yekaterinburg's 15 км and 32 км are 15 km apart, Moscow's ~90 km.
  assert.deepEqual(pair("15 км", "32 км"), ["s117", "s118"]);
  assert.deepEqual(pair("15 км, Свердловская", "32 км, Свердловская"), ["s119", "s120"]);
  assert.deepEqual(pair("15 км, Пермское", "32 км"), ["s119", "s120"], "one qualifier is enough");
});

test("a comma inside a title is not a qualifier", () => {
  assert.deepEqual(pair("Кутузовская, МЦК", "Беговая"), ["s121", "s101"]);
  assert.deepEqual(pair("Заводская, Ижевск, Удмуртия", "Беговая"), ["s106", "s101"], "everything after the first comma qualifies");
});

test("abbreviated Yandex titles match full words", () => {
  assert.deepEqual(pair("Екатеринбург-Пассажирский", "Первоуральск"), ["s104", "s113"]);
});

test("ambiguity is reported with options that are valid input", () => {
  const err = pair("Заводская", "Перово");
  assert.equal(err.reason, "ambiguous");
  assert.equal(err.which, "b");
  assert.equal(err.q, "Перово");
  assert.deepEqual(err.options, ["Перово, Москва", "Перово, Краснодарский край"]);
  for (const option of err.options) {
    assert.ok(!pair("Заводская", option).reason, `${option} resolves`);
  }

  const ekb = pair("Екатеринбург", "Первоуральск");
  assert.equal(ekb.which, "a");
  assert.deepEqual(ekb.options, ["Екатеринбург-Пасс.", "Екатеринбург-Сорт."]);
});

test("not found names the station; a qualifier that excludes all is not found", () => {
  assert.deepEqual(pair("Нет такой", "Беговая"), { reason: "notfound", which: "a", q: "Нет такой" });
  assert.deepEqual(pair("Беговая", "Заводская, Москва"), { reason: "notfound", which: "b", q: "Заводская, Москва" });
  assert.equal(pair("", "Беговая").which, "a");
});

test("codes pass through, also unknown ones", () => {
  assert.deepEqual(pair("s107", "Находка"), ["s107", "s111"]);
  const r = resolvePair("s999", "s101", DB);
  assert.deepEqual(r.a, { code: "s999", title: "s999", direction: "" });
});

test("a station without coordinates resolves within its region", () => {
  assert.deepEqual(pair("Сарапул", "Ижевск"), ["s116", "s108"]);
});

test("searchStations shows where a station is and what to type", () => {
  const found = searchStations("Заводская", DB);
  assert.deepEqual(
    found.map((s) => [s.code, s.region, s.input]),
    [
      ["s106", "Удмуртская Республика", "Заводская, Ижевск"],
      ["s107", "Приморский край", "Заводская, Находка"],
    ],
  );
  assert.deepEqual(searchStations("", DB), []);
});

test("a Moscow-only stations.json from before still loads", () => {
  const db = buildIndex(upgrade([["s1", "Одинцово", "МЦД-1"], ["s2", "Беговая", "Белорусское"]]));
  const r = resolvePair("Одинцово", "Беговая", db);
  assert.deepEqual([r.a.code, r.b.code], ["s1", "s2"]);
});
