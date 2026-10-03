import 'dart:typed_data';

/// Mirror of `sidecar/src/protocol.mjs`. If you change the layout, change it in
/// both places and bump [protocolVersion] — the sidecar rejects mismatches with
/// a `bad_version` error rather than misreading pixels.
///
/// Binary layout, little-endian:
///
///   offset  type     field
///   ------  -------  ---------------------------------------
///   0       uint16   magic (0x4D53, "MS")
///   2       uint8    version
///   3       uint8    pixelFormat (0 = RGB24)
///   4       uint32   width
///   8       uint32   height
///   12      float64  capture timestamp, microseconds
///   20      bytes    pixels, width * height * 3
class FrameCodec {
  static const int magic = 0x4D53;
  static const int protocolVersion = 1;
  static const int headerBytes = 20;
  static const int pixelFormatRgb24 = 0;

  /// Builds one wire frame from packed RGB24 [pixels].
  ///
  /// Throws [ArgumentError] if [pixels] does not match the declared dimensions,
  /// because the sidecar would reject it anyway and a local failure is easier to
  /// debug than a socket error.
  static Uint8List encode({
    required int width,
    required int height,
    required double timestampUs,
    required Uint8List pixels,
  }) {
    final expected = width * height * 3;
    if (pixels.length != expected) {
      throw ArgumentError(
        'expected $expected bytes of RGB24 for ${width}x$height, got ${pixels.length}',
      );
    }

    final out = Uint8List(headerBytes + pixels.length);
    final header = ByteData.sublistView(out, 0, headerBytes);
    header.setUint16(0, magic, Endian.little);
    header.setUint8(2, protocolVersion);
    header.setUint8(3, pixelFormatRgb24);
    header.setUint32(4, width, Endian.little);
    header.setUint32(8, height, Endian.little);
    header.setFloat64(12, timestampUs, Endian.little);
    out.setRange(headerBytes, out.length, pixels);
    return out;
  }

  /// Strips the alpha channel from canvas `getImageData` output (RGBA) to the
  /// packed RGB24 the SmartSpectra SDK expects.
  ///
  /// This runs on every frame, so it avoids per-pixel bounds checks and
  /// allocations — a naive version is measurably slower at 640x480x15fps.
  static Uint8List rgbaToRgb24(Uint8List rgba, int width, int height) {
    final pixelCount = width * height;
    if (rgba.length < pixelCount * 4) {
      throw ArgumentError(
        'RGBA buffer holds ${rgba.length} bytes, need ${pixelCount * 4} for ${width}x$height',
      );
    }

    final rgb = Uint8List(pixelCount * 3);
    var src = 0;
    var dst = 0;
    for (var i = 0; i < pixelCount; i++) {
      rgb[dst] = rgba[src];
      rgb[dst + 1] = rgba[src + 1];
      rgb[dst + 2] = rgba[src + 2];
      src += 4;
      dst += 3;
    }
    return rgb;
  }
}
