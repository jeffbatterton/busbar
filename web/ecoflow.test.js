// Run with: node --test web/
import { test } from "node:test";
import assert from "node:assert/strict";
import { signature, parseDeltaPro, withOutput, restoreOutput } from "./ecoflow.js";

test("signature matches the reference implementation", async () => {
  // Reference: hmac.new(b"secret", b"sn=DCABZ123&accessKey=AK&nonce=345164&timestamp=1681872798000", sha256)
  const sign = await signature({ sn: "DCABZ123" }, "AK", "secret", "345164", "1681872798000");
  assert.equal(sign, "e7de08da82c96795a52fef3ca276328f80f0fd31c24a4e8e754d85abe45bd592");
});

test("set commands sign flattened params in key order", async () => {
  const sign = await signature({ sn: "DCABZ123", operateType: "TCP", "params.id": "81", "params.enabled": "0" },
    "AK", "secret", "345164", "1681872798000");
  assert.equal(sign, "bcf456d73671f0b391ec8aa52e17c1ba2a22bf8ddf5fea493e39963c95aae2e2");
});

test("the extra battery feeding the main is a transfer, not input", () => {
  const s = parseDeltaPro({ "pd.wattsInSum": 320, "mppt.inWatts": 1200, "bmsSlave1.outputWatts": 200,
    "bmsSlave1.f32ShowSoc": 80, "pd.wattsOutSum": 400 });
  assert.equal(s.solarWatts, 120);
  assert.equal(s.wattsIn, 120);
  assert.equal(s.packTransferWatts, 200);
  assert.equal(s.batteries.length, 2);
});

test("switching an output off drops its draw, and restoring puts it back", () => {
  const s = parseDeltaPro({ "pd.wattsOutSum": 400, "inv.outputWatts": 380, "inv.cfgAcEnabled": 1 });
  const off = withOutput(s, "ac", false);
  assert.equal(off.acOutputOn, false);
  assert.equal(off.wattsOut, 20);
  const back = restoreOutput(off, "ac", s);
  assert.equal(back.wattsOut, 400);
  assert.equal(back.acOutputOn, true);
});

test("reads the charge and discharge limits, ignoring crossed ones", () => {
  const s = parseDeltaPro({ "ems.minDsgSoc": 10, "ems.maxChargeSoc": 90 });
  assert.equal(s.dischargeLimit, 10);
  assert.equal(s.chargeLimit, 90);
  const unset = parseDeltaPro({});
  assert.equal(unset.dischargeLimit, 0);
  assert.equal(unset.chargeLimit, 100);
  const crossed = parseDeltaPro({ "ems.minDsgSoc": 60, "ems.maxChargeSoc": 50 });
  assert.equal(crossed.dischargeLimit, 0);
  assert.equal(crossed.chargeLimit, 100);
});
