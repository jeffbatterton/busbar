// Battery history from the logger (logger/), and the chart's shaping rules, which
// match the Mac app's: calendar windows, gaps, smoothing and charging bands.

const MINUTE = 60000;
/// Readings further apart than this are a gap: the line breaks there.
export const GAP_MS = 5 * MINUTE;
/// A reading is charging when this much more is coming in than going out, as `flow()` has it.
const CHARGING_WATTS = 5;
/// Charging stretches closer than this merge; shorter ones than the minimum are dropped.
const MERGE_MS = 15 * MINUTE;
const MIN_BAND_MS = 10 * MINUTE;
/// Smoothing bucket size per range, in minutes.
export const BUCKET_MINUTES = { day: 10, week: 60 };

/// The calendar window a range covers: local midnight to midnight, or Monday to Monday.
/// Date setters keep it right across daylight saving changes, when a day isn't 24 hours.
export function windowBounds(range, date = new Date()) {
  const start = new Date(date);
  start.setHours(0, 0, 0, 0);
  if (range === "week") start.setDate(start.getDate() - (start.getDay() + 6) % 7);
  const end = new Date(start);
  end.setDate(end.getDate() + (range === "week" ? 7 : 1));
  return { start: start.getTime(), end: end.getTime() };
}

/// The local midnights from `start`, `count` + 1 of them so the last day's end is included.
export function dayStarts(start, count) {
  const day = new Date(start);
  return Array.from({ length: count + 1 }, (_, i) => {
    if (i) day.setDate(day.getDate() + 1);
    return day.getTime();
  });
}

/// Splits readings, oldest first, into runs wherever the next comes more than a gap later.
export function splitRuns(readings, gap = GAP_MS) {
  const runs = [];
  for (const reading of readings) {
    const run = runs.at(-1);
    if (run && reading[0] - run.at(-1)[0] <= gap) run.push(reading);
    else runs.push([reading]);
  }
  return runs;
}

/// Averages a run into buckets of `minutes`, counted from `origin`: one `[time, soc]` point
/// per bucket at its mean time and charge. With `exactEnd` the run ends on its latest reading
/// as recorded, not averaged in, so the line finishes on the charge shown now.
export function buckets(run, minutes, origin = 0, exactEnd = false) {
  const size = minutes * MINUTE, points = [];
  const averaged = exactEnd ? run.slice(0, -1) : run;
  let key = null, sumT = 0, sumSoc = 0, n = 0;
  for (const [t, soc] of averaged) {
    const k = Math.floor((t - origin) / size);
    if (k !== key && n) {
      points.push([sumT / n, sumSoc / n]);
      sumT = sumSoc = n = 0;
    }
    key = k;
    sumT += t;
    sumSoc += soc;
    n++;
  }
  if (n) points.push([sumT / n, sumSoc / n]);
  if (exactEnd && run.length) points.push([run.at(-1)[0], run.at(-1)[1]]);
  return points;
}

export const isCharging = ([, , wattsIn, wattsOut]) => wattsIn - wattsOut > CHARGING_WATTS;

/// `[start, end]` times when power was coming in. A charging reading counts until the next
/// reading; stretches under 15 minutes apart merge, then any under 10 minutes long are dropped.
/// Each run is done separately, so a band never spans a gap.
export function chargingBands(readings) {
  const bands = [];
  for (const run of splitRuns(readings)) {
    const stretches = [];
    run.forEach((reading, i) => {
      if (!isCharging(reading)) return;
      const t = reading[0], end = run[i + 1]?.[0] ?? t;
      const last = stretches.at(-1);
      if (last && t - last[1] < MERGE_MS) last[1] = end;
      else stretches.push([t, end]);
    });
    bands.push(...stretches.filter(([start, end]) => end - start >= MIN_BAND_MS));
  }
  return bands;
}

/// An SVG path through `[x, y]` points as a monotone cubic (Fritsch–Carlson), so the curve
/// never overshoots the readings: no bumps above 100% or below a real low.
export function smooth(P) {
  if (P.length < 3) return P.map(([x, y], k) => `${k ? 'L' : 'M'}${x.toFixed(1)},${y.toFixed(1)}`).join('');
  const n = P.length, d = [], m = [];
  for (let i = 0; i < n - 1; i++) d.push((P[i + 1][1] - P[i][1]) / (P[i + 1][0] - P[i][0]));
  m[0] = d[0]; m[n - 1] = d[n - 2];
  for (let i = 1; i < n - 1; i++) m[i] = d[i - 1] * d[i] <= 0 ? 0 : 3 / (1 / d[i - 1] + 1 / d[i] + 1 / ((d[i - 1] + d[i]) / 2));
  let s = `M${P[0][0].toFixed(1)},${P[0][1].toFixed(1)}`;
  for (let i = 0; i < n - 1; i++) {
    const [x0, y0] = P[i], [x1, y1] = P[i + 1], h = (x1 - x0) / 3;
    s += `C${(x0 + h).toFixed(1)},${(y0 + m[i] * h).toFixed(1)} ${(x1 - h).toFixed(1)},${(y1 - m[i + 1] * h).toFixed(1)} ${x1.toFixed(1)},${y1.toFixed(1)}`;
  }
  return s;
}

