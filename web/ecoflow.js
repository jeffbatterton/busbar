// EcoFlow's IoT Open Platform API and Delta Pro parsing, ported from BusbarCore.
// The API allows cross-origin calls, so the browser talks to EcoFlow directly.

const HOST = "https://api.ecoflow.com";

export class EcoFlowError extends Error {}

/// EcoFlow signs requests with HMAC-SHA256 over the request params sorted by key,
/// followed by `accessKey`, `nonce` and `timestamp`.
export async function signature(params, accessKey, secretKey, nonce, timestamp) {
  const parts = Object.keys(params).sort().map((key) => `${key}=${params[key]}`);
  parts.push(`accessKey=${accessKey}`, `nonce=${nonce}`, `timestamp=${timestamp}`);
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", encoder.encode(secretKey),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, encoder.encode(parts.join("&")));
  return [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export class EcoFlowClient {
  constructor({ accessKey, secretKey, serialNumber }) {
    Object.assign(this, { accessKey, secretKey, serialNumber });
  }

  /// All current quota values for the device, as numbers.
  async allQuotas() {
    const data = await this.#get("/iot-open/sign/device/quota/all", { sn: this.serialNumber });
    if (!data || typeof data !== "object") throw new EcoFlowError("Unexpected response from EcoFlow");
    const quotas = {};
    for (const [key, raw] of Object.entries(data)) {
      const value = typeof raw === "number" ? raw : typeof raw === "string" ? Number(raw) : NaN;
      if (raw !== "" && !Number.isNaN(value)) quotas[key] = value;
    }
    return quotas;
  }

  /// Sends a set command, e.g. `{ id: 66, enabled: 1 }`.
  async setQuota(params) {
    const body = { sn: this.serialNumber, operateType: "TCP", params };
    // Nested params are signed flattened, as `params.id=66`.
    const signed = { sn: this.serialNumber, operateType: "TCP" };
    for (const [key, value] of Object.entries(params)) signed[`params.${key}`] = String(value);
    await this.#send("/iot-open/sign/device/quota", signed, {
      method: "PUT",
      headers: { "Content-Type": "application/json;charset=UTF-8" },
      body: JSON.stringify(body),
    });
  }

  #get(path, query) {
    const search = Object.keys(query).sort().map((k) => `${k}=${encodeURIComponent(query[k])}`).join("&");
    return this.#send(search ? `${path}?${search}` : path, query, {});
  }

  async #send(path, params, init) {
    const nonce = String(100000 + Math.floor(Math.random() * 900000));
    const timestamp = String(Date.now());
    const sign = await signature(params, this.accessKey, this.secretKey, nonce, timestamp);
    const headers = { ...init.headers, accessKey: this.accessKey, nonce, timestamp, sign };
    const response = await fetch(HOST + path, { ...init, headers, signal: AbortSignal.timeout(20000) });
    if (!response.ok) throw new EcoFlowError(`EcoFlow returned HTTP ${response.status}`);
    const envelope = await response.json().catch(() => null);
    if (!envelope) throw new EcoFlowError("Unexpected response from EcoFlow");
    if (String(envelope.code) !== "0") {
      throw new EcoFlowError(`EcoFlow error ${envelope.code}: ${envelope.message ?? "Unknown error"}`);
    }
    return envelope.data;
  }
}

/// Delta Pro command ids: 66 is AC discharge, 81 the 12V car port.
const OUTPUT_IDS = { ac: 66, dc12V: 81 };

export class DeltaProSource {
  constructor(credentials) {
    this.client = new EcoFlowClient(credentials);
  }

  async snapshot() {
    return parseDeltaPro(await this.client.allQuotas());
  }

  quotas() {
    return this.client.allQuotas();
  }

  setOutput(output, on) {
    return this.client.setQuota({ id: OUTPUT_IDS[output], enabled: on ? 1 : 0 });
  }
}

