/**
 * Tests for the compressed-frame path.
 *
 * The thing that matters is not that JPEG round-trips — it is that the decoded
 * buffer is EXACTLY what the SDK expects. A stride or length mismatch here is a
 * read past the end of a buffer inside native code.
 */
import assert from "node:assert/strict";
import jpeg from "jpeg-js";
import { decodeJpegFrame } from "./jpeg_frame.mjs";
import {
  decodeFrame, encodeFrame, PIXEL_FORMAT_JPEG, PIXEL_FORMAT_RGB24,
} from "./protocol.mjs";

function rgbaFrame(w, h, fn) {
  const b = Buffer.alloc(w * h * 4);
  for (let i = 0, p = 0; i < w * h; i++, p += 4) {
    const [r, g, bl] = fn(i % w, (i / w) | 0);
    b[p] = r; b[p + 1] = g; b[p + 2] = bl; b[p + 3] = 255;
  }
  return b;
}

const W = 320, H = 240;

// --- the wire format carries JPEG and the decoder returns a correct buffer ---
{
  const rgba = rgbaFrame(W, H, () => [200, 150, 120]);
  const enc = jpeg.encode({ data: rgba, width: W, height: H }, 90);
  const wire = encodeFrame({
    width: W, height: H, timestampUs: 1234, pixels: enc.data, pixelFormat: PIXEL_FORMAT_JPEG,
  });

  const frame = decodeFrame(wire);
  assert.equal(frame.pixelFormat, "jpeg");
  assert.equal(frame.timestampUs, 1234);
  assert.ok(frame.pixels.length < W * H * 3, "compressed must be smaller than raw");

  const out = decodeJpegFrame(frame);
  assert.equal(out.width, W);
  assert.equal(out.height, H);
  assert.equal(out.stride, W * 3, "stride must match what the SDK will index by");
  assert.equal(out.pixels.length, W * H * 3, "buffer must be exactly one RGB24 frame");
  assert.equal(out.timestampUs, 1234, "timestamp must survive decoding");

  // Colour must survive well enough to be a pulse signal.
  for (const [i, expected] of [[0, 200], [1, 150], [2, 120]]) {
    assert.ok(Math.abs(out.pixels[i] - expected) <= 3,
      `channel ${i}: ${out.pixels[i]} drifted from ${expected}`);
  }
  console.log(`jpeg round-trip ok  ${(frame.pixels.length / 1024).toFixed(1)}KB vs ${(W * H * 3 / 1024).toFixed(0)}KB raw`);
}

// --- raw frames are unaffected by the new branch ----------------------------
{
  const raw = Buffer.alloc(W * H * 3, 0x44);
  const wire = encodeFrame({ width: W, height: H, timestampUs: 7, pixels: raw });
  const frame = decodeFrame(wire);
  assert.equal(frame.pixelFormat, "rgb24");
  assert.equal(frame.pixels.length, W * H * 3);
  console.log("raw path unaffected");
}

// --- a raw frame of the wrong size is still rejected ------------------------
{
  const wire = encodeFrame({ width: W, height: H, timestampUs: 1, pixels: Buffer.alloc(W * H * 3) });
  const truncated = Buffer.concat([wire.subarray(0, 20), Buffer.alloc(10)]);
  assert.throws(() => decodeFrame(truncated), (e) => e.code === "payload_size_mismatch");
  console.log("undersized raw frame still rejected");
}

// --- compressed frames get their own sanity limits --------------------------
{
  const empty = encodeFrame({
    width: W, height: H, timestampUs: 1, pixels: Buffer.from([1]), pixelFormat: PIXEL_FORMAT_JPEG,
  });
  // Strip the single payload byte to make it genuinely empty.
  assert.throws(() => decodeFrame(empty.subarray(0, 20)),
    (e) => e.code === "payload_size_mismatch", "empty compressed payload must be refused");

  const absurd = encodeFrame({
    width: W, height: H, timestampUs: 1,
    pixels: Buffer.alloc(W * H * 3 + 1), pixelFormat: PIXEL_FORMAT_JPEG,
  });
  assert.throws(() => decodeFrame(absurd),
    (e) => e.code === "payload_size_mismatch",
    "a 'compressed' frame larger than raw must be refused");
  console.log("compressed frame limits enforced");
}

// --- garbage must throw, not crash the process ------------------------------
{
  const junk = encodeFrame({
    width: W, height: H, timestampUs: 1,
    pixels: Buffer.from([0xff, 0xd8, 0xff, 0x00, 0x11, 0x22]), pixelFormat: PIXEL_FORMAT_JPEG,
  });
  const frame = decodeFrame(junk);
  assert.throws(() => decodeJpegFrame(frame), "corrupt JPEG must throw rather than return nonsense");
  console.log("corrupt jpeg throws cleanly");
}

assert.equal(PIXEL_FORMAT_RGB24, 0);
assert.equal(PIXEL_FORMAT_JPEG, 1);
console.log("\nall jpeg frame tests passed");
