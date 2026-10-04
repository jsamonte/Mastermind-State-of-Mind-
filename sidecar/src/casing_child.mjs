/**
 * One measurement, in a process of its own.
 *
 * The SmartSpectra native calls - `start()` and every `sendFrame()` - are
 * synchronous, so they run ON the Node event loop rather than beside it. When
 * the SDK blocks internally (it does: a measurement stalls partway through
 * authentication or an upload and never returns), it takes the whole process
 * with it. In the single-process design that process was also the HTTP and
 * WebSocket server, so one stalled measurement stopped the sidecar answering
 * anything at all - health checks included - and the hosted site went dead for
 * everyone until someone restarted it by hand.
 *
 * Here the SDK gets its own process. If it wedges, the parent notices the
 * silence, kills it, and tells that one person their reading failed. Everybody
 * else keeps measuring. A blocked SDK cannot be unblocked, but it can be
 * contained, and containing it is the difference between one lost reading and a
 * dead service.
 *
 * Wire protocol, both directions, deliberately dumb:
 *
 *   parent -> child  (stdin)   uint32LE length, then that many bytes: one frame
 *                              in the browser's own wire format, forwarded
 *                              verbatim so JPEG decoding happens over here too.
 *   child  -> parent (stdout)  one JSON object per line.
 *
 * stderr is left alone so the SDK's native logging still reaches the terminal.
 */
import { createSmartSpectraSource } from "./smartspectra.mjs";
import { decodeFrame } from "./protocol.mjs";
import { decodeJpegFrame } from "./jpeg_frame.mjs";

/** One JSON line out. Never throws: a dead pipe must not fault the measurement. */
function emit(obj) {
  try {
    process.stdout.write(`${JSON.stringify(obj)}\n`);
  } catch {
    /* parent has gone; nothing useful left to do */
  }
}

let source = null;
let stopping = false;

/**
 * Frame reassembly.
 *
 * A pipe is a byte stream with no message boundaries, which is the one thing
 * the WebSocket gave us for free. Hence the length prefix, and hence buffering
 * until a whole frame has arrived.
 */
let pending = Buffer.alloc(0);

function consume() {
  for (;;) {
    if (pending.length < 4) return;
    const length = pending.readUInt32LE(0);
    // A corrupt length would have us allocate wildly or wait forever. Neither
    // is recoverable mid-stream, so fail loudly instead of limping.
    if (length === 0 || length > 64 * 1024 * 1024) {
      emit({ t: "error", code: "bad_length", message: `frame length ${length}`, fatal: true });
      process.exit(2);
    }
    if (pending.length < 4 + length) return;

    const raw = pending.subarray(4, 4 + length);
    pending = pending.subarray(4 + length);

    if (!source || stopping) continue;
    try {
      const frame = decodeFrame(raw);
      const pixels = frame.pixelFormat === "jpeg" ? decodeJpegFrame(frame) : frame;
      if (source.sendFrame(pixels) === false) emit({ t: "refused" });
      else emit({ t: "accepted" });
    } catch (err) {
      emit({ t: "frame_error", message: String(err?.message ?? err) });
    }
  }
}

process.stdin.on("data", (chunk) => {
  pending = pending.length ? Buffer.concat([pending, chunk]) : chunk;
  consume();
});

// The parent closing the pipe is the normal way a casing ends.
process.stdin.on("end", () => void shutdown(0));

async function shutdown(code) {
  if (stopping) return;
  stopping = true;
  try {
    await source?.stop();
  } catch {
    /* best effort - we are leaving anyway */
  }
  try {
    await source?.destroy();
  } catch {
    /* ditto */
  }
  emit({ t: "stopped" });
  // Not process.exit(): give stdout a moment to flush the last line. The parent
  // kills us if we overstay, so a hung teardown still cannot hold things up.
  process.exitCode = code;
  setTimeout(() => process.exit(code), 1500).unref();
}

try {
  source = await createSmartSpectraSource({
    apiKey: process.env.PRESAGE_API_KEY,
    onSignals: (signals) => emit({ t: "signals", signals }),
    onStatus: (status) => emit({ t: "status", status }),
    onError: (error) => emit({ t: "error", ...error }),
  });
  await source.start();
  emit({ t: "ready" });
} catch (err) {
  emit({
    t: "error",
    code: err?.code ?? "source_start_failed",
    message: String(err?.message ?? err),
    fatal: true,
  });
  process.exit(1);
}
