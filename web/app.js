import { DeltaProSource, SimulatedSource, flow, isOn, withOutput, restoreOutput } from "./ecoflow.js";
import { HistoryCache, BUCKET_MINUTES, windowBounds, dayStarts, buckets, isCharging,
  splitRuns, outages, OFFLINE_MS,
  smooth, simulatedHistory } from "./history.js";

/// Polls while the app is open. It pauses in the background and refreshes on return.
const POLL_SECONDS = 15;
/// Readings older than this show as stale, matching the Mac app's default.
const STALE_MINUTES = 10;
const STORAGE_KEY = "busbar.credentials";
const BASELINE_KEY = "busbar.rawBaseline";
const HISTORY_KEY = "busbar.history";
const RANGE_KEY = "busbar.historyRange";
const THRESHOLDS_KEY = "busbar.thresholds";
const HISTORY_URL = "https://busbar-logger.jeffbatterton.workers.dev";

const $ = (selector) => document.querySelector(selector);
/// A phone on its side: the dashboard is just the chart, full screen.
const landscape = matchMedia("(orientation: landscape) and (max-height: 500px)");
const demo = new URLSearchParams(location.search).has("demo");

const state = {
  source: null,
  snapshot: null,
  lastUpdate: null,
  error: null,
  /// Outputs with a switch command in flight.
  switching: new Set(),
  /// States just switched to, shown until the device reports them (it lags a few seconds).
  expected: new Map(),
  timer: null,
  /// The last raw quotas fetched for the Raw values screen.
  raw: null,
  /// This week's readings from the logger, or null with no read token set.
  history: null,
  /// The chart's range, "live", "day" or "week".
  range: ["live", "week"].includes(localStorage.getItem(RANGE_KEY)) ? localStorage.getItem(RANGE_KEY) : "day",
  /// What the chart was last drawn with, for hovering; and where the pointer is, if over it.
  chart: null,
  hoverX: null,
  /// The alert thresholds from the Mac app, by way of the logger, kept for next time.
  thresholds: savedThresholds(),
};

function savedThresholds() {
  try {
    const saved = JSON.parse(localStorage.getItem(THRESHOLDS_KEY));
    if (saved?.lowThreshold > saved?.criticalThreshold) return { ...saved, fromMac: true };
  } catch {}
  // Until the logger shares them, the Mac app's as set there.
  return { lowThreshold: 25, criticalThreshold: 10, fromMac: false };
}

// MARK: Screens

function show(screen) {
  for (const id of ["launch", "setup", "dashboard", "raw"]) $(`#${id}`).hidden = id !== screen;
}

function savedCredentials() {
  try {
    const saved = JSON.parse(localStorage.getItem(STORAGE_KEY));
    return saved?.accessKey && saved?.secretKey && saved?.serialNumber ? saved : null;
  } catch {
    return null;
  }
}

/// The history settings as saved: the URL may be blank, meaning the default.
function savedHistory() {
  try {
    return JSON.parse(localStorage.getItem(HISTORY_KEY)) ?? {};
  } catch {
    return {};
  }
}

async function launch() {
  const credentials = savedCredentials();
  if (!demo && !credentials) return showSetup();
  state.source = demo ? new SimulatedSource() : new DeltaProSource(credentials);
  $("#launch-message").innerHTML = '<span class="spin"></span>Connecting to Delta Pro…';
  $("#launch-message").classList.remove("failed");
  $("#launch-actions").hidden = true;
  show("launch");
  try {
    state.snapshot = await state.source.snapshot();
    state.lastUpdate = new Date();
    state.error = null;
    render();
    show("dashboard");
    startHistory();
    schedule();
  } catch (error) {
    $("#launch-message").textContent = error.message;
    $("#launch-message").classList.add("failed");
    $("#launch-actions").hidden = false;
  }
}

function showSetup() {
  stop();
  const form = $("#setup-form");
  const saved = savedCredentials();
  for (const name of ["accessKey", "secretKey", "serialNumber"]) form.elements[name].value = saved?.[name] ?? "";
  const history = savedHistory();
  form.elements.historyUrl.value = history.url ?? "";
  form.elements.historyToken.value = history.token ?? "";
  const { lowThreshold, criticalThreshold, fromMac } = state.thresholds;
  $("#thresholds-h").hidden = $("#thresholds").hidden = $("#thresholds-help").hidden = !fromMac;
  $("#low-threshold").textContent = `${Math.round(lowThreshold)}%`;
  $("#critical-threshold").textContent = `${Math.round(criticalThreshold)}%`;
  $("#setup-error").hidden = true;
  // Opened from the dashboard's Settings link, there's a connection to go back to.
  $("#setup-cancel").hidden = !saved && !demo;
  $("#home-tip").hidden = navigator.standalone === true || matchMedia("(display-mode: standalone)").matches;
  show("setup");
}