/// Interprets Delta Pro quotas. Field names come from EcoFlow's Delta Pro developer
/// docs; `bmsSlave1.*` is undocumented but reported by real units.
export function parseDeltaPro(q, timestamp = new Date()) {
  const int = (key) => (q[key] === undefined ? undefined : Math.trunc(q[key]));
  // The mppt.*Watts fields are in tenths of a watt; the rest are whole watts.
  const mpptWatts = (key) => (q[key] === undefined ? undefined : Math.round(q[key] / 10));

  const stateOfCharge = q["ems.f32LcdShowSoc"] ?? q["ems.lcdShowSoc"] ?? q["pd.soc"] ?? 0;
  const wattsInSum = int("pd.wattsInSum") ?? 0;
  let wattsOut = int("pd.wattsOutSum") ?? 0;

  // The XT60 port is solar unless it's detected as a DC adapter.
  const solarWatts = int("mppt.xt60ChgType") === 2 ? 0 : (mpptWatts("mppt.inWatts") ?? 0);
  const acInWatts = int("inv.inputWatts") ?? 0;
  // The extra battery discharging into the Delta Pro is counted in wattsInSum.
  const extraBatteryWatts = int("bmsSlave1.outputWatts") ?? 0;
  const transfer = extraBatteryWatts - (int("bmsSlave1.inputWatts") ?? 0);
  const packTransferWatts = Math.abs(transfer) < 10 ? 0 : transfer;
  const unexplained = wattsInSum - solarWatts - acInWatts - extraBatteryWatts;
  // Separately measured readings rarely match, and the extra battery's lags a little;
  // under 25 W left over is noise (the alternator charger runs in the hundreds).
  const otherInWatts = unexplained < 25 ? 0 : unexplained;

  const acOutWatts = int("inv.outputWatts") ?? 0;
  const dc12VOutWatts = (int("pd.carWatts") ?? 0) + (mpptWatts("mppt.dcdc12vWatts") ?? 0);
  // Prefer the switch states; fall back to "drawing power" if they aren't reported.
  const acOutputOn = int("inv.cfgAcEnabled") === 1 || acOutWatts > 0;
  // The 12V car port's switch is mppt.carState; pd.carState stays 0 on real units.
  const dc12VOutputOn = q["mppt.carState"] !== undefined ? int("mppt.carState") === 1 : dc12VOutWatts > 0;

  // EcoFlow reports 5999 (or larger) when it can't estimate; treat that as unknown.
  const plausibleMinutes = (key) => {
    const m = int(key);
    return m > 0 && m < 5999 ? m : null;
  };

  // ems.bmsNOnline bit 0 is the pack's hardware-online signal.
  const batteries = [{
    name: "Main",
    stateOfCharge: q["bmsMaster.f32ShowSoc"] ?? q["bmsMaster.soc"] ?? null,
    temperature: q["bmsMaster.temp"] ?? null,
    isAvailable: q["ems.bms0Online"] === undefined ? true : (int("ems.bms0Online") & 1) === 1,
  }];
  const extraSOC = q["bmsSlave1.f32ShowSoc"] ?? q["bmsSlave1.soc"];
  // Listed whenever the Delta Pro reports on the extra battery port, so a
  // disconnected pack shows as unavailable rather than disappearing.
  if (q["ems.bms1Online"] !== undefined || q["pd.ext4p8Port"] !== undefined || extraSOC !== undefined) {
    const online = ((int("ems.bms1Online") ?? 0) & 1) === 1 || (int("pd.ext4p8Port") ?? 0) !== 0
      || extraSOC !== undefined;
    batteries.push({
      name: "Extra",
      stateOfCharge: online ? extraSOC ?? null : null,
      temperature: online ? q["bmsSlave1.temp"] ?? null : null,
      isAvailable: online,
    });
  }

  const warnings = [];
  const warningState = int("ems.bmsWarningState") ?? 0;
  if (int("pd.iconOverloadState") === 1 || warningState & 0b100) warnings.push("Overload");
  if (int("pd.iconHiTempState") === 1 || warningState & 0b001) warnings.push("High temperature");
  if (int("pd.iconLowTempState") === 1 || warningState & 0b010) warnings.push("Low temperature");
  for (const [key, label] of [["pd.errCode", "System"], ["inv.errCode", "Inverter"],
    ["mppt.faultCode", "Solar/DC"], ["bmsMaster.errCode", "Battery"], ["bmsMaster.bmsFault", "Battery permanent"]]) {
    const code = int(key);
    if (code) warnings.push(`${label} fault (${code})`);
  }

  return {
    stateOfCharge,
    wattsIn: solarWatts + acInWatts + otherInWatts,
    wattsOut,
    solarWatts, acInWatts, otherInWatts, packTransferWatts,
    acOutWatts, dc12VOutWatts, acOutputOn, dc12VOutputOn,
    // inv.acInVol is in millivolts; anything over ~80 V means shore power is present.
    shorePowerConnected: (q["inv.acInVol"] ?? 0) > 80000,
    minutesToFull: plausibleMinutes("ems.chgRemainTime"),
    minutesToEmpty: plausibleMinutes("ems.dsgRemainTime"),
    batteries,
    warnings,
    timestamp,
  };
}

