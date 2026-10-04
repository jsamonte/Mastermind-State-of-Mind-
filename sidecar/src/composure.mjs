/**
 * composure.mjs - turns Presage physiological signals into one 0..100 score.
 *
 * This is a HEURISTIC. Nothing here is clinically validated, and the SmartSpectra
 * metrics themselves are wellness-grade, not FDA-cleared. The point of keeping it
 * in one small file with named constants is that it can be read, argued with, and
 * tuned - rather than looking authoritative while hiding its assumptions.
 *
 * Design rule: FAIL CLOSED. Missing or low-confidence data never produces GREEN.
 * A gate that opens when the sensor breaks is not a gate.
 */

/** Weights per signal. Only *available* signals are used; the rest are renormalized. */
/**
 * Weights per signal. Only *available* signals are used; the rest are renormalized.
 *
 * Rebalanced from real readings. The original split gave the two HRV-derived
 * signals half the total weight (stressIndex .28 + rmssd .22), which looked
 * principled — they are the most stress-shaped numbers Presage produces — but
 * made the whole score hostage to them. In practice Presage reports pulse and
 * breathing with usable confidence long before HRV, and often reports HRV
 * confidence as zero; HRV needs ~60s of clean signal where breathing needs ~30.
 * With HRV dropped, coverage reached only 0.35 against a 0.5 floor, so EVERY
 * real measurement came back inconclusive even while showing live vitals.
 *
 * Pulse + breathing alone now clear the floor (0.55), so a reading lands on the
 * signals that actually arrive. HRV still carries real weight when it shows up.
 */
export const WEIGHTS = {
  pulseRate: 0.30,
  breathingRate: 0.25,
  rmssd: 0.22,       // parasympathetic ("rest and digest") tone
  stressIndex: 0.18, // Baevsky SI
  expression: 0.03,  // only populated if faceMetrics is requested
  eda: 0.02,         // only populated if edaMetrics is requested
};

/**
 * Piecewise-linear ramp. Returns 1.0 at `good`, 0.0 at `bad`, linear between,
 * clamped outside. Works in either direction (good may be above or below bad).
 */
function ramp(x, good, bad) {
  if (!Number.isFinite(x)) return null;
  if (good === bad) return x === good ? 1 : 0;
  const t = (x - bad) / (good - bad);
  return Math.max(0, Math.min(1, t));
}

/** Score a value that is best inside a band, penalised on either side. */
function band(x, lo, hi, slackLo, slackHi) {
  if (!Number.isFinite(x)) return null;
  if (x >= lo && x <= hi) return 1;
  return x < lo ? ramp(x, lo, slackLo) : ramp(x, hi, slackHi);
}

/** Facial expressions that argue against "good state of mind". */
const NEGATIVE_EXPRESSIONS = new Set([
  "anger", "contempt", "disgust", "fear", "sadness",
]);
/** Surprise is arousing but not negative; neutral/happiness are fine. */
const NEUTRAL_EXPRESSIONS = new Set(["neutral", "happiness", "surprise"]);

/**
 * Reduce the SDK's expression payload to a 0..1 calm score.
 * The payload shape varies by SDK version, so this is defensive on purpose:
 * it accepts {label, probability}, {name, score}, or a flat map of name->prob.
 */
function scoreExpression(expression) {
  if (!expression || typeof expression !== "object") return null;

  // Flat probability map, e.g. { anger: 0.1, neutral: 0.7, ... }
  const entries = Object.entries(expression).filter(
    ([k, v]) => typeof v === "number" && (NEGATIVE_EXPRESSIONS.has(k) || NEUTRAL_EXPRESSIONS.has(k)),
  );
  if (entries.length) {
    let negative = 0;
    for (const [k, v] of entries) if (NEGATIVE_EXPRESSIONS.has(k)) negative += v;
    return Math.max(0, Math.min(1, 1 - negative));
  }

  // Single winning label.
  const label = String(expression.label ?? expression.name ?? expression.type ?? "").toLowerCase();
  if (!label) return null;
  const prob = Number(expression.probability ?? expression.score ?? expression.confidence ?? 1);
  if (NEGATIVE_EXPRESSIONS.has(label)) return Math.max(0, 1 - (Number.isFinite(prob) ? prob : 1));
  if (NEUTRAL_EXPRESSIONS.has(label)) return 1;
  return null;
}

