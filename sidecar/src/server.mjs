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
import { createAuthMinter } from "./auth.mjs";
import { createCounsellor } from "./counsel.mjs";
import { decodeFrame, VERSION as PROTOCOL_VERSION } from "./protocol.mjs";
import { composure } from "./composure.mjs";
import { createMockSource, SCENARIOS } from "./mock.mjs";
import { createSmartSpectraSource, nativeSupportNote } from "./smartspectra.mjs";

const args = parseArgs(process.argv.slice(2));
const PORT = Number(args.port ?? process.env.SIDECAR_PORT ?? 8787);
const HOST = "127.0.0.1";
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

// Both of these are optional; the vault measures fine without either.
const { minter, reason: authReason } = await createAuthMinter();
const { counsellor, reason: counselReason } = createCounsellor();

/**
 * The page is served from a different port than the sidecar, so every HTTP
 * response needs CORS headers and preflights must be answered. Only loopback
 * origins are allowed - this process holds the Presage key and a Firebase
 * private key, and should not answer to a page from anywhere else.
 */
function applyCors(req, res) {
  const origin = req.headers.origin;
  if (!origin) return true;
  const allowed = /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(origin);
  if (!allowed) return false;
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
const wss = new WebSocketServer({ server: httpServer, maxPayload: MAX_FRAME_BYTES });

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
  console.log(`  auth:     ${minter ? `ready (${minter.issuer})` : `disabled - ${authReason}`}`);
  console.log(`  counsel:  ${counsellor ? `ready (${counsellor.models[0]})` : `disabled - ${counselReason}`}\n`);
});

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

    const result = finished.last ?? {
      composure: null,
      verdict: "inconclusive",
      parts: {},
      reasons: ["The measurement ended before a confident reading arrived."],
    };
    console.log(`[=] casing ended (${reason}): ${result.verdict} ${result.composure ?? "-"}`);
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
      lastSent: 0,
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
          : await createSmartSpectraSource({
              apiKey: process.env.PRESAGE_API_KEY,
              onSignals,
              onStatus: (s) => send({ type: "status", ...s }),
              onError: (e) => send({ type: "error", ...e }),
            });

      await pending.source.start();
    } catch (err) {
      console.error("  could not start source:", err?.message ?? err);
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
        send({ type: "error", code: err.code ?? "bad_frame", message: err.message });
        return;
      }
      session.frames += 1;
      try {
        session.source.sendFrame(frame);
      } catch (err) {
        send({ type: "error", code: "send_frame_failed", message: String(err?.message ?? err) });
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