/// Checks the keys with EcoFlow before saving them, so a typo shows up here.
async function connect(event) {
  event.preventDefault();
  const form = event.target;
  const credentials = Object.fromEntries(["accessKey", "secretKey", "serialNumber"]
    .map((name) => [name, form.elements[name].value.trim()]));
  const button = $("#connect");
  button.disabled = true;
  button.textContent = "Connecting…";
  $("#setup-error").hidden = true;
  try {
    const source = new DeltaProSource(credentials);
    state.snapshot = await source.snapshot();
    localStorage.setItem(STORAGE_KEY, JSON.stringify(credentials));
    const history = { url: form.elements.historyUrl.value.trim(), token: form.elements.historyToken.value.trim() };
    if (history.token) localStorage.setItem(HISTORY_KEY, JSON.stringify(history));
    else localStorage.removeItem(HISTORY_KEY);
    Object.assign(state, { source, lastUpdate: new Date(), error: null });
    render();
    show("dashboard");
    startHistory();
    schedule();
  } catch (error) {
    $("#setup-error").textContent = error.message;
    $("#setup-error").hidden = false;
  } finally {
    button.disabled = false;
    button.textContent = "Connect";
  }
}

async function disconnect() {
  if (!(await confirmAlert("Disconnect from Delta Pro?", "Disconnect"))) return;
  localStorage.removeItem(STORAGE_KEY);
  localStorage.removeItem(HISTORY_KEY);
  localStorage.removeItem(THRESHOLDS_KEY);
  state.thresholds = savedThresholds();
  Object.assign(state, { source: null, snapshot: null, lastUpdate: null, error: null, history: null });
  state.expected.clear();
  if (demo) history.replaceState(null, "", location.pathname);
  showSetup();
  $("#setup-form").reset();
}

// MARK: Polling

function schedule(delay = POLL_SECONDS * 1000) {
  stop();
  state.timer = setTimeout(async () => {
    await refresh();
    schedule();
  }, delay);
}

function stop() {
  clearTimeout(state.timer);
  state.timer = null;
}

async function refresh() {
  if (!state.source) return;
  try {
    let snapshot = await state.source.snapshot();
    for (const [output, expected] of state.expected) {
      if (isOn(snapshot, output) === expected.on || expected.until < Date.now()) state.expected.delete(output);
      else snapshot = withOutput(snapshot, output, expected.on);
    }
    Object.assign(state, { snapshot, lastUpdate: new Date(), error: null });
  } catch (error) {
    state.error = error.message;
  }
  render();
  refreshHistory();
}

document.addEventListener("visibilitychange", () => {
  if (!state.source || $("#dashboard").hidden) return;
  if (document.hidden) stop();
  else schedule(0);
});

// MARK: Outputs

/// Switching on happens straight away. Switching off asks first: turning the AC off
/// can take the router, and with it the Delta Pro's own connection, down with it.
async function toggle(row) {
  const output = row.dataset.output;
  const before = state.snapshot;
  if (!before || state.switching.has(output)) return;
  const on = !isOn(before, output);
  if (!on && !(await confirmAlert(`Turn off ${row.dataset.title.toLowerCase()}?`, "Turn Off"))) return;

  state.switching.add(output);
  state.expected.set(output, { on, until: Date.now() + 20000 });
  state.snapshot = withOutput(state.snapshot, output, on);
  render();
  try {
    await state.source.setOutput(output, on);
    state.error = null;
    schedule(3000);
  } catch (error) {
    state.expected.delete(output);
    state.snapshot = restoreOutput(state.snapshot, output, before);
    state.error = `Couldn't switch ${on ? "on" : "off"}: ${error.message}`;
  } finally {
    state.switching.delete(output);
    render();
  }
}

// MARK: Alert

