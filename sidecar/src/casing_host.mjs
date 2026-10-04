/**
 * Parent half of the isolated measurement: looks exactly like the in-process
 * SmartSpectra source, but the SDK is actually running in a child process.
 *
 * See `casing_child.mjs` for why. The short version: the native calls are
 * synchronous and sometimes never return, so they cannot be allowed to share an
 * event loop with the server that everyone else is talking to.
 *
 * What this adds beyond plumbing is the watchdog. A wedged SDK cannot be
 * unwedged - there is no timeout to pass it and no callback to wait on - so the
 * only honest move is to notice the silence, kill the process, and tell that
 * one person their reading failed.
 */
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const CHILD = path.join(path.dirname(fileURLToPath(import.meta.url)), "casing_child.mjs");

/**
 * How long the child may produce nothing at all before it is presumed wedged.
 *
 * A healthy measurement is noisy: an accepted/refused line per frame at 30fps,
 * plus status and metrics. Silence for this long is not slowness, it is a
 * native call that has stopped returning. Generous enough to cover SDK startup
 * on a cold, emulated runtime, which is the one legitimately quiet stretch.
 */
export const SILENCE_TIMEOUT_MS = Number(process.env.CASING_SILENCE_MS ?? 25_000);

/** How long a child gets to exit politely before it is killed outright. */
export const EXIT_GRACE_MS = 4_000;

/**
 * Starts a measurement in its own process.
 *
 * Resolves once the child reports the SDK is up, so a failure to start is
 * thrown to the caller exactly as the in-process version threw it. Rejects if
 * the child dies or stays silent through startup.
 */
export async function createIsolatedSource({ apiKey, onSignals, onStatus, onError, nodePath }) {
  const child = spawn(nodePath ?? process.execPath, [CHILD], {
    env: { ...process.env, PRESAGE_API_KEY: apiKey },
    stdio: ["pipe", "pipe", "inherit"],
    windowsHide: true,
  });

  let alive = true;
  let ready = false;
  /** Set once stop()/destroy() has been asked for, so an exit is expected. */
  let leaving = false;
  let lastHeardAt = Date.now();
  /** Set when we give up on it, so the reason survives into the final reading. */
  let giveUpReason = null;

  // A dropped frame is better than an unbounded queue: the child falls behind
  // when the SDK stalls, and buffering a stalled 30fps stream is how a tidy
  // failure becomes an out-of-memory one.
  let writable = true;
  child.stdin.on("drain", () => { writable = true; });
  // EPIPE is expected whenever the child goes first; it is not worth reporting.
  child.stdin.on("error", () => { writable = false; });

  let stdout = "";
  const started = withResolvers();

  child.stdout.on("data", (chunk) => {
    lastHeardAt = Date.now();
    stdout += chunk.toString();
    let nl;
    while ((nl = stdout.indexOf("\n")) >= 0) {
      const line = stdout.slice(0, nl);
      stdout = stdout.slice(nl + 1);
      if (!line) continue;
      let msg;
      try {
        msg = JSON.parse(line);
      } catch {
        continue; // stray output is not fatal
      }
      switch (msg.t) {
        case "ready":
          ready = true;
          started.resolve();
          break;
        case "signals":
          onSignals?.(msg.signals);
          break;
        case "status":
          onStatus?.(msg.status);
          break;
        case "error": {
          const { t, ...error } = msg;
          if (!ready && error.fatal) {
            const err = new Error(error.message);
            err.code = error.code;
            started.reject(err);
          }
          onError?.(error);
          break;
        }
        default:
          break; // accepted / refused / frame_error / stopped: liveness only
      }
    }
  });

  child.on("exit", (code, signal) => {
    alive = false;
    if (!ready) {
      const err = new Error(
        `the measurement process exited before it was ready (code ${code}, signal ${signal})`,
      );
      err.code = "source_start_failed";
      started.reject(err);
      return;
    }
    // Died mid-measurement and nobody asked it to. Every later frame would be
    // dropped in silence and the window would run its full length before
    // admitting nothing was recorded, so say it now.
    if (!leaving && !giveUpReason) {
      giveUpReason =
        "The measurement stopped unexpectedly. Nothing else was affected - press Try again.";
      onError?.({ code: "casing_died", message: giveUpReason, fatal: true, retryable: false });
    }
  });

  const watchdog = setInterval(() => {
    if (!alive || giveUpReason) return;
    if (Date.now() - lastHeardAt < SILENCE_TIMEOUT_MS) return;
    giveUpReason =
      "The measurement stopped responding and was abandoned. Nothing else was affected - press Try again.";
    onError?.({
      code: "casing_wedged",
      message: giveUpReason,
      fatal: true,
      retryable: false,
    });
    kill();
  }, 1_000);
  watchdog.unref();

  function kill() {
    if (!alive) return;
    try {
      // SIGKILL, not SIGTERM: a process blocked inside a native call does not
      // run its handlers, so asking nicely achieves nothing but a longer wait.
      child.kill("SIGKILL");
    } catch {
      /* already gone */
    }
    alive = false;
  }

  await started.promise;

  return {
    kind: "smartspectra",
    isolated: true,

    /** Already started: the child does it before reporting ready. */
    async start() {},

    sendFrame(raw) {
      if (!alive || !writable) return false;
      const header = Buffer.allocUnsafe(4);
      header.writeUInt32LE(raw.length, 0);
      writable = child.stdin.write(Buffer.concat([header, raw]));
      return true;
    },

    async stop() {
      leaving = true;
      clearInterval(watchdog);
      if (!alive) return;
      try {
        child.stdin.end();
      } catch {
        /* nothing to close */
      }
      // Closing stdin is the request; this is the deadline on it.
      await Promise.race([
        new Promise((resolve) => child.once("exit", resolve)),
        new Promise((resolve) => setTimeout(resolve, EXIT_GRACE_MS)),
      ]);
      kill();
    },

    async destroy() {
      leaving = true;
      clearInterval(watchdog);
      kill();
    },

    /** Why this measurement was abandoned, or null if it ended normally. */
    get abandonedReason() {
      return giveUpReason;
    },
  };
}

/** Promise.withResolvers, which is not available on every runtime we support. */
function withResolvers() {
  let resolve;
  let reject;
  const promise = new Promise((res, rej) => {
    resolve = res;
    reject = rej;
  });
  // The rejection is consumed by the awaiting caller; this only stops an
  // unhandled-rejection warning in the window before that await is reached.
  promise.catch(() => {});
  return { promise, resolve, reject };
}