export function flow(s) {
  const net = s.wattsIn - s.wattsOut;
  return net > 5 ? "charging" : net < -5 ? "discharging" : "idle";
}

const OUTPUT_FIELDS = { ac: ["acOutputOn", "acOutWatts"], dc12V: ["dc12VOutputOn", "dc12VOutWatts"] };

export function isOn(s, output) {
  return s[OUTPUT_FIELDS[output][0]];
}

/// A copy with an output switched. Switching off also drops its draw from the totals,
/// since a switched-off output can't be using power.
export function withOutput(s, output, on) {
  const [onKey, wattsKey] = OUTPUT_FIELDS[output];
  const next = { ...s, [onKey]: on };
  if (!on) Object.assign(next, { wattsOut: s.wattsOut - s[wattsKey], [wattsKey]: 0 });
  return next;
}

/// A copy with an output's switch and draw put back as they were in `earlier`.
export function restoreOutput(s, output, earlier) {
  const [onKey, wattsKey] = OUTPUT_FIELDS[output];
  return { ...s, [onKey]: earlier[onKey], [wattsKey]: earlier[wattsKey],
    wattsOut: s.wattsOut + earlier[wattsKey] - s[wattsKey] };
}

/// Fake Delta Pro data for trying the app without keys (open it with `?demo`). It emits
/// raw quotas with the real field names, so parsing is exercised too. Solar follows the
/// time of day, with the extra battery feeding the main.
export class SimulatedSource {
  soc = 78;
  acOn = true;
  dc12VOn = true;
  lastTick = null;
  capacityWh = 7200;
  timeScale = 10;

  async snapshot() {
    return parseDeltaPro(this.quotas());
  }

  async setOutput(output, on) {
    await new Promise((resolve) => setTimeout(resolve, 600));
    if (output === "ac") this.acOn = on;
    else this.dc12VOn = on;
  }

  quotas(now = new Date()) {
    const rand = (lo, hi) => lo + Math.random() * (hi - lo);
    const hour = now.getHours() + now.getMinutes() / 60;
    const daylight = Math.max(0, Math.sin(((hour - 6) / 14) * Math.PI));
    const solar = Math.trunc(1200 * daylight * rand(0.85, 1));
    const acOut = this.acOn ? 140 + Math.trunc(rand(-20, 30)) + (Math.random() < 0.1 ? 900 : 0) : 0;
    const dc12V = this.dc12VOn ? 45 + Math.trunc(rand(0, 15)) : 0;
    const wattsOut = acOut + dc12V;
    const solarIn = this.soc >= 100 ? 0 : solar;

    if (this.lastTick) {
      const hours = ((now - this.lastTick) / 3600000) * this.timeScale;
      this.soc = Math.min(100, Math.max(0, this.soc + ((solarIn - wattsOut) * hours) / this.capacityWh * 100));
    }
    this.lastTick = now;

    const net = solarIn - wattsOut;
    // The extra feeds the main while discharging; the main tops it up while charging.
    const toExtra = Math.trunc(net / 2);
    return {
      "ems.f32LcdShowSoc": this.soc,
      "bmsMaster.f32ShowSoc": Math.min(100, this.soc + 1.5),
      "bmsMaster.temp": 27,
      "ems.bms0Online": 3,
      "ems.bms1Online": 3,
      "pd.wattsInSum": solarIn + Math.max(0, -toExtra),
      "pd.wattsOutSum": wattsOut,
      "mppt.inWatts": solarIn * 10,
      "mppt.xt60ChgType": 1,
      "inv.inputWatts": 0,
      "inv.acInVol": 0,
      "inv.outputWatts": acOut,
      "inv.cfgAcEnabled": this.acOn ? 1 : 0,
      "mppt.carState": this.dc12VOn ? 1 : 0,
      "pd.carWatts": dc12V,
      "ems.chgRemainTime": net > 0 ? Math.trunc(((100 - this.soc) / 100) * this.capacityWh / net * 60) : 5999,
      "ems.dsgRemainTime": net < 0 ? Math.trunc((this.soc / 100) * this.capacityWh / -net * 60) : 5999,
      "bmsSlave1.f32ShowSoc": Math.max(0, this.soc - 1.5),
      "bmsSlave1.temp": 26,
      "bmsSlave1.outputWatts": Math.max(0, -toExtra),
      "bmsSlave1.inputWatts": Math.max(0, toExtra),
    };
  }
}
