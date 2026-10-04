/**
 * server.mjs - the Presage sidecar.
 *
 * Holds the SmartSpectra SDK (which cannot run in a browser), accepts webcam
 * frames from the Flutter web app over a WebSocket, and streams composure
 * readings back.
 *
 * Binds to loopback only. The Presage API key lives here and is never sent to
 * the browser.
 *
 * Trust note: this process runs on the user's own machine, so it is NOT a
 * security boundary - a determined user can always feed it a video of someone
 * calm. Mastermind is a commitment device for a willing participant, not an
 * adversarial control. The Cloud Function records what the sidecar reports; it
 * does not pretend to verify it.
 *
 *   node src/server.mjs                  # real SDK, key from .env
 *   node src/server.mjs --source=mock    # no SDK needed
 *   node src/server.mjs --source=mock --scenario=agitated
 */
import { WebSocketServer } from "ws";
import { createServer } from "node:http";
import process from "node:process";
import os from "node:os";
import { createAuthMinter } from "./auth.mjs";
import { createCounsellor } from "./counsel.mjs";
import { decodeJpegFrame } from "./jpeg_frame.mjs";
import { decodeFrame, VERSION as PROTOCOL_VERSION } from "./protocol.mjs";
import { composure } from "./composure.mjs";
import { createMockSource, SCENARIOS } from "./mock.mjs";
import { createIsolatedSource } from "./casing_host.mjs";
import { nativeSupportNote } from "./smartspectra.mjs";

const args = parseArgs(process.argv.slice(2));
// PORT is read from the plain `PORT` too, because every container platform sets
// that and nothing else.
const PORT = Number(args.port ?? process.env.PORT ?? process.env.SIDECAR_PORT ?? 8787);

// Loopback by default: on a developer machine this process holds the Presage
// key, a Gemini key and a Firebase private key, and must not be reachable from
// the network. A container has no loopback worth binding, so deployments set
// SIDECAR_HOST=0.0.0.0 explicitly — an opt-in, never a default.
const HOST = args.host ?? process.env.SIDECAR_HOST ?? "127.0.0.1";
/** Default measurement window. Presage needs a sustained look to produce HRV. */
const DEFAULT_DURATION_MS = Number(args.duration ?? process.env.CASING_DURATION_MS ?? 30_000);
/** Readings are emitted at most this often, to keep the UI calm. */
const READING_INTERVAL_MS = 500;
/** Frames larger than this are refused outright rather than buffered. */
const MAX_FRAME_BYTES = 8 * 1024 * 1024;

let sourceMode = args.source ?? process.env.SIDECAR_SOURCE ?? "smartspectra";
const scenario = args.scenario ?? process.env.MOCK_SCENARIO ?? "settling";

if (sourceMode === "smartspectra") {
  const note = nativeSupportNote();
  if (note) {
    console.error(`\n!! ${note}\n`);
    console.error("   Falling back to --source=mock so you can keep working.\n");
    sourceMode = "mock";
  } else if (!process.env.PRESAGE_API_KEY) {
    console.error("\n!! PRESAGE_API_KEY is not set. Copy sidecar/.env.example to .env.");
    console.error("   Falling back to --source=mock.\n");
    sourceMode = "mock";
  }
}

if (sourceMode === "mock" && !SCENARIOS.includes(scenario)) {
  console.error(`unknown --scenario=${scenario}; expected one of ${SCENARIOS.join(", ")}`);
  process.exit(1);
}

// Both of these are optional; measurement works fine without either. They are
// wrapped because a broken credential or a missing key must DISABLE the feature,
// never stop the sidecar from measuring — that is its one essential job.
let minter = null;
let authReason = null;
try {
  ({ minter, reason: authReason } = await createAuthMinter());
} catch (err) {
  authReason = `auth setup threw: ${err?.message ?? err}`;
}

let counsellor = null;
let counselReason = null;
try {
  ({ counsellor, reason: counselReason } = createCounsellor());
} catch (err) {
  counselReason = `counsel setup threw: ${err?.message ?? err}`;
}

