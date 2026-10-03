/**
 * smartspectra.mjs - wraps @smartspectra/node-sdk behind the small interface the
 * rest of the sidecar uses, so `mock.mjs` can stand in for it exactly.
 *
 * The SDK is imported lazily. That is deliberate: Presage does not publish a
 * `win32-arm64` native runtime, so on a Windows ARM64 machine `require()` throws.
 * Importing on demand means the sidecar can still boot with `--source=mock` on
 * hardware that cannot run the real thing. See docs/ARCHITECTURE.md.
 */

/** Signal source interface: start / sendFrame / stop / destroy + three callbacks. */

const SUPPORTED_NATIVE_TARGETS = new Set([
  "win32-x64", "linux-x64", "linux-arm64", "darwin-arm64",
]);

/** Human-readable explanation when the native runtime is missing for this host. */
export function nativeSupportNote() {
  const target = `${process.platform}-${process.arch}`;
  if (SUPPORTED_NATIVE_TARGETS.has(target)) return null;
  return [
    `@smartspectra/node-sdk has no native runtime for ${target}.`,
    `Presage publishes: ${[...SUPPORTED_NATIVE_TARGETS].join(", ")}.`,
    "Options: run the sidecar under WSL2 on Ubuntu 22.04+ (reports linux-arm64),",
    "use an x64 Node build under emulation (reports win32-x64), or run --source=mock.",
  ].join(" ");
}

/**
 * @param {object} options
 * @param {string} options.apiKey
 * @param {(signals:object)=>void} options.onSignals
 * @param {(status:object)=>void} options.onStatus
 * @param {(error:object)=>void} options.onError
 */
export async function createSmartSpectraSource({ apiKey, onSignals, onStatus, onError }) {
  if (!apiKey) throw new Error("PRESAGE_API_KEY is not set - see sidecar/.env.example");

  const note = nativeSupportNote();
  if (note) {
    const err = new Error(note);
    err.code = "unsupported_platform";
    throw err;
  }

  let sdkModule;
  try {
    sdkModule = await import("@smartspectra/node-sdk");
  } catch (cause) {
    const err = new Error(
      `Could not load @smartspectra/node-sdk: ${cause?.message ?? cause}. ` +
        "Run `npm install` in sidecar/, and check the native runtime for this platform exists.",
    );
    err.code = "sdk_load_failed";
    err.cause = cause;
    throw err;
  }

  const {
    SmartSpectraSDK,
    FrameTransform,
    PixelFormat,
    decodeMetrics,
    breathingMetrics,
    cardioMetrics,
    faceMetrics,
    edaMetrics,
  } = sdkModule;

  const sdk = new SmartSpectraSDK({
    apiKey,
    // Everything the composure heuristic can use. Requesting a bundle we then
    // ignore only costs processing, but a bundle we *forget* arrives empty -
    // cardio fields stay empty unless a cardio metric is explicitly requested.
    requestedMetrics: [
      ...(breathingMetrics ?? []),
      ...(cardioMetrics ?? []),
      ...(faceMetrics ?? []),
      ...(edaMetrics ?? []),
    ],
  });

  // Latest-value accumulator. Presage emits metrics incrementally, so we keep the
  // most recent confident sample of each signal rather than re-deriving per event.
  const latest = {};

  sdk.on("metrics", (buf, timestampUs) => {
    let decoded;
    try {
      decoded = decodeMetrics(buf);
    } catch (cause) {
      onError?.({ code: "decode_failed", message: String(cause?.message ?? cause), retryable: true });
      return;
    }
    // decodeMetrics hands back the raw Buffer when it cannot parse the payload.
    if (!decoded || Buffer.isBuffer(decoded)) return;

    Object.assign(latest, flattenMetrics(decoded), { timestampUs });
    onSignals?.({ ...latest });
  });

  sdk.on("processingStatus", (status) => onStatus?.({ kind: "processing", status }));
  sdk.on("validationStatus", (code, timestampUs, hint) =>
    onStatus?.({ kind: "validation", code, timestampUs, hint }));
  sdk.on("error", (code, message, retryable) => onError?.({ code, message, retryable }));

  return {
    kind: "smartspectra",
    version: SmartSpectraSDK.version,

    async start() {
      sdk.useCustomInput(FrameTransform?.kNone);
      sdk.start();
    },

    sendFrame({ pixels, width, height, stride, timestampUs }) {
      return sdk.sendFrame(pixels, width, height, stride, PixelFormat.kRGB, timestampUs);
    },

    async stop() {
      await sdk.stopAsync();
    },

    async destroy() {
      try {
        await sdk.stopAsync();
      } catch {
        // Already stopped, or never started - destroy anyway.
      }
      await sdk.destroy();
    },
  };
}

/**
 * Flatten the decoded protobuf into the flat shape composure.mjs expects.
 * Written defensively: field presence varies with the requested bundles, the
 * measurement's maturity, and SDK version.
 */
export function flattenMetrics(m) {
  const out = {};
  const last = (arr) => (Array.isArray(arr) && arr.length ? arr[arr.length - 1] : undefined);

  const breathingRate = last(m.breathing?.rate);
  if (breathingRate) {
    out.breathingRate = num(breathingRate.value);
    out.breathingConfidence = num(breathingRate.confidence);
  }

  const pulseRate = last(m.cardio?.pulseRate);
  if (pulseRate) {
    out.pulseRate = num(pulseRate.value);
    out.pulseConfidence = num(pulseRate.confidence);
  }

  const hrv = last(m.cardio?.hrv);
  if (hrv) {
    out.rmssd = num(hrv.rmssd);
    out.sdnn = num(hrv.sdnn);
    out.meanNn = num(hrv.meanNn);
    // Baevsky stress index - the most directly stress-shaped value Presage gives.
    out.stressIndex = num(hrv.baevsky);
    out.hrvConfidence = num(hrv.confidence);
    out.hrvStable = Boolean(hrv.stable);
  }

  if (Array.isArray(m.eda?.trace) && m.eda.trace.length) {
    // Keep a bounded window - only the shape of the recent trace is used.
    out.edaTrace = m.eda.trace.slice(-120).map((s) => num(s?.value)).filter(Number.isFinite);
  }

  const expression = last(m.face?.expression);
  if (expression) out.expression = expression;

  const blinking = last(m.face?.blinking);
  if (blinking) out.blinking = Boolean(blinking.detected);

  const talking = last(m.face?.talking);
  if (talking) out.talking = Boolean(talking.detected);

  return out;
}

function num(v) {
  const n = Number(v);
  return Number.isFinite(n) ? n : undefined;
}
