/**
 * Tests for the counsel layer.
 *
 * These are offline by default — they check the prompt-building, which is where
 * the behaviour actually lives, without spending tokens or needing a key.
 *
 * Run the live check too with:  node src/counsel.test.mjs --live
 */
import assert from "node:assert/strict";
import { describeReading, createCounsellor, MODEL_CHAIN } from "./counsel.mjs";

// --- an inconclusive read must not let the model invent a state -------------
{
  const text = describeReading({ composure: null, verdict: "inconclusive", signals: {} });
  assert.match(text, /did NOT produce a confident reading/);
  assert.match(text, /do not describe their state as if it were measured/i);
  // It must not claim a score it does not have.
  assert.doesNotMatch(text, /Composure score/);
  console.log("inconclusive  -> refuses to assert a state");
}

// --- a real read passes the numbers through ---------------------------------
{
  const text = describeReading({
    composure: 19,
    verdict: "red",
    signals: { pulseRate: 104.4, breathingRate: 24.2, rmssd: 17.1, stressIndex: 520.9 },
    reasons: ["heart-rate variability is suppressed"],
  });
  assert.match(text, /Composure score: 19 out of 100/);
  assert.match(text, /holding the decision back/);
  assert.match(text, /Pulse: 104 bpm/);
  assert.match(text, /Breathing rate: 24/);
  assert.match(text, /RMSSD\): 17 ms/);
  assert.match(text, /Baevsky stress index: 521/);
  assert.match(text, /heart-rate variability is suppressed/);
  console.log("red read      -> passes real numbers through");
}

// --- each verdict gets its own framing --------------------------------------
{
  const green = describeReading({ composure: 88, verdict: "green", signals: {} });
  assert.match(green, /calm enough that the app would release/);
  const amber = describeReading({ composure: 55, verdict: "amber", signals: {} });
  assert.match(amber, /borderline/);
  console.log("verdicts      -> framed distinctly");
}

// --- missing and malformed input must not throw -----------------------------
{
  for (const input of [undefined, null, {}, "nonsense", 42, { signals: null }]) {
    assert.doesNotThrow(() => describeReading(input), `threw on ${JSON.stringify(input)}`);
  }
  // Absent signals simply do not appear, rather than printing "undefined".
  const sparse = describeReading({ composure: 70, verdict: "green", signals: {} });
  assert.doesNotMatch(sparse, /undefined|NaN|null/);
  console.log("bad input     -> no throw, no undefined leaking into the prompt");
}

// --- no key means disabled, not a crash ------------------------------------
{
  const { counsellor, reason } = createCounsellor({ apiKey: undefined });
  assert.equal(counsellor, null);
  assert.match(reason, /GEMINI_API_KEY/);
  console.log("no key        -> disabled cleanly:", reason);
}

// --- a key produces a usable counsellor ------------------------------------
{
  const { counsellor, reason } = createCounsellor({ apiKey: "test-key" });
  assert.equal(reason, null);
  assert.ok(counsellor);
  assert.deepEqual(counsellor.models, MODEL_CHAIN);
  assert.ok(MODEL_CHAIN.length > 1, "there must be fallbacks — models get retired and overloaded");
  console.log("with key      -> ready, with", MODEL_CHAIN.length, "models in the chain");
}

// --- live check (opt-in) ----------------------------------------------------
if (process.argv.includes("--live")) {
  const { counsellor, reason } = createCounsellor();
  if (!counsellor) {
    console.log("\n[live] skipped:", reason);
  } else {
    const { reply, model } = await counsellor.counsel({
      reading: {
        composure: 19,
        verdict: "red",
        signals: { pulseRate: 104, breathingRate: 24, rmssd: 17, stressIndex: 520 },
        reasons: ["heart-rate variability is suppressed"],
      },
      messages: [],
    });
    assert.ok(reply.length > 10, "a real reply should say something");
    // The opening turn's job is to ask what decision is being faced.
    assert.match(reply, /\?/, "the opening turn should ask a question");
    console.log(`\n[live] ${model} replied:\n${reply}`);
  }
}

console.log("\nall counsel tests passed");