function confirmAlert(title, action) {
  const layer = $("#alert");
  $("#alert-title").textContent = title;
  $("#alert-ok").textContent = action;
  layer.hidden = false;
  return new Promise((resolve) => {
    const finish = (result) => {
      layer.hidden = true;
      $("#alert-ok").onclick = $("#alert-cancel").onclick = layer.querySelector(".scrim").onclick = null;
      resolve(result);
    };
    $("#alert-ok").onclick = () => finish(true);
    $("#alert-cancel").onclick = layer.querySelector(".scrim").onclick = () => finish(false);
  });
}

// MARK: Rendering

const watts = (value) => (value >= 1000 ? `${(value / 1000).toFixed(2)} kW` : `${value} W`);

function duration(minutes) {
  const h = Math.floor(minutes / 60), m = minutes % 60;
  if (h === 0) return `${m}m`;
  if (h >= 24) return `${Math.floor(h / 24)}d ${h % 24}h`;
  return m === 0 ? `${h}h` : `${h}h ${m}m`;
}

function isStale() {
  if (!state.lastUpdate) return state.error !== null;
  return Date.now() - state.lastUpdate >= STALE_MINUTES * 60000;
}

function updatedText() {
  if (!state.lastUpdate) return "Not updated yet";
  const seconds = Math.floor((Date.now() - state.lastUpdate) / 1000);
  if (seconds < 5) return "Updated just now";
  if (seconds < 60) return `Updated ${seconds}s ago`;
  return `Updated ${duration(Math.floor(seconds / 60))} ago`;
}

function renderStatus() {
  const stale = isStale();
  $("#dot").classList.toggle("stale", stale || state.error !== null);
  $("#updated").textContent = updatedText();
  $("#updated").classList.toggle("stale", stale);
}

function render() {
  const s = state.snapshot;
  if (!s) return;
  renderStatus();

  const soc = Math.round(s.stateOfCharge);
  $("#soc").textContent = `${soc}%`;
  $("#history-soc").textContent = `${soc}%`;
  const level = levelColor(soc);
  renderBar(s, level);

  const direction = flow(s);
  $("#flow-title").textContent = { charging: "Charging", discharging: "Discharging", idle: "Idle" }[direction];
  $("#flow-title").className = direction;
  $("#flow-detail").textContent = direction === "charging" && s.minutesToFull ? `${duration(s.minutesToFull)} to full`
    : direction === "discharging" && s.minutesToEmpty ? `${duration(s.minutesToEmpty)} left` : "";

  $("#dash-error").hidden = !state.error;
  $("#dash-error span").textContent = state.error ?? "";
  $("#warnings").replaceChildren(...s.warnings.map((text) => {
    const row = document.createElement("p");
    row.className = "warning";
    row.innerHTML = '<svg class="ic"><use href="#i-warning"/></svg><span></span>';
    row.querySelector("span").textContent = text;
    return row;
  }));

  $("#watts-in").textContent = watts(s.wattsIn);
  for (const row of document.querySelectorAll("[data-input]")) {
    const value = s[row.dataset.input];
    row.classList.toggle("lit-in", value > 0);
    row.querySelector(".w").textContent = watts(value);
    row.querySelector(".w").classList.toggle("zero", value === 0);
  }
  $("#shore-detail").hidden = !s.shorePowerConnected;

  $("#watts-out").textContent = watts(s.wattsOut);
  for (const row of document.querySelectorAll("[data-output]")) {
    const output = row.dataset.output;
    const on = isOn(s, output);
    const value = output === "ac" ? s.acOutWatts : s.dc12VOutWatts;
    row.classList.toggle("lit-out", on);
    const button = row.querySelector(".tog");
    button.disabled = state.switching.has(output);
    button.setAttribute("aria-label", `Turn ${row.dataset.title.toLowerCase()} ${on ? "off" : "on"}`);
    // An output that's off reads Off, so it can't be mistaken for one that's on but idle.
    row.querySelector(".w").textContent = on ? watts(value) : "Off";
    row.querySelector(".w").classList.toggle("zero", !on || value === 0);
  }

  renderBatteries(s);
  renderHistory();
}

/// The charge bar: solid from the discharge limit to the level, striped past either limit.
function renderBar(s, level) {
  const soc = Math.min(100, Math.max(0, s.stateOfCharge));
  const low = s.dischargeLimit, high = s.chargeLimit;
  $(".hero .bar").style.setProperty("--level", level);
  $("#bar-reserve").style.width = `${Math.min(soc, low)}%`;
  $("#bar-over").style.left = `${high}%`;
  $("#bar-over").hidden = high >= 100;
  const fill = $("#bar-fill");
  fill.hidden = soc <= low && low > 0;
  fill.classList.toggle("limited", low > 0);
  fill.style.left = `${low}%`;
  fill.style.width = `${Math.max(0, soc - low)}%`;
  for (const [id, limit] of [["#limit-low", low], ["#limit-high", high]]) {
    $(id).hidden = limit <= 0 || limit >= 100;
    $(id).style.left = `${limit}%`;
  }
}

