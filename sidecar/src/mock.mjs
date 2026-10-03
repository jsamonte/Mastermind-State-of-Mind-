/**
 * mock.mjs - a stand-in signal source implementing the same interface as
 * smartspectra.mjs, so the whole product (vault logic, UI, Firestore writes)
 * can be built and demoed without the SDK.
 *
 * This exists because Presage ships no `win32-arm64` native runtime, and the
 * laptop this was written on is Windows ARM64. It is also just a faster loop
 * for UI work than holding still in front of a webcam.
 *
 * Scenarios let a demo be deterministic:
 *   calm      - clears any sensible blueprint
 *   agitated  - stays red
 *   settling  - starts red and genuinely improves, so the "lie low" breathing
 *               screen has something real to show. This is the good demo.
 *   noisy     - low confidence throughout; proves the gate fails CLOSED
 */

export const SCENARIOS = ["calm", "agitated", "settling", "noisy"];

const PROFILES = {
  calm: { stressIndex: 95, rmssd: 62, pulseRate: 66, breathingRate: 13, negative: 0.03 },
  agitated: { stressIndex: 540, rmssd: 16, pulseRate: 103, breathingRate: 23, negative: 0.65 },
};

/** Linear interpolation between the agitated and calm profiles. */
function blend(t) {
  const a = PROFILES.agitated;
  const c = PROFILES.calm;
  const mix = (k) => a[k] + (c[k] - a[k]) * t;
  return {
    stressIndex: mix("stressIndex"),
    rmssd: mix("rmssd"),
    pulseRate: mix("pulseRate"),
    breathingRate: mix("breathingRate"),
    negative: mix("negative"),
  };
}

/**
 * @param {object} options
 * @param {string} [options.scenario]
 * @param {number} [options.settleSeconds] how long `settling` takes to go green
 */
export function createMockSource({
  scenario = "settling",
  settleSeconds = 25,
  onSignals,
  onStatus,
  onError,
} = {}) {
  if (!SCENARIOS.includes(scenario)) {
    throw new Error(`unknown mock scenario "${scenario}" - try one of: ${SCENARIOS.join(", ")}`);
  }

  let startedAt = 0;
  let frames = 0;
  let timer = null;
  const jitter = (amp) => (Math.random() - 0.5) * 2 * amp;
  const edaTrace = [];

  function emit() {
    const elapsed = (Date.now() - startedAt) / 1000;

    let base;
    let confidence = 0.88;
    if (scenario === "calm") base = blend(1);
    else if (scenario === "agitated") base = blend(0);
    else if (scenario === "noisy") {
      base = blend(0.5);
      confidence = 0.2; // below MIN_CONFIDENCE - nothing should count
    } else {
      // settling: ease from agitated to calm over settleSeconds
      base = blend(Math.max(0, Math.min(1, elapsed / settleSeconds)));
    }

    // EDA trace: falls while settling (arousal dropping), climbs while agitated.
    const direction = scenario === "agitated" ? 1 : -1;
    edaTrace.push(5 + direction * elapsed * 0.08 + jitter(0.05));
    if (edaTrace.length > 120) edaTrace.shift();

    onSignals?.({
      source: "mock",
      scenario,
      pulseRate: base.pulseRate + jitter(2),
      pulseConfidence: confidence,
      breathingRate: base.breathingRate + jitter(0.8),
      breathingConfidence: confidence,
      rmssd: Math.max(1, base.rmssd + jitter(4)),
      sdnn: Math.max(1, base.rmssd * 1.3 + jitter(4)),
      meanNn: 60000 / Math.max(30, base.pulseRate),
      stressIndex: Math.max(10, base.stressIndex + jitter(25)),
      hrvConfidence: confidence,
      hrvStable: elapsed > 5,
      edaTrace: [...edaTrace],
      expression: {
        anger: base.negative * 0.6,
        fear: base.negative * 0.4,
        neutral: Math.max(0, 1 - base.negative),
      },
      blinking: Math.random() < 0.1,
      talking: false,
      framesReceived: frames,
      timestampUs: Date.now() * 1000,
    });
  }

  return {
    kind: "mock",
    version: `mock/${scenario}`,

    async start() {
      startedAt = Date.now();
      frames = 0;
      edaTrace.length = 0;
      onStatus?.({ kind: "processing", status: "running", note: `mock source (${scenario})` });
      // Presage emits metrics roughly once a second once the pipeline warms up.
      timer = setInterval(emit, 1000);
      if (timer.unref) timer.unref();
    },

    sendFrame() {
      // The mock does not look at pixels, but counting frames proves the browser
      // really is streaming - a silent capture bug otherwise looks like calm.
      frames += 1;
      return true;
    },

    // The mock cannot enter a bad pipeline state, but it must satisfy the same
    // interface or the server's recovery path throws on mock runs.
    async recover() {},

    async stop() {
      if (timer) clearInterval(timer);
      timer = null;
      onStatus?.({ kind: "processing", status: "idle" });
    },

    async destroy() {
      if (timer) clearInterval(timer);
      timer = null;
    },
  };
}
