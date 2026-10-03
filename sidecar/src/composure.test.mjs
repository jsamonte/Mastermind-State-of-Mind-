/**
 * Smoke tests for the composure heuristic. Run: node src/composure.test.mjs
 *
 * These assert the *properties* that matter for a gate, not exact scores -
 * the weights are meant to be tuned, and brittle snapshots would block that.
 */
import assert from "node:assert/strict";
import { composure } from "./composure.mjs";

const CONF = { hrvConfidence: 0.9, pulseConfidence: 0.9, breathingConfidence: 0.9 };

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
const sparse = composure({ pulseRate: 70, pulseConfidence: 0.9 });
console.log("sparse   ", JSON.stringify(sparse));
assert.equal(sparse.verdict, "inconclusive");
assert.equal(sparse.composure, null);

// FAIL CLOSED: a perfect-looking reading with no confidence is still not green.
const noConfidence = composure({
  stressIndex: 90, rmssd: 65, pulseRate: 64, breathingRate: 13,
  hrvConfidence: 0.1, pulseConfidence: 0.1, breathingConfidence: 0.1,
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