/// The charge bar's color. Hex, not var(--good), so SVG
/// attributes can use it too.
function levelColor(soc) {
  const { lowThreshold, criticalThreshold } = state.thresholds;
  return soc <= criticalThreshold ? "#ff453a" : soc <= lowThreshold ? "#ffd60a" : "#30d158";
}

/// The history line's colors by charge: red up to critical, yellow at low, green from 20
/// points above low, blended in between.
function lineColors() {
  const { lowThreshold, criticalThreshold } = state.thresholds;
  return [[criticalThreshold, [255, 69, 58]], [lowThreshold, [255, 214, 10]],
    [Math.min(100, lowThreshold + 20), [48, 209, 88]]];
}

function lineColor(soc) {
  const colors = lineColors();
  const upper = colors.findIndex(([level]) => soc < level);
  if (upper === -1) return `rgb(${colors.at(-1)[1]})`;
  if (upper === 0) return `rgb(${colors[0][1]})`;
  const [[a, from], [b, to]] = [colors[upper - 1], colors[upper]];
  const k = (soc - a) / (b - a);
  return `rgb(${from.map((c, i) => Math.round(c + (to[i] - c) * k))})`;
}

function renderBatteries(s) {
  // Main is first and Extra second; the transfer only shows while both are online.
  const transfer = s.batteries.length === 2 && s.batteries.every((b) => b.isAvailable) ? s.packTransferWatts : 0;
  const sender = transfer > 0 ? 1 : 0;
  const bracket = $("#bracket");
  // An SVG element has no `hidden` property, only the attribute.
  bracket.toggleAttribute("hidden", transfer === 0);
  bracket.classList.toggle("down", transfer < 0);

  for (const row of document.querySelectorAll("[data-pack]")) {
    const index = Number(row.dataset.pack);
    const battery = s.batteries[index];
    row.hidden = !battery;
    if (!battery) continue;
    row.querySelector(".name").textContent = battery.name;
    row.classList.toggle("lit-good", battery.isAvailable);
    row.classList.toggle("lit-bad", !battery.isAvailable);
    row.classList.toggle("unavailable", !battery.isAvailable);
    row.classList.toggle("receiving", transfer !== 0 && index !== sender);

    // Extra sits below Main, so the arrow points at the pack receiving the power.
    const xfer = row.querySelector(".xfer");
    xfer.hidden = transfer === 0 || index !== sender;
    xfer.querySelector("use").setAttribute("href", transfer > 0 ? "#i-up" : "#i-down");
    xfer.querySelector("span").textContent = watts(Math.abs(transfer));

    row.querySelector(".temp").textContent = battery.temperature === null ? ""
      : `${Math.round(battery.temperature * 9 / 5 + 32)}°F`;
    row.querySelector(".pct").textContent = !battery.isAvailable ? "Unavailable"
      : battery.stateOfCharge === null ? "Connected" : `${Math.round(battery.stateOfCharge)}%`;
  }
}

setInterval(() => {
  if (state.snapshot && !$("#dashboard").hidden) renderStatus();
}, 5000);

// MARK: Battery history

const CHART_HEIGHT = 76, AXIS_HEIGHT = 16, Y_LABELS_WIDTH = 34;
/// The card's background, or the page's in landscape, so dots stand out from the line behind them.
const PANEL = "#1c1c1f", BACKGROUND = "#0d0d0f";

/// Starts this week's history, after the first snapshot. The demo makes up a week ending
/// at its current charge, then adds a reading a minute as the logger would.
function startHistory() {
  const { url, token } = savedHistory();
  state.history = demo ? new HistoryCache({ readings: simulatedHistory(state.snapshot.stateOfCharge) })
    : token ? new HistoryCache({ url: url || HISTORY_URL, token }) : null;
  state.hoverX = null;
  renderHistory();
  refreshHistory();
}

