/**
 * Decodes JPEG frames back to the packed RGB24 the SmartSpectra SDK expects.
 *
 * Why frames are compressed at all: raw RGB cannot cross a network. Measured
 * against the hosted service, 640x480 RGB24 at 30fps is 27.6 MB/s while the
 * real upload to Cloud Run was 3.5 MB/s, so almost no frames arrived and
 * Presage produced no validation output at all — it had nothing to look at.
 *
 * This is lossy, and that is a real risk rather than a detail: Presage recovers
 * a pulse from roughly 1% colour changes in skin, which is exactly what
 * quantisation attacks. Loopback therefore stays on rgb24, and compression is
 * used only where raw is impossible. Readings taken over a compressed link
 * should be compared against a local raw reading before they are trusted.
 */
import jpeg from "jpeg-js";

/** Guard against a decompression bomb: a frame claiming absurd dimensions. */
const MAX_PIXELS = 1920 * 1080;

/**
 * @param {{pixels: Buffer, width: number, height: number, timestampUs: number}} frame
 * @returns {{pixels: Buffer, width: number, height: number, stride: number, timestampUs: number}}
 */
export function decodeJpegFrame(frame) {
  const decoded = jpeg.decode(frame.pixels, { useTArray: true });

  if (decoded.width * decoded.height > MAX_PIXELS) {
    throw new Error(`decoded frame is implausibly large: ${decoded.width}x${decoded.height}`);
  }

  // Trust the JPEG's own dimensions over the header's: if they disagree, the
  // header is the untrusted half, and handing the SDK a stride that does not
  // match the buffer is how you get a read past the end of it.
  const { width, height, data } = decoded;
  const pixelCount = width * height;

  // jpeg-js emits RGBA; the SDK wants packed RGB24. Done in one pass without
  // per-pixel allocation, because this runs 30 times a second.
  const rgb = Buffer.allocUnsafe(pixelCount * 3);
  let src = 0;
  let dst = 0;
  for (let i = 0; i < pixelCount; i++) {
    rgb[dst] = data[src];
    rgb[dst + 1] = data[src + 1];
    rgb[dst + 2] = data[src + 2];
    src += 4;
    dst += 3;
  }

  return {
    pixels: rgb,
    width,
    height,
    stride: width * 3,
    timestampUs: frame.timestampUs,
  };
}