/**
 * The page is served from a different port than the sidecar, so every HTTP
 * response needs CORS headers and preflights must be answered. Only loopback
 * origins are allowed - this process holds the Presage key and a Firebase
 * private key, and should not answer to a page from anywhere else.
 */
/**
 * Origins allowed in addition to loopback, comma-separated in EXTRA_ORIGINS.
 *
 * The deployed site needs this: a page on https://<project>.web.app talking to
 * this process is a cross-origin request, so the origin has to be listed. Note
 * that allowing it is NOT enough on its own — Chrome's Local Network Access
 * policy blocks a public HTTPS page from reaching 127.0.0.1 before CORS is even
 * consulted (`ERR_BLOCKED_BY_LOCAL_NETWORK_ACCESS_CHECKS`), and WebSockets have
 * no preflight to opt in with. The deployed site therefore has to reach this
 * process through a tunnel, not through loopback. See docs/DEPLOYED.md.
 */
const EXTRA_ORIGINS = new Set(
  (process.env.EXTRA_ORIGINS ?? "https://mastermind-state-of-mind.web.app")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean),
);

function applyCors(req, res) {
  const origin = req.headers.origin;
  if (!origin) return true;
  const isLoopback = /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(origin);
  if (!isLoopback && !EXTRA_ORIGINS.has(origin)) return false;
  res.setHeader("Access-Control-Allow-Origin", origin);
  res.setHeader("Access-Control-Allow-Methods", "POST, GET, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");
  res.setHeader("Vary", "Origin");
  return true;
}

function sendJson(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(payload);
}