/// Rides along with each poll; only readings newer than the last are fetched.
async function refreshHistory() {
  const history = state.history;
  if (!history) return;
  if (demo && state.snapshot && Date.now() - (history.readings.at(-1)?.[0] ?? 0) >= 60000) {
    const s = state.snapshot;
    history.append([[Date.now(), Math.round(s.stateOfCharge * 10) / 10, s.wattsIn, s.wattsOut]]);
  }
  await history.refresh();
  if (history !== state.history) return;
  const thresholds = history.thresholds;
  if (thresholds?.lowThreshold > thresholds?.criticalThreshold) {
    localStorage.setItem(THRESHOLDS_KEY, JSON.stringify(thresholds));
    state.thresholds = { ...thresholds, fromMac: true };
    render();
  }
  renderHistory();
}

function renderHistory() {
  const history = state.history;
  $("#history").hidden = !history;
  if (!history || !state.snapshot) return;
  for (const button of document.querySelectorAll("[data-range]")) {
    button.classList.toggle("on", button.dataset.range === state.range);
  }
  // With nothing to draw, a failure says so quietly; while loading the chart is just empty.
  const failed = history.readings.length === 0 && history.error !== null;
  $("#history-error").hidden = !failed;
  $("#chart").hidden = failed;
  const svg = $("#chart-svg"), box = svg.getBoundingClientRect();
  if (failed || !box.width) return;

  // Full screen, the chart takes the height it's given and labels its gridlines on the right.
  const large = landscape.matches;
  const width = large ? box.width - Y_LABELS_WIDTH : box.width;
  const range = state.range, H = large ? box.height - AXIS_HEIGHT : CHART_HEIGHT, now = Date.now();
  const { start, end } = windowBounds(range, new Date(now));
  const x = (t) => ((t - start) / (end - start)) * width;
  const y = (soc) => H - (Math.min(100, Math.max(0, soc)) / 100) * H;
  const f = (n) => n.toFixed(1);
  const hline = (soc, attrs) => `<line x1="0" x2="${f(width)}" y1="${f(y(soc))}" y2="${f(y(soc))}" ${attrs}/>`;
  const readings = history.readings.filter(([t]) => t >= start && t < end);
  const latest = history.readings.at(-1);
  // The line takes its color from its height, so its gradient spans the plot; the fill's
  // spans the highest charge down to 0, fading as it goes.
  const top = Math.max(1, ...readings.map(([, soc]) => soc));
  const gradient = (id, high, opacity) => {
    const levels = [high, ...lineColors().map(([level]) => level).reverse().filter((level) => level < high), 0];
    return `<linearGradient id="${id}" gradientUnits="userSpaceOnUse" x1="0" y1="${f(y(high))}" x2="0" y2="${H}">${levels.map((soc) =>
      `<stop offset="${(1 - soc / high).toFixed(3)}" stop-color="${lineColor(soc)}" stop-opacity="${opacity(soc).toFixed(3)}"/>`).join("")}</linearGradient>`;
  };
  const hatch = `<pattern id="chart-hatch" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">
    <rect width="6" height="6" fill="rgba(255,255,255,.025)"/><line x1="0" y1="0" x2="0" y2="6" stroke="rgba(255,255,255,.08)" stroke-width="2"/></pattern>`;
  const parts = [`<defs>${gradient("chart-line", 100, () => 1)}${gradient("chart-fill", top, (soc) => 0.24 * soc / top)}${hatch}</defs>`];

  // Hatched wherever the Delta Pro was offline, cut to the window and to now. Found from all
  // the readings, so one that began before the window still shows.
  const offline = outages(history.readings, now)
    .map(([from, to]) => [Math.max(from, start), Math.min(to, end, now), from, to, to === now])
    .filter(([from, to]) => from < to);
  for (const [from, to] of offline) {
    parts.push(`<rect x="${f(x(from))}" y="0" width="${f(x(to) - x(from))}" height="${H}" fill="url(#chart-hatch)"/>`);
  }

  for (const soc of large ? [100, 75, 50, 25] : [100, 50]) parts.push(hline(soc, 'stroke="rgba(255,255,255,.07)"'));
  parts.push(hline(0, 'stroke="rgba(255,255,255,.16)"'));
  if (large) {
    for (const soc of [100, 75, 50, 25, 0]) {
      parts.push(`<text x="${f(width + 8)}" y="${f(y(soc) + 3.5)}">${soc}%</text>`);
    }
  }

  // The axis: each whole hour, quarter days, or a column per weekday with today's brighter.
  const label = (at, text, anchor = "middle", today = false) =>
    `<text x="${f(at)}" y="${H + AXIS_HEIGHT - 3}" text-anchor="${anchor}"${today ? ' class="today"' : ""}>${text}</text>`;
  if (range === "live") {
    const hour = new Date(start);
    hour.setMinutes(60, 0, 0);
    for (; hour.getTime() < end - 15 * 60000; hour.setHours(hour.getHours() + 1)) {
      if (hour.getTime() - start < 15 * 60000) continue;
      const text = hour.toLocaleTimeString([], { hour: "numeric" }).replace(/\s/g, "").toLowerCase();
      parts.push(label(x(hour.getTime()), text));
    }
  } else if (range === "day") {
    const labels = large ? ["12am", "3am", "6am", "9am", "12pm", "3pm", "6pm", "9pm"] : ["12am", "6am", "12pm", "6pm"];
    labels.forEach((text, i) => parts.push(label((width * i) / labels.length, text, i ? "middle" : "start")));
  } else {
    const days = dayStarts(start, 7);
    ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].forEach((text, i) => {
      if (i) parts.push(`<line x1="${f(x(days[i]))}" x2="${f(x(days[i]))}" y1="0" y2="${H}" stroke="rgba(255,255,255,.07)"/>`);
      parts.push(label((x(days[i]) + x(days[i + 1])) / 2, text, "middle", now >= days[i] && now < days[i + 1]));
    });
  }
  parts.push(hline(state.thresholds.lowThreshold, 'stroke="#ffd60a" stroke-opacity=".22" stroke-dasharray="2 3"'));

  // A line per stretch the Delta Pro was online, running straight on across the few minutes
  // the logger sometimes misses. Live's buckets keep to the clock, not its moving window, so
  // the line holds still.
  const segments = splitRuns(readings, OFFLINE_MS).map((run) =>
    buckets(run, BUCKET_MINUTES[range], range === "live" ? 0 : start, run.at(-1) === latest)
      .map(([t, soc]) => [x(t), y(soc), soc]));
  for (const points of segments) {
    if (points.length < 2) continue;
    const path = smooth(points);
    parts.push(`<path d="${path}L${f(points.at(-1)[0])},${H}L${f(points[0][0])},${H}Z" fill="url(#chart-fill)"/>`,
      `<path d="${path}" fill="none" stroke="url(#chart-line)" stroke-width="${large ? 2.5 : 2}" stroke-linejoin="round" stroke-linecap="round"/>`);
  }
  // Across each outage, a dotted line from where the charge left off to where it came back,
  // with a small open dot at each end.
  segments.slice(1).forEach((points, i) => {
    const from = segments[i].at(-1), to = points[0];
    parts.push(`<line x1="${f(from[0])}" y1="${f(from[1])}" x2="${f(to[0])}" y2="${f(to[1])}" stroke="${lineColor((from[2] + to[2]) / 2)}"
      stroke-opacity=".55" stroke-width="${large ? 2 : 1.5}" stroke-dasharray="0.1 4" stroke-linecap="round"/>`);
    for (const [cx, cy, soc] of [from, to]) {
      parts.push(`<circle cx="${f(cx)}" cy="${f(cy)}" r="${large ? 3 : 2.5}" fill="${large ? BACKGROUND : PANEL}" stroke="${lineColor(soc)}" stroke-width="1.5"/>`);
    }
  });
  const dot = `r="${large ? 5 : 4}" stroke="${large ? BACKGROUND : PANEL}" stroke-width="2"`;
  if (latest && latest[0] >= start && latest[0] < end) {
    parts.push(`<circle cx="${f(x(latest[0]))}" cy="${f(y(latest[1]))}" fill="${lineColor(latest[1])}" ${dot}/>`);
  }
  parts.push(`<g id="chart-hover" visibility="hidden"><line y1="0" y2="${H}" stroke="rgba(255,255,255,.4)"/>
    <circle ${dot}/></g>`);

  svg.innerHTML = parts.join("");
  state.chart = { readings, latest, range, width, start, end, x, y, H, offline };
  if (state.hoverX === null) $("#chart-tip").hidden = true;
  else hover(state.hoverX);
}

