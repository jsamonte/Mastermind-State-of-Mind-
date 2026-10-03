/**
 * End-to-end test: boots the real server as a child process, connects a real
 * WebSocket client, streams frames, and checks the verdict that comes back.
 *
 * Uses the mock source, so it runs anywhere - including the Windows ARM64
 * machine that cannot load the Presage native runtime.
 */
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { fileURLToPath } from "node:url";
import path from "node:path";
import WebSocket from "ws";
import { encodeFrame } from "./protocol.mjs";

const SERVER = fileURLToPath(new URL("./server.mjs", import.meta.url));
const WIDTH = 32;
const HEIGHT = 24;
const PIXELS = Buffer.alloc(WIDTH * HEIGHT * 3, 0x60);

/** Run one casing against a mock scenario and return every message received. */
async function runCasing({ scenario, port, durationMs = 6000, thresholds }) {
  const child = spawn(
    process.execPath,
    [SERVER, "--source=mock", `--scenario=${scenario}`, `--port=${port}`],
    { stdio: ["ignore", "pipe", "pipe"], cwd: path.dirname(SERVER) },
  );

  const stderr = [];
  child.stderr.on("data", (d) => stderr.push(d.toString()));

  // Wait for the listening banner before connecting.
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`server did not start: ${stderr.join("")}`)), 15_000);
    child.stdout.on("data", (d) => {
      if (d.toString().includes("listening")) {
        clearTimeout(timer);
        resolve();
      }
    });
    child.on("exit", (code) => {
      clearTimeout(timer);
      reject(new Error(`server exited early (${code}): ${stderr.join("")}`));
    });
  });

  const ws = new WebSocket(`ws://127.0.0.1:${port}`);
  await once(ws, "open");

  const messages = [];
  const finalArrived = new Promise((resolve) => {
    ws.on("message", (raw) => {
      const msg = JSON.parse(raw.toString());
      messages.push(msg);
      if (msg.type === "final") resolve(msg);
    });
  });

  ws.send(JSON.stringify({ type: "begin", durationMs, thresholds }));

  // Stream frames at roughly 15fps for the whole window.
  const started = Date.now();
  const pump = setInterval(() => {
    if (ws.readyState !== WebSocket.OPEN) return;
    ws.send(encodeFrame({ width: WIDTH, height: HEIGHT, timestampUs: (Date.now() - started) * 1000, pixels: PIXELS }));
  }, 66);

  const final = await finalArrived;
  clearInterval(pump);
  ws.close();
  child.kill();
  await once(child, "exit").catch(() => {});

  return { final, messages };
}

// --- calm scenario should open the vault -------------------------------------
{
  const { final, messages } = await runCasing({ scenario: "calm", port: 18801 });
  console.log("calm      ->", final.verdict, final.composure, `(${final.framesReceived} frames)`);

  assert.equal(final.type, "final");
  assert.equal(final.verdict, "green", "calm scenario should clear the vault");
  assert.ok(final.composure > 70);
  assert.ok(final.framesReceived > 10, "server should have counted the streamed frames");
  assert.ok(messages.some((m) => m.type === "ready"), "server must announce itself");
  assert.ok(messages.some((m) => m.type === "casing"), "server must confirm the casing started");

  const readings = messages.filter((m) => m.type === "reading");
  assert.ok(readings.length >= 2, "live readings should stream during the window");
  for (const r of readings) {
    assert.ok(Number.isFinite(r.remainingMs), "countdown must be a real number, never NaN");
    assert.ok(r.remainingMs >= 0);
  }
}

// --- agitated scenario should keep it shut -----------------------------------
{
  const { final } = await runCasing({ scenario: "agitated", port: 18802 });
  console.log("agitated  ->", final.verdict, final.composure);
  assert.equal(final.verdict, "red", "agitated scenario must not clear the vault");
  assert.ok(final.reasons.length > 0, "a refusal must explain itself");
}

// --- noisy scenario must FAIL CLOSED ----------------------------------------
{
  const { final } = await runCasing({ scenario: "noisy", port: 18803 });
  console.log("noisy     ->", final.verdict, final.composure);
  assert.notEqual(final.verdict, "green", "low-confidence signal must never open the vault");
  assert.equal(final.composure, null);
}

// --- a malformed frame is reported, not fatal -------------------------------
{
  const child = spawn(process.execPath, [SERVER, "--source=mock", "--scenario=calm", "--port=18804"], {
    stdio: ["ignore", "pipe", "pipe"], cwd: path.dirname(SERVER),
  });
  await new Promise((resolve) => child.stdout.on("data", (d) => d.toString().includes("listening") && resolve()));

  const ws = new WebSocket("ws://127.0.0.1:18804");
  await once(ws, "open");
  const errors = [];
  ws.on("message", (raw) => {
    const m = JSON.parse(raw.toString());
    if (m.type === "error") errors.push(m);
  });

  ws.send(JSON.stringify({ type: "begin", durationMs: 6000 }));
  await new Promise((r) => setTimeout(r, 300));
  ws.send(Buffer.from([1, 2, 3, 4, 5]));           // garbage binary
  ws.send(Buffer.from("not json at all"));          // handled as text? still safe
  ws.send(JSON.stringify({ type: "nonsense" }));    // unknown control message
  await new Promise((r) => setTimeout(r, 500));

  assert.ok(errors.some((e) => e.code === "short_frame"), `expected short_frame, got ${JSON.stringify(errors)}`);
  assert.ok(errors.some((e) => e.code === "unknown_message"), "unknown control messages must be reported");
  assert.equal(ws.readyState, WebSocket.OPEN, "bad input must not kill the connection");
  console.log("bad input ->", errors.map((e) => e.code).join(", "));

  ws.close();
  child.kill();
  await once(child, "exit").catch(() => {});
}

console.log("\nall e2e tests passed");