/// This week's readings, `[time, soc, wattsIn, wattsOut]` oldest first. The first refresh
/// fetches from Monday; later ones only what's newer than the last reading. Failures keep
/// what's cached and set `error`.
export class HistoryCache {
  readings = [];
  error = null;
  simulated = false;
  /// The Mac app's `{ lowThreshold, criticalThreshold }`, once fetched.
  thresholds = null;
  #pending = null;

  /// Without a `url` nothing is fetched; the demo seeds `readings` and appends instead.
  constructor({ url = "", token = "", readings = [], fetch = (...args) => globalThis.fetch(...args),
    now = () => new Date() } = {}) {
    Object.assign(this, { url: url.replace(/\/+$/, ""), token, fetch, now });
    this.readings = readings;
  }

  /// Overlapping calls share one request.
  refresh() {
    this.#pending ??= this.#load().finally(() => { this.#pending = null; });
    return this.#pending;
  }

  /// Adds readings newer than the last one.
  append(readings) {
    const last = this.readings.at(-1)?.[0] ?? -Infinity;
    this.readings = this.readings.concat(readings.filter(([t]) => t > last));
  }

  async #load() {
    const now = this.now();
    const { start } = windowBounds("week", now);
    // A new week starts empty.
    if (this.readings[0]?.[0] < start) this.readings = this.readings.filter(([t]) => t >= start);
    if (!this.url) return;
    const since = this.readings.length ? this.readings.at(-1)[0] + 1 : start;
    if (since >= now.getTime()) return;
    try {
      const response = await this.fetch(`${this.url}/readings?since=${since}`, {
        headers: { Authorization: `Bearer ${this.token}` }, signal: AbortSignal.timeout(20000),
      });
      if (response.status === 401) throw new Error("The history token was refused");
      if (!response.ok) throw new Error(`History returned HTTP ${response.status}`);
      const body = await response.json();
      this.append(body.readings.filter(([t]) => t >= start));
      this.simulated = body.simulated === true;
      this.error = null;
    } catch (error) {
      this.error = error.message;
    }
    // Thresholds are a nicety: without them the app keeps what it had.
    try {
      const response = await this.fetch(`${this.url}/settings`, {
        headers: { Authorization: `Bearer ${this.token}` }, signal: AbortSignal.timeout(20000),
      });
      if (response.ok) this.thresholds = await response.json();
    } catch {}
  }
}

/// A plausible week of minute readings for the demo, Monday to `now`, ending at `endSoc`:
/// a solar bell from 6am to 8pm that varies by day, a ~200 W load with the odd spike, and
/// a short logger outage yesterday. The starting charge is searched for so the week lands
/// on the charge shown now.
export function simulatedHistory(endSoc, now = new Date(), capacityWh = 7200) {
  const { start } = windowBounds("week", now);
  const end = Math.floor(now.getTime() / MINUTE) * MINUTE;
  const outage = windowBounds("day", now).start - 11 * 3600000;
  const sunshine = [1, 0.7, 0.95, 0.5, 1, 0.85, 0.9];

  const run = (startSoc) => {
    // Seeded, so the same week looks the same on every reload.
    let seed = start % 2147483647 || 1;
    const random = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
    const readings = [];
    let soc = startSoc;
    for (let t = start; t <= end; t += MINUTE) {
      const time = new Date(t), hour = time.getHours() + time.getMinutes() / 60;
      const daylight = Math.max(0, Math.sin(((hour - 6) / 14) * Math.PI));
      const wattsOut = Math.round(200 + (random() - 0.5) * 60 + (random() < 0.03 ? 900 : 0));
      let wattsIn = Math.round(900 * sunshine[(time.getDay() + 6) % 7] * daylight * (0.9 + random() * 0.1));
      // Full: the charge controller only lets in what's being used.
      if (soc >= 100) wattsIn = Math.min(wattsIn, wattsOut);
      soc = Math.min(100, Math.max(0, soc + ((wattsIn - wattsOut) / 60 / capacityWh) * 100));
      if (t < outage || t >= outage + 40 * MINUTE) readings.push([t, Math.round(soc * 10) / 10, wattsIn, wattsOut]);
    }
    return readings;
  };

  let lo = 0, hi = 100, readings = run(50);
  for (let i = 0; i < 20; i++) {
    const mid = (lo + hi) / 2;
    readings = run(mid);
    if ((readings.at(-1)?.[1] ?? endSoc) < endSoc) lo = mid;
    else hi = mid;
  }
  return readings;
}