/// Snaps to the recorded reading nearest the pointer, which is never past now.
function hover(px) {
  const chart = state.chart;
  if (!chart?.readings.length && !chart?.offline.length) return;
  state.hoverX = px;
  const t = chart.start + (px / chart.width) * (chart.end - chart.start);
  const tip = $("#chart-tip");
  const top = $("#chart-svg").getBoundingClientRect().top - $("#chart").getBoundingClientRect().top;
  const outage = chart.offline.find(([from, to]) => from < t && t < to);
  if (outage || !chart.readings.length) return outage ? hoverOffline(outage, px, tip, top) : unhover();
  let reading = chart.readings[0];
  for (const r of chart.readings) if (Math.abs(r[0] - t) < Math.abs(reading[0] - t)) reading = r;

  const [time, soc] = reading, cx = chart.x(time), cy = chart.y(soc);
  const group = $("#chart-hover");
  group.setAttribute("visibility", "visible");
  group.querySelector("line").setAttribute("x1", cx);
  group.querySelector("line").setAttribute("x2", cx);
  group.querySelector("circle").setAttribute("cx", cx);
  group.querySelector("circle").setAttribute("cy", cy);
  group.querySelector("circle").setAttribute("fill", lineColor(soc));
  group.querySelector("circle").setAttribute("visibility", "visible");

  const date = new Date(time);
  const at = reading === chart.latest ? "Now"
    : (chart.range === "week" ? `${date.toLocaleDateString([], { weekday: "short" })} ` : "")
      + date.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  tip.innerHTML = `<b>${Math.round(soc)}%</b> ${at}${isCharging(reading) ? " · charging" : ""}`;
  if (landscape.matches) {
    const [, , wattsIn, wattsOut] = reading;
    tip.innerHTML += `<span class="w">${wattsIn > 0 ? `<span style="color:var(--in)">${watts(wattsIn)} in</span> · ` : ""}${watts(wattsOut)} out</span>`;
  }
  tip.hidden = false;
  // Kept inside the card, however near the edge the reading is.
  const half = tip.offsetWidth / 2;
  tip.style.left = `${Math.min(chart.width - half, Math.max(half, cx))}px`;
  tip.style.top = `${top + cy - 8}px`;
}

