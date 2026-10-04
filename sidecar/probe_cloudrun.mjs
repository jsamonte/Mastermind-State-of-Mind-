/**
 * Streams synthetic JPEG frames at a sidecar exactly as the browser does, and
 * prints what the far end made of them.
 *
 * This exists because "Presage did not work" is not a diagnosis: a measurement
 * that ends with no reading looks identical whether the frames never arrived,
 * arrived too slowly, or arrived perfectly and were refused. The synthetic face
 * will never yield a real pulse - that is not the point. The point is the
 * tally, which separates a bandwidth problem from a pipeline problem in one
 * run, with no camera and no second person involved.
 *
 *   node probe_cloudrun.mjs [wss://host] [seconds]
 */
import jpeg from "jpeg-js";
import WebSocket from "ws";

const URL_ = process.argv[2] ?? "wss://mastermind-sidecar-981957401598.us-central1.run.app";
const W = 320, H = 240, FPS = 30, SECONDS = Number(process.argv[3] ?? 35);

function frameAt(t) {
  const d = Buffer.alloc(W * H * 4);
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    const i = (y * W + x) * 4;
    // a face-ish warm blob that breathes, over a neutral background
    const dx = (x - W / 2) / 60, dy = (y - H / 2) / 70;
    const inFace = dx * dx + dy * dy < 1;
    const pulse = 6 * Math.sin(2 * Math.PI * 1.2 * t);
    d[i]     = inFace ? 205 + pulse : 60;
    d[i + 1] = inFace ? 150 + pulse * 0.4 : 62;
    d[i + 2] = inFace ? 130 + pulse * 0.2 : 65;
    d[i + 3] = 255;
  }
  return jpeg.encode({ data: d, width: W, height: H }, 90).data;
}

const pre = [];
for (let k = 0; k < 24; k++) pre.push(frameAt(k / 24));
console.log(`jpeg size ~${(pre[0].length / 1024).toFixed(1)}KB -> ${(pre[0].length * FPS / 1024).toFixed(0)}KB/s`);

const ws = new WebSocket(URL_, { origin: "https://mastermind-state-of-mind.web.app" });
let sent = 0, t0 = 0;
ws.on("open", () => console.log("socket open"));
ws.on("message", (m) => {
  const msg = JSON.parse(m.toString());
  if (msg.type === "ready") {
    console.log("ready, source =", msg.source);
    ws.send(JSON.stringify({ type: "begin", durationMs: SECONDS * 1000, thresholds: { green: 70, amber: 45 } }));
  } else if (msg.type === "casing") {
    t0 = Date.now();
    const iv = setInterval(() => {
      if (ws.readyState !== WebSocket.OPEN) return clearInterval(iv);
      const elapsed = (Date.now() - t0) / 1000;
      if (elapsed > SECONDS + 2) return clearInterval(iv);
      const px = pre[sent % pre.length];
      const head = Buffer.alloc(20);
      head.writeUInt16LE(0x4d53, 0); head.writeUInt8(1, 2); head.writeUInt8(1, 3);
      head.writeUInt32LE(W, 4); head.writeUInt32LE(H, 8);
      head.writeDoubleLE(elapsed * 1e6, 12);
      ws.send(Buffer.concat([head, px]));
      sent++;
      if (sent % 150 === 0) console.log(`  sent ${sent} @ ${(sent / elapsed).toFixed(1)}fps, buffered ${(ws.bufferedAmount / 1024).toFixed(0)}KB`);
    }, 1000 / FPS);
  } else if (msg.type === "status") {
    console.log("  [status]", JSON.stringify(msg).slice(0, 200));
  } else if (msg.type === "error") {
    console.log("  [error]", msg.code, msg.message.slice(0, 160));
  } else if (msg.type === "reading") {
    console.log("  [reading]", msg.verdict, msg.composure, JSON.stringify(msg.parts ?? {}).slice(0, 120));
  } else if (msg.type === "final") {
    console.log("FINAL:", msg.verdict, msg.composure, "framesReceived =", msg.framesReceived, "reason =", msg.reason);
    console.log("sent total =", sent);
    ws.close(); process.exit(0);
  }
});
ws.on("error", (e) => { console.log("socket error:", e.message); process.exit(1); });
setTimeout(() => { console.log("timed out; sent =", sent); process.exit(1); }, (SECONDS + 100) * 1000);
