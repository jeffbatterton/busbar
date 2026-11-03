import { DeltaProSource, SimulatedSource, flow, isOn, withOutput, restoreOutput } from "./ecoflow.js";

/// Polls while the app is open. It pauses in the background and refreshes on return.
const POLL_SECONDS = 15;
/// Readings older than this show as stale, matching the Mac app's default.
const STALE_MINUTES = 10;
const LOW = 30, CRITICAL = 15;
const STORAGE_KEY = "busbar.credentials";

const $ = (selector) => document.querySelector(selector);
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
};

// MARK: Screens

function show(screen) {
  for (const id of ["launch", "setup", "dashboard"]) $(`#${id}`).hidden = id !== screen;
}

function savedCredentials() {
  try {
    const saved = JSON.parse(localStorage.getItem(STORAGE_KEY));
    return saved?.accessKey && saved?.secretKey && saved?.serialNumber ? saved : null;
  } catch {
    return null;
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
  $("#setup-error").hidden = true;
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
    Object.assign(state, { source, lastUpdate: new Date(), error: null });
    render();
    show("dashboard");
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
  Object.assign(state, { source: null, snapshot: null, lastUpdate: null, error: null });
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
  const level = soc <= CRITICAL ? "#ff453a" : soc <= LOW ? "#ffd60a" : "var(--good)";
  $("#bar-fill").style.width = `${Math.min(100, Math.max(0, s.stateOfCharge))}%`;
  $("#bar-fill").style.setProperty("--level", level);

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

// MARK: Pull to refresh

function setUpPullToRefresh() {
  const dashboard = $("#dashboard"), content = dashboard.querySelector(".content"), indicator = $("#pull");
  const threshold = 70;
  let startY = null, distance = 0;

  dashboard.addEventListener("touchstart", (event) => {
    startY = window.scrollY <= 0 ? event.touches[0].clientY : null;
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
$("#disconnect").addEventListener("click", disconnect);
$("#demo-badge").hidden = !demo;
for (const row of document.querySelectorAll("[data-output]")) {
  row.querySelector(".tog").addEventListener("click", () => toggle(row));
}
setUpPullToRefresh();
launch();