/// Over an outage: when it was and how long, with the crosshair but no dot.
function hoverOffline([, , from, to, ongoing], px, tip, top) {
  const chart = state.chart;
  const group = $("#chart-hover");
  group.setAttribute("visibility", "visible");
  group.querySelector("line").setAttribute("x1", px);
  group.querySelector("line").setAttribute("x2", px);
  group.querySelector("circle").setAttribute("visibility", "hidden");
  const clock = (t) => new Date(t).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  tip.innerHTML = `<b>Offline</b> ${ongoing ? `since ${clock(from)}` : `${clock(from)} – ${clock(to)}`}`
    + `<span class="sub">No readings for ${duration(Math.round((to - from) / 60000))}</span>`;
  tip.hidden = false;
  const half = tip.offsetWidth / 2;
  tip.style.left = `${Math.min(chart.width - half, Math.max(half, px))}px`;
  tip.style.top = `${top + chart.H / 2 + tip.offsetHeight / 2}px`;
}

function unhover() {
  state.hoverX = null;
  $("#chart-hover")?.setAttribute("visibility", "hidden");
  $("#chart-tip").hidden = true;
}

function setUpChart() {
  const chart = $("#chart");
  const move = (event) => hover(event.clientX - $("#chart-svg").getBoundingClientRect().left);
  chart.addEventListener("pointerdown", move);
  chart.addEventListener("pointermove", move);
  chart.addEventListener("pointerleave", unhover);
  chart.addEventListener("pointercancel", unhover);
  chart.addEventListener("pointerup", (event) => { if (event.pointerType !== "mouse") unhover(); });
  for (const button of document.querySelectorAll("[data-range]")) {
    button.addEventListener("click", () => {
      state.range = button.dataset.range;
      localStorage.setItem(RANGE_KEY, state.range);
      renderHistory();
    });
  }
  addEventListener("resize", () => { if (!$("#dashboard").hidden) renderHistory(); });
}

// MARK: Raw values

/// Fields that look like running energy totals or pack capacity: what usage history needs.
const ENERGY = /chg|dsg|cap|cycle|energy|kwh/i;

async function showRaw() {
  stop();
  show("raw");
  $("#raw-error").hidden = true;
  $("#raw-since").textContent = "Loading…";
  try {
    state.raw = await state.source.quotas();
  } catch (error) {
    $("#raw-error").textContent = error.message;
    $("#raw-error").hidden = false;
    return;
  }
  let baseline = null;
  try { baseline = JSON.parse(localStorage.getItem(BASELINE_KEY)); } catch {}
  if (!baseline) resetBaseline();
  else renderRaw(baseline);
}

