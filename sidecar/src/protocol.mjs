/**
 * protocol.mjs - the wire format between the Flutter web app and this sidecar.
 *
 * The Flutter side mirrors this in `app/lib/src/casing/frame_codec.dart`.
 * If you change the layout, change it in both places and bump VERSION.
 *
 * Binary message (browser -> sidecar), little-endian:
 *
 *   offset  type     field
 *   ------  -------  -------------------------------------------------
 *   0       uint16   MAGIC (0x4D53, "MS")
 *   2       uint8    VERSION
 *   3       uint8    pixelFormat (0 = RGB24, packed, 3 bytes per pixel)
 *   4       uint32   width
 *   8       uint32   height
 *   12      float64  captureTimestamp, microseconds
 *   20      bytes    pixel payload, length == width * height * 3
 *
 * Text messages (both directions) are JSON, one object per message, with a
 * `type` discriminator. See `sidecar/README.md` for the message list.
 */

export const MAGIC = 0x4d53;
export const VERSION = 1;
export const HEADER_BYTES = 20;

/** pixelFormat wire values -> a name the SDK layer can map to its own enum. */
export const PIXEL_FORMATS = { 0: "rgb24" };
export const PIXEL_FORMAT_RGB24 = 0;

/**
 * Decode a binary frame message.
 * @param {ArrayBuffer|Buffer|Uint8Array} data
 * @returns {{width:number,height:number,stride:number,pixelFormat:string,timestampUs:number,pixels:Buffer}}
 * @throws {Error} with a `code` property on any malformed frame
 */
export function decodeFrame(data) {
  const buf = Buffer.isBuffer(data) ? data : Buffer.from(data);

  if (buf.length < HEADER_BYTES) {
    throw fail("short_frame", `frame is ${buf.length}B, need at least ${HEADER_BYTES}B of header`);
  }

  const magic = buf.readUInt16LE(0);
  if (magic !== MAGIC) {
    throw fail("bad_magic", `expected magic 0x${MAGIC.toString(16)}, got 0x${magic.toString(16)}`);
  }

  const version = buf.readUInt8(2);
  if (version !== VERSION) {
    throw fail("bad_version", `frame protocol v${version}, sidecar speaks v${VERSION}`);
  }

  const pixelFormatId = buf.readUInt8(3);
  const pixelFormat = PIXEL_FORMATS[pixelFormatId];
  if (!pixelFormat) {
    throw fail("bad_pixel_format", `unknown pixel format id ${pixelFormatId}`);
  }

  const width = buf.readUInt32LE(4);
  const height = buf.readUInt32LE(8);
  if (width === 0 || height === 0 || width > 7680 || height > 4320) {
    throw fail("bad_dimensions", `implausible frame dimensions ${width}x${height}`);
  }

  const timestampUs = buf.readDoubleLE(12);
  if (!Number.isFinite(timestampUs) || timestampUs < 0) {
    throw fail("bad_timestamp", `timestamp ${timestampUs} is not a usable microsecond value`);
  }

  const stride = width * 3;
  const expected = stride * height;
  const pixels = buf.subarray(HEADER_BYTES);
  if (pixels.length !== expected) {
    throw fail(
      "payload_size_mismatch",
      `${width}x${height} RGB24 needs ${expected}B of pixels, got ${pixels.length}B`,
    );
  }

  return { width, height, stride, pixelFormat, timestampUs, pixels };
}

/**
 * Encode a frame. Only used by tests and tooling - the browser builds these
 * itself - but keeping the encoder beside the decoder keeps them honest.
 */
export function encodeFrame({ width, height, timestampUs, pixels, pixelFormat = PIXEL_FORMAT_RGB24 }) {
  const header = Buffer.alloc(HEADER_BYTES);
  header.writeUInt16LE(MAGIC, 0);
  header.writeUInt8(VERSION, 2);
  header.writeUInt8(pixelFormat, 3);
  header.writeUInt32LE(width, 4);
  header.writeUInt32LE(height, 8);
  header.writeDoubleLE(timestampUs, 12);
  return Buffer.concat([header, Buffer.isBuffer(pixels) ? pixels : Buffer.from(pixels)]);
}

function fail(code, message) {
  const err = new Error(message);
  err.code = code;
  return err;
}
