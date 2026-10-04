/**
 * Smoke tests for the composure heuristic. Run: node src/composure.test.mjs
 *
 * These assert the *properties* that matter for a gate, not exact scores -
 * the weights are meant to be tuned, and brittle snapshots would block that.
 */
import assert from "node:assert/strict";
import { composure } from "./composure.mjs";

// Presage reports confidence as a PERCENTAGE in [0,100], not a fraction.
const CONF = { hrvConfidence: 90, pulseConfidence: 90, breathingConfidence: 90 };

const calm = {
  ...CONF,
  stressIndex: 90, rmssd: 65, pulseRate: 64, breathingRate: 13,
  expression: { neutral: 0.85, anger: 0.02 },
};

const agitated = {
  ...CONF,
  stressIndex: 520, rmssd: 17, pulseRate: 104, breathingRate: 24,
  expression: { anger: 0.6, neutral: 0.2 },
};

const results = {};
for (const [name, signals] of Object.entries({ calm, agitated })) {
  results[name] = composure(signals);
  console.log(name.padEnd(9), JSON.stringify(results[name]));
}

assert.equal(results.calm.verdict, "green", "a calm reading should open the vault");
assert.equal(results.agitated.verdict, "red", "an agitated reading should keep it shut");
assert.ok(results.calm.composure > results.agitated.composure);
assert.ok(results.agitated.reasons.length > 0, "a refusal must explain itself");

// FAIL CLOSED: one lonely signal is not enough to judge.
const sparse = composure({ pulseRate: 70, pulseConfidence: 90 });
console.log("sparse   ", JSON.stringify(sparse));
assert.equal(sparse.verdict, "inconclusive");
assert.equal(sparse.composure, null);

// FAIL CLOSED: a perfect-looking reading with no confidence is still not green.
const noConfidence = composure({
  stressIndex: 90, rmssd: 65, pulseRate: 64, breathingRate: 13,
  hrvConfidence: 0, pulseConfidence: 0, breathingConfidence: 0,
});
console.log("unsure   ", JSON.stringify(noConfidence));
assert.notEqual(noConfidence.verdict, "green", "low confidence must never open the vault");

// Empty input must not throw and must not pass.
const empty = composure({});
assert.equal(empty.verdict, "inconclusive");
assert.equal(composure().verdict, "inconclusive");

// A stricter blueprint must never be easier to satisfy than a lenient one.
// Self-calibrating: set the bar just above whatever this reading actually scored,
// so the test does not bake in today's weights.
const RANK = { red: 0, amber: 1, green: 2, inconclusive: -1 };
const warm = {
  ...CONF,
  stressIndex: 260, rmssd: 38, pulseRate: 86, breathingRate: 18,
  expression: { neutral: 0.5, fear: 0.2 },
};
const lenient = composure(warm, { green: 50, amber: 25 });
console.log("warm     ", JSON.stringify(lenient));

const justAbove = composure(warm, { green: lenient.composure + 1, amber: 0 });
assert.notEqual(justAbove.verdict, "green", "raising the bar above the score must not stay green");
assert.ok(
  RANK[composure(warm, { green: 90, amber: 70 }).verdict] <= RANK[lenient.verdict],
  "a stricter blueprint must not yield a better verdict than a lenient one",
);

// Expression payload shape variants must all be tolerated.
for (const shape of [
  { label: "anger", probability: 0.9 },
  { name: "neutral", score: 0.8 },
  { anger: 0.7, neutral: 0.1 },
  {}, null, undefined, "nonsense",
]) {
  assert.doesNotThrow(() => composure({ ...calm, expression: shape }));
}

console.log("\nall composure tests passed");

// --- regression: real readings must actually produce a verdict ---------------
// These are signal sets recorded from genuine Presage measurements (read back
// out of Firestore). Every one of them scored `inconclusive` with a null
// composure, because the two HRV-derived signals carried half the weight and
// Presage frequently reports HRV confidence as ZERO - so coverage peaked at
// 0.35 against a 0.5 floor and no reading could ever land.
//
// The scores here are not asserted exactly; only that a verdict exists at all.
const REAL_READINGS = [
  { pulseRate: 71.49, breathingRate: 17.91, rmssd: 70.67, stressIndex: 0.646 },
  { pulseRate: 67.42, breathingRate: 18.60, rmssd: 51.11, stressIndex: 1.111 },
  { pulseRate: 67.82, breathingRate: 16.36, rmssd: 31.54, stressIndex: 1.225 },
  { pulseRate: 79.10, breathingRate: 20.20 }, // HRV never arrived
];

for (const signals of REAL_READINGS) {
  const withConfidence = {
    ...signals,
    pulseConfidence: 90,
    breathingConfidence: 90,
    hrvConfidence: signals.rmssd ? 90 : 0,
  };
  const r = composure(withConfidence);
  assert.notEqual(r.verdict, "inconclusive",
    `a real reading must produce a verdict: ${JSON.stringify(signals)}`);
  assert.ok(Number.isFinite(r.composure), "a real reading must produce a score");
}
console.log(`real data  -> all ${REAL_READINGS.length} recorded readings produce a verdict`);

// Pulse + breathing alone must clear the coverage floor. If a future reweighting
// breaks this, every HRV-less measurement silently becomes inconclusive again.
const pulseAndBreathOnly = composure({
  pulseRate: 68, breathingRate: 14, pulseConfidence: 90, breathingConfidence: 90,
});
assert.notEqual(pulseAndBreathOnly.verdict, "inconclusive",
  "pulse + breathing alone must be enough to land a reading");

// Presage's unitless Baevsky (~0.6-1.2) must map onto the classical band, not
// be read as "perfectly calm" because 1.2 is far below 150.
const calmSi = composure({ ...CONF, pulseRate: 64, breathingRate: 13, rmssd: 65, stressIndex: 0.8 });
const highSi = composure({ ...CONF, pulseRate: 64, breathingRate: 13, rmssd: 65, stressIndex: 5.0 });
assert.ok(calmSi.composure > highSi.composure,
  "a high stress index must score worse than a low one after scaling");
console.log(`stress idx -> 0.8 scores ${calmSi.composure}, 5.0 scores ${highSi.composure}`);
