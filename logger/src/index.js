// Records the Delta Pro's charge every minute so the apps can chart history, even while
// the Mac is asleep or the phone app is closed. Shares its EcoFlow code with the web app.

import { DeltaProSource, SimulatedSource, parseDeltaPro } from "../../web/ecoflow.js";

/// The most a single request can ask for: a calendar week plus a day of slack.
const MAX_RANGE_MS = 8 * 24 * 3600 * 1000;
/// Alert thresholds, in percent, until the Mac app sends its own.
const DEFAULT_SETTINGS = { lowThreshold: 30, criticalThreshold: 15 };

export default {
  async scheduled(controller, env) {
    await record(env, new Date(controller.scheduledTime));
  },

  fetch(request, env) {
    return handle(request, env);
  },
};

/// Takes one reading and stores it. Without EcoFlow keys it records simulated data,
/// marked as such, so the charts can be built before developer access comes through.
export async function record(env, now) {
  const simulated = !env.ECOFLOW_ACCESS_KEY;
  let s;
  if (simulated) {
    // Workers don't keep state between runs, so carry the simulation on from the last row.
    const last = await env.DB.prepare("SELECT t, soc FROM readings ORDER BY t DESC LIMIT 1").first();
    const source = Object.assign(new SimulatedSource(), { timeScale: 1 });
    if (last) Object.assign(source, { soc: last.soc, lastTick: new Date(last.t) });
    s = parseDeltaPro(source.quotas(now), now);
  } else {
    s = await new DeltaProSource({
      accessKey: env.ECOFLOW_ACCESS_KEY,
      secretKey: env.ECOFLOW_SECRET_KEY,
      serialNumber: env.ECOFLOW_SERIAL_NUMBER,
    }).snapshot();
  }

  const statements = [];
  // The first real reading clears out the simulated ones.
  if (!simulated) statements.push(env.DB.prepare("DELETE FROM readings WHERE simulated = 1"));
  statements.push(env.DB.prepare(
    "INSERT OR REPLACE INTO readings (t, soc, watts_in, watts_out, simulated) VALUES (?, ?, ?, ?, ?)",
  ).bind(now.getTime(), Math.round(s.stateOfCharge * 10) / 10, s.wattsIn, s.wattsOut, simulated ? 1 : 0));
  await env.DB.batch(statements);
}

/// `GET /readings?since=<ms>[&until=<ms>]` answers `{ readings: [[t, soc, wattsIn, wattsOut], …] }`.
/// `GET /settings` answers `{ lowThreshold, criticalThreshold }`; the Mac app `PUT`s them.
export async function handle(request, env) {
  const cors = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Authorization",
    "Access-Control-Allow-Methods": "GET",
  };
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });

  const json = (body, status = 200) => Response.json(body, { status, headers: cors });
  const url = new URL(request.url);
  const route = `${request.method} ${url.pathname}`;
  if (!["GET /readings", "GET /settings", "PUT /settings"].includes(route)) return json({ error: "Not found" }, 404);
  if (!env.READ_TOKEN || request.headers.get("Authorization") !== `Bearer ${env.READ_TOKEN}`) {
    return json({ error: "Unauthorized" }, 401);
  }
  if (route === "GET /settings") return json(await settings(env));
  if (route === "PUT /settings") {
    const body = await request.json().catch(() => null);
    const { lowThreshold: low, criticalThreshold: critical } = body ?? {};
    const valid = [low, critical].every((n) => typeof n === "number" && n >= 0 && n <= 100) && critical < low;
    if (!valid) return json({ error: "lowThreshold and criticalThreshold must be percentages, critical below low" }, 400);
    const put = env.DB.prepare("INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)");
    await env.DB.batch([put.bind("lowThreshold", low), put.bind("criticalThreshold", critical)]);
    return json(await settings(env));
  }

  const until = Number(url.searchParams.get("until") ?? Date.now());
  const since = Number(url.searchParams.get("since") ?? NaN);
  if (!Number.isFinite(since) || !Number.isFinite(until) || since >= until) {
    return json({ error: "since must be a time in milliseconds, before until" }, 400);
  }
  if (until - since > MAX_RANGE_MS) return json({ error: "At most 8 days per request" }, 400);

  const { results } = await env.DB.prepare(
    "SELECT t, soc, watts_in, watts_out, simulated FROM readings WHERE t >= ? AND t < ? ORDER BY t",
  ).bind(since, until).all();
  return json({
    simulated: results.some((r) => r.simulated === 1),
    readings: results.map((r) => [r.t, r.soc, r.watts_in, r.watts_out]),
  });
}

async function settings(env) {
  const { results } = await env.DB.prepare("SELECT key, value FROM settings").all();
  return { ...DEFAULT_SETTINGS, ...Object.fromEntries(results.map((r) => [r.key, r.value])) };
}