/**
 * Score the EDA trace as relative arousal: a rising trace over the window means
 * climbing sympathetic arousal. Absolute EDA values are not comparable between
 * people or sessions, so only the *shape* is used.
 */
function scoreEda(trace) {
  if (!Array.isArray(trace) || trace.length < 8) return null;
  const vals = trace.map((s) => Number(s?.value ?? s)).filter(Number.isFinite);
  if (vals.length < 8) return null;

  const half = Math.floor(vals.length / 2);
  const mean = (a) => a.reduce((s, v) => s + v, 0) / a.length;
  const first = mean(vals.slice(0, half));
  const second = mean(vals.slice(half));
  const spread = Math.max(...vals) - Math.min(...vals);
  if (spread <= 0) return 1;

  // Normalised rise across the window: 0 means flat/falling, 1 a full-range climb.
  const rise = (second - first) / spread;
  return ramp(rise, 0, 0.6);
}

/**
 * Reference points. Each is a (calm, agitated) pair or a band with slack.
 * Tuned from commonly cited resting ranges for healthy adults - they are
 * starting points for calibration, not population truth.
 */
/**
 * Puts Presage's Baevsky value onto the classical scale.
 *
 * Presage reports it "without a unit, matching the HRV model card", and real
 * readings from this app come back as 0.6-1.2. The classical Stress Index
 * (AMo / (2 * Mo * MxDMn), with AMo as a percentage) puts resting adults at
 * roughly 50-150 — the same readings two orders of magnitude up. So Presage's
 * figure is the classical one with AMo as a fraction rather than a percent.
 *
 * Scaled by detection rather than assumption: anything below 10 is on Presage's
 * unitless scale, anything above is already classical. That way the reference
 * band stays meaningful if a future SDK changes the convention, instead of
 * silently scoring every reading as perfectly calm — which is what the
 * unscaled comparison did.
 */
function normaliseStressIndex(value) {
  return value < 10 ? value * 100 : value;
}

export const REFERENCE = {
  // Baevsky Stress Index, CLASSICAL scale. ~50-150 is typically called normal.
  // Inputs are put on this scale by normaliseStressIndex() above.
  stressIndex: { good: 150, bad: 600 },
  // RMSSD in ms - higher is calmer.
  rmssd: { good: 60, bad: 15 },
  // Resting pulse, beats/min.
  pulseRate: { lo: 55, hi: 78, slackLo: 42, slackHi: 108 },
  // Resting breathing, breaths/min.
  breathingRate: { lo: 10, hi: 16, slackLo: 6, slackHi: 26 },
};

/**
 * Minimum SDK-reported confidence before a signal counts.
 *
 * Presage reports confidence as a PERCENTAGE in [0, 100] — not a 0..1 fraction
 * (see docs/data-types: "expressed as a percentage in the range [0.0, 100.0]").
 * This was written as 0.5 on the assumption of a fraction, which made it a
 * 0.5% gate — i.e. no gate at all for anything non-zero. Kept deliberately
 * permissive on the correct scale: the weight system already de-rates a signal
 * by dropping it, and being stricter here mostly produces refusals.
 */
export const MIN_CONFIDENCE = 1; // percent
/** Signals must cover at least this much total weight, or the reading is inconclusive. */
export const MIN_WEIGHT_COVERAGE = 0.5;

const LABEL = {
  stressIndex: "stress index is elevated",
  rmssd: "heart-rate variability is suppressed",
  pulseRate: "pulse is outside your calm range",
  breathingRate: "breathing is outside your calm range",
  expression: "your face is reading tense",
  eda: "arousal is climbing through the measurement",
};