function resetBaseline() {
  if (!state.raw) return;
  const baseline = { time: Date.now(), values: state.raw };
  localStorage.setItem(BASELINE_KEY, JSON.stringify(baseline));
  renderRaw(baseline);
}

function renderRaw(baseline) {
  const minutes = Math.floor((Date.now() - baseline.time) / 60000);
  const at = new Date(baseline.time).toLocaleString([], { weekday: "short", hour: "numeric", minute: "2-digit" });
  $("#raw-since").textContent = minutes < 1 ? "Baseline saved just now"
    : `Changes since ${at} (${duration(minutes)} ago)`;

  const row = (key) => {
    const value = state.raw[key], before = baseline.values[key];
    const el = document.createElement("div");
    el.className = "kv";
    el.innerHTML = '<span class="k"></span><span class="delta"></span><span class="v"></span>';
    el.querySelector(".k").textContent = key;
    el.querySelector(".v").textContent = String(value);
    const change = before === undefined ? null : +(value - before).toFixed(3);
    if (change) {
      el.querySelector(".delta").textContent = change > 0 ? `+${change}` : String(change);
      el.querySelector(".delta").classList.toggle("down", change < 0);
    }
    return el;
  };
  const keys = Object.keys(state.raw).sort();
  $("#raw-energy").replaceChildren(...keys.filter((k) => ENERGY.test(k)).map(row));
  $("#raw-rest").replaceChildren(...keys.filter((k) => !ENERGY.test(k)).map(row));
}

async function copyRaw() {
  let baseline = null;
  try { baseline = JSON.parse(localStorage.getItem(BASELINE_KEY)); } catch {}
  const text = JSON.stringify({ now: { time: Date.now(), values: state.raw }, baseline }, null, 1);
  try {
    await navigator.clipboard.writeText(text);
    $("#raw-copy").textContent = "Copied";
    setTimeout(() => { $("#raw-copy").textContent = "Copy"; }, 1500);
  } catch {
    $("#raw-error").textContent = "Couldn't copy to the clipboard.";
    $("#raw-error").hidden = false;
  }
}

function hideRaw() {
  show("dashboard");
  schedule(0);
}

// MARK: Pull to refresh

function setUpPullToRefresh() {
  const dashboard = $("#dashboard"), content = dashboard.querySelector(".content"), indicator = $("#pull");
  const threshold = 70;
  let startY = null, distance = 0;

  dashboard.addEventListener("touchstart", (event) => {
    // The landscape chart fills the screen and doesn't scroll, so there's nothing to pull down.
    startY = window.scrollY <= 0 && !landscape.matches ? event.touches[0].clientY : null;
    distance = 0;
  }, { passive: true });
  dashboard.addEventListener("touchmove", (event) => {
    if (startY === null) return;
    distance = Math.max(0, event.touches[0].clientY - startY);
    dashboard.classList.add("pulling");
    content.style.transform = `translateY(${Math.min(distance / 2.5, threshold)}px)`;
    indicator.classList.toggle("show", distance / 2.5 >= threshold * 0.6);
  }, { passive: true });
  dashboard.addEventListener("touchend", async () => {
    if (startY === null) return;
    dashboard.classList.remove("pulling");
    const pulled = distance / 2.5 >= threshold * 0.6;
    startY = null;
    if (!pulled) {
      content.style.transform = "";
      return;
    }
    content.style.transform = "translateY(40px)";
    stop();
    await refresh();
    schedule();
    content.style.transform = "";
    indicator.classList.remove("show");
  });
}

// MARK: Start

$("#setup-form").addEventListener("submit", connect);
$("#retry").addEventListener("click", launch);
$("#change-keys").addEventListener("click", showSetup);
$("#settings").addEventListener("click", showSetup);
$("#setup-cancel").addEventListener("click", launch);
$("#disconnect").addEventListener("click", disconnect);
$("#show-raw").addEventListener("click", showRaw);
$("#raw-back").addEventListener("click", hideRaw);
$("#raw-reset").addEventListener("click", resetBaseline);
$("#raw-copy").addEventListener("click", copyRaw);
$("#demo-badge").hidden = !demo;
for (const row of document.querySelectorAll("[data-output]")) {
  row.querySelector(".tog").addEventListener("click", () => toggle(row));
}
setUpPullToRefresh();
setUpChart();
launch();
