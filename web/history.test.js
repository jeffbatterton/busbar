// Run with: cd web && node --test
// A zone with daylight saving, so the windows are checked across a 25-hour day.
process.env.TZ = "America/Los_Angeles";

import { test } from "node:test";
import assert from "node:assert/strict";
import { windowBounds, dayStarts, splitRuns, buckets, chargingBands, outages, smooth, HistoryCache } from "./history.js";

const MINUTE = 60000;
const at = (...args) => new Date(...args).getTime();
/// Minute readings from `start`, each `[t, soc, wattsIn, wattsOut]`.
const minutes = (start, count, soc = 50, wattsIn = 0, wattsOut = 200) =>
  Array.from({ length: count }, (_, i) => [start + i * MINUTE, soc, wattsIn, wattsOut]);

test("today runs midnight to midnight, even on the day the clocks go back", () => {
  // Sunday 1 November 2026 has 25 hours in Los Angeles.
  const { start, end } = windowBounds("day", new Date(2026, 10, 1, 15, 30));
  assert.equal(start, at(2026, 10, 1));
  assert.equal(end, at(2026, 10, 2));
  assert.equal(end - start, 25 * 3600000);
});

test("this week runs Monday to Monday, with Sunday the last day", () => {
  const sunday = windowBounds("week", new Date(2026, 10, 1, 23, 59));
  assert.equal(sunday.start, at(2026, 9, 26));
  assert.equal(sunday.end, at(2026, 10, 2));
  const monday = windowBounds("week", new Date(2026, 10, 2, 0, 0));
  assert.equal(monday.start, at(2026, 10, 2));
  assert.equal(monday.end, at(2026, 10, 9));
  assert.deepEqual(dayStarts(sunday.start, 7).slice(5), [at(2026, 9, 31), at(2026, 10, 1), at(2026, 10, 2)]);
});

test("readings more than 5 minutes apart start a new run", () => {
  const t = at(2026, 10, 3, 9);
  const runs = splitRuns([[t], [t + 5 * MINUTE], [t + 10 * MINUTE + 1], [t + 11 * MINUTE]]);
  assert.deepEqual(runs.map((run) => run.length), [2, 2]);
});

test("buckets average, and the run reaching now ends on its exact latest reading", () => {
  const t = at(2026, 10, 3, 9);
  const run = [[t, 50], [t + 5 * MINUTE, 52], [t + 10 * MINUTE, 60], [t + 12 * MINUTE, 61]];
  assert.deepEqual(buckets(run, 10, t), [[t + 2.5 * MINUTE, 51], [t + 11 * MINUTE, 60.5]]);
  assert.deepEqual(buckets(run, 10, t, true), [[t + 2.5 * MINUTE, 51], [t + 10 * MINUTE, 60], [t + 12 * MINUTE, 61]]);
  // A latest reading alone in its bucket isn't doubled.
  assert.deepEqual(buckets(run.slice(0, 3), 10, t, true), [[t + 2.5 * MINUTE, 51], [t + 10 * MINUTE, 60]]);
});

test("charging bands merge across short breaks and drop short stretches", () => {
  const t = at(2026, 10, 3, 9);
  const readings = [
    ...minutes(t, 20, 50, 500),                 // charging 9:00–9:20
    ...minutes(t + 20 * MINUTE, 10),            // a 10-minute break: merged
    ...minutes(t + 30 * MINUTE, 10, 50, 500),   // charging 9:30–9:40
    ...minutes(t + 40 * MINUTE, 20),            // a 20-minute break: kept apart
    ...minutes(t + 60 * MINUTE, 5, 50, 500),    // 5 minutes: too short, dropped
    ...minutes(t + 65 * MINUTE, 5, 50, 204),    // in over out by only 4 W: not charging
  ];
  assert.deepEqual(chargingBands(readings), [[t, t + 40 * MINUTE]]);
});

test("charging bands never cross a gap", () => {
  const t = at(2026, 10, 3, 9);
  const readings = [...minutes(t, 12, 50, 500), ...minutes(t + 20 * MINUTE, 12, 50, 500)];
  assert.deepEqual(chargingBands(readings), [[t, t + 11 * MINUTE], [t + 20 * MINUTE, t + 31 * MINUTE]]);
});

test("the smoothed path never overshoots a flat stretch", () => {
  assert.equal(smooth([[0, 10], [10, 20]]), "M0.0,10.0L10.0,20.0");
  const path = smooth([[0, 50], [10, 20], [20, 20], [30, 60]]);
  // The flat middle segment's control points stay on the flat.
  assert.match(path, /C13\.3,20\.0 16\.7,20\.0 20\.0,20\.0/);
});

test("the cache fetches from Monday, then only what's new", async () => {
  let now = new Date(2026, 10, 3, 12);
  const monday = at(2026, 10, 2);
  const requests = [];
  const pages = [minutes(monday, 3), minutes(at(2026, 10, 3, 12, 1), 2)];
  const thresholds = { lowThreshold: 40, criticalThreshold: 20 };
  const fetch = async (url, init) => {
    if (url.endsWith("/settings")) return { ok: true, status: 200, json: async () => thresholds };
    requests.push({ url, auth: init.headers.Authorization });
    return { ok: true, status: 200, json: async () => ({ simulated: false, readings: pages.shift() }) };
  };
  const cache = new HistoryCache({ url: "https://logger.example/", token: "tok", fetch, now: () => now });

  await cache.refresh();
  assert.deepEqual(requests[0], { url: `https://logger.example/readings?since=${monday}`, auth: "Bearer tok" });
  assert.equal(cache.readings.length, 3);
  assert.deepEqual(cache.thresholds, thresholds);

  now = new Date(2026, 10, 3, 12, 5);
  await cache.refresh();
  assert.equal(requests[1].url, `https://logger.example/readings?since=${monday + 2 * MINUTE + 1}`);
  assert.equal(cache.readings.length, 5);
});

test("a failed fetch keeps the cache, and a new week drops the old one once Live is past it", async () => {
  let now = new Date(2026, 10, 8, 23);
  let ok = true;
  const fetch = async () => (ok ? { ok: true, status: 200, json: async () => ({ readings: [] }) }
    : { ok: false, status: 500 });
  const cache = new HistoryCache({ url: "https://logger.example", token: "tok", fetch, now: () => now,
    readings: minutes(at(2026, 10, 8, 22), 3) });

  ok = false;
  await cache.refresh();
  assert.equal(cache.error, "History returned HTTP 500");
  assert.equal(cache.readings.length, 3);

  ok = true;
  now = new Date(2026, 10, 9, 0, 30);
  await cache.refresh();
  assert.equal(cache.error, null);
  // Live still reaches back to Sunday night.
  assert.equal(cache.readings.length, 3);

  now = new Date(2026, 10, 9, 3, 30);
  await cache.refresh();
  assert.equal(cache.readings.length, 0);
});

test("outages are gaps over 15 minutes, and the time since the last reading", () => {
  const t = at(2026, 10, 5, 3);
  const readings = [...minutes(t, 10), ...minutes(t + 24 * MINUTE, 10), ...minutes(t + 7 * 60 * MINUTE, 10)];
  const lastAt = t + 7 * 60 * MINUTE + 9 * MINUTE;
  assert.deepEqual(outages(readings, lastAt + MINUTE), [[t + 33 * MINUTE, t + 7 * 60 * MINUTE]]);
  assert.deepEqual(outages(readings, lastAt + 20 * MINUTE).at(-1), [lastAt, lastAt + 20 * MINUTE]);
});