/**
 * @param {object} signals Flattened Presage readings - see smartspectra.mjs
 * @param {object} [thresholds] { green, amber } cutoffs, from the user's blueprint
 * @returns {{composure:number|null, verdict:string, parts:object, coverage:number, reasons:string[]}}
 */
export function composure(signals = {}, thresholds = {}) {
  const { green = 70, amber = 45 } = thresholds;
  const parts = {};
  const reasons = [];

  const confident = (v, c) =>
    Number.isFinite(v) && (c == null || c >= MIN_CONFIDENCE) ? v : null;

  const si = confident(signals.stressIndex, signals.hrvConfidence);
  if (si != null) {
    parts.stressIndex = ramp(
      normaliseStressIndex(si),
      REFERENCE.stressIndex.good,
      REFERENCE.stressIndex.bad,
    );
  }

  const rmssd = confident(signals.rmssd, signals.hrvConfidence);
  if (rmssd != null) {
    parts.rmssd = ramp(rmssd, REFERENCE.rmssd.good, REFERENCE.rmssd.bad);
  }

  const pulse = confident(signals.pulseRate, signals.pulseConfidence);
  if (pulse != null) {
    const r = REFERENCE.pulseRate;
    parts.pulseRate = band(pulse, r.lo, r.hi, r.slackLo, r.slackHi);
  }

  const br = confident(signals.breathingRate, signals.breathingConfidence);
  if (br != null) {
    const r = REFERENCE.breathingRate;
    parts.breathingRate = band(br, r.lo, r.hi, r.slackLo, r.slackHi);
  }

  const expr = scoreExpression(signals.expression);
  if (expr != null) parts.expression = expr;

  const eda = scoreEda(signals.edaTrace);
  if (eda != null) parts.eda = eda;

  // Weighted mean over whatever we actually got.
  let weighted = 0;
  let coverage = 0;
  for (const [key, value] of Object.entries(parts)) {
    if (value == null) continue;
    weighted += value * WEIGHTS[key];
    coverage += WEIGHTS[key];
  }

  if (coverage < MIN_WEIGHT_COVERAGE) {
    // FAIL CLOSED still holds: `composure` stays null and the verdict stays
    // inconclusive, so a weak read can never open the vault.
    //
    // But refusing to say anything at all was its own failure. Someone who sat
    // still for 60s and watched real vitals appear was told only "I cannot
    // tell", which reads as the app being broken rather than the light being
    // poor. So when SOMETHING measurable survived, publish a provisional score
    // alongside the refusal. It is explicitly labelled, never authoritative,
    // and never a verdict - it exists so the UI and the conversation can say
    // "this is roughly what we saw, and here is why we do not trust it".
    const provisional =
      coverage > 0 ? Math.round((weighted / coverage) * 100) : null;

    const weak = Object.entries(parts)
      .filter(([, v]) => v != null)
      .sort((a, b) => a[1] - b[1])
      .filter(([key, value]) => value < 0.6 && LABEL[key])
      .slice(0, 2)
      .map(([key]) => LABEL[key]);

    return {
      composure: null,
      provisional,
      verdict: "inconclusive",
      parts,
      coverage,
      reasons: [
        "Not enough confident signal to judge - hold still, good light, face in frame.",
        ...weak,
      ],
    };
  }

  const score = Math.round((weighted / coverage) * 100);

  // Name the weakest contributors so the UI can explain itself.
  const ranked = Object.entries(parts)
    .filter(([, v]) => v != null)
    .sort((a, b) => a[1] - b[1]);
  for (const [key, value] of ranked) {
    if (value < 0.6 && LABEL[key]) reasons.push(LABEL[key]);
    if (reasons.length >= 2) break;
  }

  const verdict = score >= green ? "green" : score >= amber ? "amber" : "red";
  return { composure: score, provisional: null, verdict, parts, coverage, reasons };
}
