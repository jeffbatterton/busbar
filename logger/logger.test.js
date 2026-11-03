import assert from "node:assert/strict";
import { test } from "node:test";
import { handle, record } from "./src/index.js";

/// Just enough of D1 for the logger: a readings table kept in memory.
function fakeDB() {
  const rows = [];
  const statement = (sql, args = []) => ({
    bind: (...values) => statement(sql, values),
    async first() {
      return [...rows].sort((a, b) => b.t - a.t)[0] ?? null;
    },
    async all() {
      const [since, until] = args;
      return { results: rows.filter((r) => r.t >= since && r.t < until).sort((a, b) => a.t - b.t) };
    },
    async run() {
      if (sql.startsWith("DELETE")) rows.splice(0, rows.length, ...rows.filter((r) => !r.simulated));
      else {
        const [t, soc, watts_in, watts_out, simulated] = args;
        rows.push({ t, soc, watts_in, watts_out, simulated });
      }
    },
  });
  return { rows, prepare: (sql) => statement(sql), batch: (list) => Promise.all(list.map((s) => s.run())) };
}

const read = (env, query, token = "secret") =>
  handle(new Request(`https://logger.test/readings?${query}`, { headers: { Authorization: `Bearer ${token}` } }), env);

test("records simulated readings that carry on from the last one", async () => {
  const env = { DB: fakeDB() };
  await record(env, new Date(2026, 10, 3, 2, 0));
  await record(env, new Date(2026, 10, 3, 2, 1));
  assert.equal(env.DB.rows.length, 2);
  assert.ok(env.DB.rows.every((r) => r.simulated === 1));
  // At 2 AM there's no sun, so a minute later the charge has gone down a little.
  assert.ok(env.DB.rows[1].soc <= env.DB.rows[0].soc);
  assert.ok(env.DB.rows[0].soc - env.DB.rows[1].soc < 1);
});

test("answers readings in a range, oldest first", async () => {
  const env = { DB: fakeDB(), READ_TOKEN: "secret" };
  env.DB.rows.push({ t: 3000, soc: 70, watts_in: 0, watts_out: 200, simulated: 0 },
    { t: 1000, soc: 72, watts_in: 500, watts_out: 200, simulated: 0 },
    { t: 9000, soc: 60, watts_in: 0, watts_out: 200, simulated: 0 });
  const response = await read(env, "since=0&until=5000");
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Access-Control-Allow-Origin"), "*");
  assert.deepEqual(await response.json(), {
    simulated: false,
    readings: [[1000, 72, 500, 200], [3000, 70, 0, 200]],
  });
});

test("refuses a wrong token, a missing token and oversized ranges", async () => {
  const env = { DB: fakeDB(), READ_TOKEN: "secret" };
  assert.equal((await read(env, "since=0&until=5000", "nope")).status, 401);
  assert.equal((await read({ DB: fakeDB() }, "since=0&until=5000")).status, 401);
  assert.equal((await read(env, `since=0&until=${9 * 24 * 3600 * 1000}`)).status, 400);
  assert.equal((await read(env, "until=5000")).status, 400);
});
