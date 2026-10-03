/** Round-trip and rejection tests for the frame wire format. */
import assert from "node:assert/strict";
import {
  decodeFrame, encodeFrame, HEADER_BYTES, MAGIC, VERSION, PIXEL_FORMAT_RGB24,
} from "./protocol.mjs";

const width = 8;
const height = 4;
const pixels = Buffer.alloc(width * height * 3, 0x7f);
const good = encodeFrame({ width, height, timestampUs: 1_234_567.5, pixels });

const decoded = decodeFrame(good);
assert.equal(decoded.width, width);
assert.equal(decoded.height, height);
assert.equal(decoded.stride, width * 3);
assert.equal(decoded.pixelFormat, "rgb24");
assert.equal(decoded.timestampUs, 1_234_567.5);
assert.equal(decoded.pixels.length, width * height * 3);
assert.ok(decoded.pixels.every((b) => b === 0x7f));
console.log("round-trip ok");

/** Every rejection must carry a machine-readable code, not just a message. */
function expectCode(code, buf, label) {
  assert.throws(() => decodeFrame(buf), (err) => {
    assert.equal(err.code, code, `${label}: expected code ${code}, got ${err.code}`);
    return true;
  }, label);
  console.log(`rejects ${label.padEnd(22)} -> ${code}`);
}

expectCode("short_frame", Buffer.alloc(HEADER_BYTES - 1), "truncated header");

const badMagic = Buffer.from(good);
badMagic.writeUInt16LE(0x0000, 0);
expectCode("bad_magic", badMagic, "wrong magic");

const badVersion = Buffer.from(good);
badVersion.writeUInt8(VERSION + 9, 2);
expectCode("bad_version", badVersion, "future protocol");

const badFormat = Buffer.from(good);
badFormat.writeUInt8(200, 3);
expectCode("bad_pixel_format", badFormat, "unknown pixel format");

const zeroDims = Buffer.from(good);
zeroDims.writeUInt32LE(0, 4);
expectCode("bad_dimensions", zeroDims, "zero width");

const hugeDims = Buffer.from(good);
hugeDims.writeUInt32LE(99_999, 4);
expectCode("bad_dimensions", hugeDims, "implausible width");

const badTs = Buffer.from(good);
badTs.writeDoubleLE(Number.NaN, 12);
expectCode("bad_timestamp", badTs, "NaN timestamp");

// A frame whose declared size disagrees with its payload is the dangerous case:
// silently passing it on would hand the SDK a buffer overrun.
const shortPayload = Buffer.concat([good.subarray(0, HEADER_BYTES), Buffer.alloc(10)]);
expectCode("payload_size_mismatch", shortPayload, "payload too small");

const longPayload = Buffer.concat([good, Buffer.alloc(3)]);
expectCode("payload_size_mismatch", longPayload, "payload too large");

// Accepts a bare ArrayBuffer / Uint8Array too, since that is what browsers send.
assert.equal(decodeFrame(new Uint8Array(good)).width, width);
const ab = good.buffer.slice(good.byteOffset, good.byteOffset + good.byteLength);
assert.equal(decodeFrame(ab).width, width);
assert.equal(MAGIC, 0x4d53);
assert.equal(PIXEL_FORMAT_RGB24, 0);

console.log("\nall protocol tests passed");
