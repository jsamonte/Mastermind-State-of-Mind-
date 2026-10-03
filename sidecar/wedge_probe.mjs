// Begins a casing, streams frames, then kills the socket MID-WINDOW - the
// shape that precedes a bound-but-unresponsive sidecar. Then polls /health.
import WebSocket from "ws";
import { encodeFrame } from "./src/protocol.mjs";

const PORT = Number(process.argv[2]);
const W = 64, H = 48;
const PIXELS = Buffer.alloc(W * H * 3, 0x70);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function health(label) {
  const started = Date.now();
  try {
    const res = await fetch(`http://127.0.0.1:${PORT}/health`, {
      signal: AbortSignal.timeout(8000),
    });
    const body = await res.json();
    console.log(`  ${label}: HTTP ${res.status} in ${Date.now() - started}ms  source=${body.source} auth=${body.auth}`);
    return true;
  } catch (err) {
    console.log(`  ${label}: NO ANSWER after ${Date.now() - started}ms (${err?.name ?? err})`);
    return false;
  }
}

console.log("before any casing:");
await health("health");

const ws = new WebSocket(`ws://127.0.0.1:${PORT}`);
await new Promise((r) => ws.on("open", r));
const seen = [];
ws.on("message", (raw) => {
  try { seen.push(JSON.parse(raw.toString()).type); } catch {}
});

ws.send(JSON.stringify({ type: "begin", durationMs: 60000 }));
const t0 = Date.now();
const pump = setInterval(() => {
  if (ws.readyState === WebSocket.OPEN) {
    ws.send(encodeFrame({ width: W, height: H, timestampUs: (Date.now() - t0) * 1000, pixels: PIXELS }));
  }
}, 33);

await sleep(4000);
console.log(`messages so far: ${[...new Set(seen)].join(", ") || "(none)"}`);

// Mid-window, destroy the socket without an `end` - a closed tab, a reload.
clearInterval(pump);
console.log("killing the socket mid-window (no end message)...");
ws.terminate();

for (let i = 1; i <= 5; i++) {
  await sleep(2500);
  await health(`health +${i * 2.5}s`);
}
process.exit(0);