async function readBody(req, limitBytes = 64 * 1024) {
  const chunks = [];
  let total = 0;
  for await (const chunk of req) {
    total += chunk.length;
    if (total > limitBytes) throw new Error("request body too large");
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString("utf8");
}

const httpServer = createServer(async (req, res) => {
  if (!applyCors(req, res)) {
    sendJson(res, 403, { error: "origin_not_allowed" });
    return;
  }
  if (req.method === "OPTIONS") {
    res.writeHead(204);
    res.end();
    return;
  }

  const url = new URL(req.url ?? "/", `http://${HOST}:${PORT}`);

  if (url.pathname === "/health") {
    sendJson(res, 200, {
      ok: true,
      source: sourceMode,
      protocolVersion: PROTOCOL_VERSION,
      auth: minter ? "ready" : "disabled",
      authReason,
      counsel: counsellor ? "ready" : "disabled",
      counselReason,
    });
    return;
  }

  // The conversation after a reading. The Gemini key stays here; anything in
  // the Flutter web bundle is public.
  if (url.pathname === "/counsel" && req.method === "POST") {
    if (!counsellor) {
      sendJson(res, 503, { error: "counsel_disabled", message: counselReason });
      return;
    }
    try {
      const body = JSON.parse(await readBody(req, 256 * 1024));
      const messages = Array.isArray(body.messages) ? body.messages.slice(-24) : [];
      const { reply, model } = await counsellor.counsel({
        reading: body.reading,
        messages,
      });
      sendJson(res, 200, { reply, model });
    } catch (err) {
      console.error("  counsel failed:", err?.message ?? err);
      sendJson(res, err?.status === 503 ? 503 : 502, {
        error: "counsel_failed",
        message: String(err?.message ?? err),
      });
    }
    return;
  }

  if (url.pathname === "/auth/firebase" && req.method === "POST") {
    if (!minter) {
      sendJson(res, 503, { error: "auth_disabled", message: authReason });
      return;
    }
    try {
      const body = JSON.parse(await readBody(req));
      const result = await minter.mint(body.idToken);
      sendJson(res, 200, result);
    } catch (err) {
      const status = err?.status ?? 400;
      sendJson(res, status, {
        error: err?.code ?? "mint_failed",
        message: String(err?.message ?? err),
      });
    }
    return;
  }

  sendJson(res, 404, { error: "not_found" });
});

// The WebSocket shares the HTTP server, so frames and the auth endpoint live on
// one port and the app only needs one address configured.
/** True for origins allowed to open a socket: loopback, or an EXTRA_ORIGINS entry. */
function isAllowedOrigin(origin) {
  if (!origin) return HOST === "127.0.0.1"; // a non-browser client is only OK locally
  return /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(origin) || EXTRA_ORIGINS.has(origin);
}

const wss = new WebSocketServer({
  server: httpServer,
  maxPayload: MAX_FRAME_BYTES,
  // The HTTP endpoints were origin-checked from the start, but the socket was
  // not — it only logged the origin. That is survivable on loopback and a real
  // hole once this binds publicly: anyone could stream frames and spend the
  // account's Presage credits. Refuse the upgrade instead.
  verifyClient: ({ origin }, done) => {
    if (isAllowedOrigin(origin)) return done(true);
    console.warn(`  [ws] refused upgrade from origin ${origin ?? "(none)"}`);
    done(false, 403, "Origin not allowed");
  },
});

httpServer.on("error", (err) => {
  console.error(`sidecar could not listen on ${HOST}:${PORT}: ${err?.message ?? err}`);
  process.exit(1);
});

// Announce only once the socket is actually accepting connections - printing this
// synchronously after construction is a lie, and anything that waits for the
// banner before connecting gets ECONNREFUSED.
httpServer.listen(PORT, HOST, () => {
  console.log(`Mastermind sidecar listening on ws://${HOST}:${PORT}`);
  console.log(`  source:   ${sourceMode}${sourceMode === "mock" ? ` (${scenario})` : ""}`);
  console.log(`  protocol: v${PROTOCOL_VERSION}`);
  console.log(`  window:   ${DEFAULT_DURATION_MS / 1000}s per casing`);
  console.log(`  at once:  ${MAX_CONCURRENT_CASINGS} measurement${MAX_CONCURRENT_CASINGS === 1 ? "" : "s"}`);
  console.log(`  auth:     ${minter ? `ready (${minter.issuer})` : `disabled - ${authReason}`}`);
  console.log(`  counsel:  ${counsellor ? `ready (${counsellor.models[0]})` : `disabled - ${counselReason}`}`);
  if (HOST !== "127.0.0.1") {
    console.log(`  origins:  ${[...EXTRA_ORIGINS].join(", ") || "(loopback only)"}`);
    console.warn(
      `\n!! Bound to ${HOST} — this process is reachable from the network and holds\n` +
        "   the Presage, Gemini and Firebase credentials. Only the origins above can\n" +
        "   open a socket; make sure that list is right before exposing it.\n",
    );
  } else {
    console.log("");
  }
});

/**
 * Which socket currently owns the capture SDK, or null when it is free.
 *
 * Per-connection state is not enough. `@smartspectra/node-sdk`'s own typings
 * say "native SDK state is process-global", so every socket's SmartSpectraSDK
 * is a handle onto the same native session. Two tabs casing at once therefore
 * fight over it, and one tab's teardown drops the other out of its measuring
 * state mid-window. The damage lands on the INNOCENT tab, as an opaque
 * "SmartSpectra is not in a valid state for this operation" on its frames,
 * which reads like a Presage outage and is not one.
 *
 * So the SDK is owned by one connection at a time and the second tab is told
 * plainly what is happening.
 */
let sdkOwner = null;

/**
 * How many measurements may run at once.
 *
 * This used to be one, enforced by sdkOwner below, because the SDK was a
 * process-global singleton: two tabs measuring at once fought over it and the
 * damage landed on the innocent one. Each casing now runs in its own process,
 * so they no longer share anything and that reason is gone.
 *
 * What caps it now is the machine. The SmartSpectra runtime is x64 and this
 * class of host may be ARM, so it can be running emulated, and each concurrent
 * measurement is a whole pipeline at 30fps. Overcommitting does not fail
 * politely - it slows every measurement below the 25fps Presage requires and
 * spoils all of them instead of queueing one. So: a conservative share of the
 * cores, overridable when you know your own hardware.
 */
const MAX_CONCURRENT_CASINGS = Math.max(
  1,
  Number(process.env.MAX_CASINGS ?? Math.min(3, Math.floor((os.cpus()?.length ?? 4) / 3))),
);

/** Casings in flight, for the cap above. */
let activeCasings = 0;

/**
 * SDK errors that mean this measurement is over, and the plain-language reason.
 *
 * Without this, a rejected API key looked exactly like a quiet failure: the
 * pipeline refused every subsequent frame with "SmartSpectra is not in a valid
 * state", one message per frame, and the person waited out the full window to
 * be told the reading was inconclusive. The cause was in the first error, 55
 * seconds earlier, and nothing surfaced it.
 *
 * Codes are from SmartSpectraErrorCode in the SDK's constants.
 */
const TERMINAL_SDK_ERRORS = new Map([
  [2, "Presage rejected this server's API key, so no measurement can be taken here."],
  [3, "The measurement service is misconfigured, so no measurement can be taken here."],
  [4, "The Presage account is out of measurement credits."],
  [5, "The measurement service could not reach Presage, so this reading was abandoned."],
  [6, "Presage reported a server error, so this reading was abandoned."],
]);

wss.on("connection", (ws, req) => {
  // Loopback-only is enforced by the bind, but a stray remote origin is worth refusing.
  const origin = req.headers.origin;
  console.log(`[+] client connected${origin ? ` (origin ${origin})` : ""}`);

  /** @type {{source:any, thresholds:object, endsAt:number, timer:any, lastSent:number, best:object|null}|null} */
  let session = null;

  const send = (obj) => {
    if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(obj));
  };

  send({ type: "ready", source: sourceMode, protocolVersion: PROTOCOL_VERSION, scenario: sourceMode === "mock" ? scenario : undefined });

  async function endSession(reason) {
    if (!session) return;
    const finished = session;
    session = null;
    if (finished.timer) clearTimeout(finished.timer);

    try {
      await finished.source.stop();
    } catch (err) {
      console.error("  stop failed:", err?.message ?? err);
    }
    try {
      await finished.source.destroy();
    } catch {
      /* best effort */
    }

    // Released only once teardown has actually finished, so a slot is never
    // handed on while the process using it is still shutting down.
    if (finished.heldSlot) activeCasings = Math.max(0, activeCasings - 1);
    if (sdkOwner === ws) sdkOwner = null;

    const result = finished.last ?? {
      composure: null,
      verdict: "inconclusive",
      parts: {},
      reasons: [
        finished.terminalError ??
          finished.source?.abandonedReason ??
          "The measurement ended before a confident reading arrived.",
      ],
    };
    const span = finished.lastFrameAt - finished.firstFrameAt;
    const fps = span > 0 ? (finished.frames / (span / 1000)).toFixed(1) : "0.0";
    console.log(`[=] casing ended (${reason}): ${result.verdict} ${result.composure ?? "-"}`);
    console.log(
      `    frames: ${finished.frames} received @ ${fps}fps` +
        ` | ${finished.accepted} accepted, ${finished.refused} refused` +
        `, ${finished.decodeFailures} rejected, ${finished.badFrames} malformed`,
    );
    send({
      type: "final",
      reason,
      ...result,
      framesReceived: finished.frames,
      durationMs: Date.now() - finished.startedAt,
    });
  }

  async function beginSession(msg) {
    if (session) {
      send({ type: "error", code: "already_casing", message: "a measurement is already running" });
      return;
    }
    if (activeCasings >= MAX_CONCURRENT_CASINGS) {
      send({
        type: "error",
        code: "sidecar_busy",
        // Not necessarily another TAB. The hosted site points everyone at one
        // sidecar, so the people ahead are usually strangers, and telling
        // someone to close a tab they do not have reads as a bug.
        message:
          `${MAX_CONCURRENT_CASINGS} measurement${MAX_CONCURRENT_CASINGS === 1 ? " is" : "s are"} ` +
          "already running, which is all this machine can do at once. One takes " +
          "about a minute - try again in a moment.",
      });
      return;
    }

    const thresholds = {
      green: clampThreshold(msg?.thresholds?.green, 70),
      amber: clampThreshold(msg?.thresholds?.amber, 45),
    };
    if (thresholds.amber > thresholds.green) {
      send({ type: "error", code: "bad_thresholds", message: "amber must not exceed green" });
      return;
    }
    const durationMs = Number.isFinite(msg?.durationMs)
      ? Math.max(5_000, Math.min(120_000, msg.durationMs))
      : DEFAULT_DURATION_MS;

    const startedAt = Date.now();
    const pending = {
      thresholds,
      startedAt,
      // Set before the source starts: signals can arrive before start() returns,
      // and onSignals reads endsAt to report the countdown.
      endsAt: startedAt + durationMs,
      frames: 0,
      // Why a measurement produced nothing is otherwise unanswerable from the
      // logs: frame errors used to go only to the browser, so a server with
      // zero frames arriving looked identical to one the SDK ignored.
      badFrames: 0,
      // Set once the SDK has reported something this measurement cannot
      // recover from, so the person is told why instead of "inconclusive".
      terminalError: null,
      /** True once this casing has taken one of the concurrency slots. */
      heldSlot: true,
      decodeFailures: 0,
      accepted: 0,
      refused: 0,
      firstFrameAt: 0,
      lastFrameAt: 0,
      lastSent: 0,
      // Set once the pipeline has been rebuilt for this casing, so a fault
      // cannot put the SDK into a reset loop.
      recovered: false,
      last: null,
      timer: null,
      source: null,
    };

    const onSignals = (signals) => {
      const reading = composure(signals, pending.thresholds);
      pending.last = { ...reading, signals };
      const now = Date.now();
      if (now - pending.lastSent < READING_INTERVAL_MS) return;
      pending.lastSent = now;
      send({
        type: "reading",
        ...reading,
        signals,
        elapsedMs: now - pending.startedAt,
        remainingMs: Math.max(0, pending.endsAt - now),
        framesReceived: pending.frames,
      });
    };

    // Claimed before the first await rather than after start() returns:
    // beginSession is async, so several sockets could all clear the check above
    // if the slot were only taken once the source is up.
    activeCasings += 1;
    sdkOwner = ws;

    try {
      pending.source =
        sourceMode === "mock"
          ? createMockSource({
              scenario,
              settleSeconds: Math.round(durationMs / 1000) - 5,
              onSignals,
              onStatus: (s) => send({ type: "status", ...s }),
              onError: (e) => send({ type: "error", ...e }),
            })
          : await createIsolatedSource({
              // The SDK runs in its own process, so a native call that never
              // returns costs one reading instead of the whole sidecar. The
              // child does the JPEG decode too, which takes that work off the
              // event loop everyone else is sharing.
              apiKey: process.env.PRESAGE_API_KEY,
              nodePath: process.env.CASING_NODE,
              onSignals,
              onStatus: (s) => {
                // Presage's validation hints say WHY a measurement is not
                // landing ("no face", "too dark"). Silent in the log is how a
                // broken pipeline looks healthy.
                console.log(`  [status] ${s.kind}: ${s.hint ?? s.code ?? s.status ?? ""}`);
                send({ type: "status", ...s });
              },
              onError: (e) => {
                console.error(`  [sdk error] code=${e.code} retryable=${e.retryable}: ${e.message}`);

                // A terminal error poisons the pipeline: every later frame is
                // refused. Say so once, in words that name the actual problem,
                // and stop rather than spending the rest of the window proving
                // it again frame by frame.
                const terminal = TERMINAL_SDK_ERRORS.get(e.code);
                if (terminal) {
                  if (pending.terminalError) return;
                  pending.terminalError = terminal;
                  send({ type: "error", code: `sdk_${e.code}`, message: terminal, fatal: true });
                  void endSession("sdk_unavailable");
                  return;
                }

                // Anything else flagged fatal - the watchdog giving up on a
                // wedged child, most of all - ends the window too. Letting it
                // run on would spend another 50 seconds proving what the error
                // already said.
                if (e.fatal) {
                  if (pending.terminalError) return;
                  pending.terminalError = e.message;
                  send({ type: "error", ...e });
                  void endSession(e.code ?? "source_failed");
                  return;
                }

                send({ type: "error", ...e });

                // Deliberately does NOT rebuild the pipeline here.
                //
                // An earlier version called source.recover() on kProcessingFailed,
                // which runs the SDK's synchronous native reset()/start() on the
                // main thread. That blocked the event loop: the process kept
                // holding port 8787 while answering nothing, so one bad reading
                // took down the whole sidecar — and the site with it.
                //
                // It was also unnecessary. beginSession() constructs a FRESH
                // SmartSpectraSDK for every casing and destroys it at the end,
                // so the next measurement already starts from a clean pipeline.
                // A failed reading stays a failed reading; it is not contagious.
              },
            });

      await pending.source.start();
    } catch (err) {
      console.error("  could not start source:", err?.message ?? err);
      activeCasings = Math.max(0, activeCasings - 1);
      pending.heldSlot = false;
      sdkOwner = null;
      send({
        type: "error",
        code: err?.code ?? "source_start_failed",
        message: String(err?.message ?? err),
        fatal: true,
      });
      return;
    }

    pending.timer = setTimeout(() => void endSession("window_elapsed"), durationMs);
    session = pending;

    console.log(`[>] casing started: ${durationMs / 1000}s, green>=${thresholds.green}`);
    send({ type: "casing", durationMs, thresholds, endsAt: pending.endsAt });
  }

  ws.on("message", (data, isBinary) => {
    if (isBinary) {
      if (!session) return; // frames before `begin` are simply ignored
      let frame;
      try {
        frame = decodeFrame(data);
      } catch (err) {
        session.badFrames += 1;
        if (session.badFrames === 1) console.error(`  [bad frame] ${err.message}`);
        send({ type: "error", code: err.code ?? "bad_frame", message: err.message });
        return;
      }
      session.frames += 1;
      if (!session.firstFrameAt) session.firstFrameAt = Date.now();
      session.lastFrameAt = Date.now();
      try {
        // Mock runs in-process and wants pixels; the real source is a child
        // process that takes the browser's bytes as they arrived and decodes
        // them over there.
        const payload = session.source.isolated
            ? data
            : frame.pixelFormat === "jpeg"
                ? decodeJpegFrame(frame)
                : frame;
        // A false return is not an error but it is not a delivered frame
        // either: it is the monotonic guard dropping it, the child falling
        // behind, or the SDK refusing it. Counted apart, because "frames
        // arrived" and "frames reached the pipeline" fail for different reasons.
        if (session.source.sendFrame(payload) === false) session.refused += 1;
        else session.accepted += 1;
      } catch (err) {
        session.decodeFailures += 1;
        // Once per casing, not once per frame: a poisoned pipeline fails all
        // 900 of them, and 900 identical socket messages bury whatever the
        // real first error was.
        if (session.decodeFailures === 1) {
          console.error(`  [frame rejected] ${String(err?.message ?? err)}`);
          send({ type: "error", code: "send_frame_failed", message: String(err?.message ?? err) });
        }
      }
      return;
    }

    let msg;
    try {
      msg = JSON.parse(data.toString());
    } catch {
      send({ type: "error", code: "bad_json", message: "control messages must be JSON" });
      return;
    }

    switch (msg.type) {
      case "begin":
        void beginSession(msg);
        break;
      case "end":
        void endSession("client_ended");
        break;
      case "ping":
        send({ type: "pong", t: msg.t });
        break;
      default:
        send({ type: "error", code: "unknown_message", message: `unknown type "${msg.type}"` });
    }
  });

  ws.on("close", () => {
    console.log("[-] client disconnected");
    void endSession("disconnected");
  });

  ws.on("error", (err) => console.error("  socket error:", err?.message ?? err));
});

function clampThreshold(value, fallback) {
  const n = Number(value);
  return Number.isFinite(n) ? Math.max(0, Math.min(100, n)) : fallback;
}

function parseArgs(argv) {
  const out = {};
  for (const arg of argv) {
    const m = /^--([^=]+)(?:=(.*))?$/.exec(arg);
    if (m) out[m[1]] = m[2] ?? true;
  }
  return out;
}

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    console.log("\nshutting down");
    wss.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 1500).unref();
  });
}
