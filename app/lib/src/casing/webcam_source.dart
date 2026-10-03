import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'frame_codec.dart';

/// Thrown when the camera cannot be opened. The browser's own error names are
/// worth preserving — `NotAllowedError` and `NotFoundError` need very different
/// advice from the UI.
class CameraError implements Exception {
  const CameraError(this.name, this.message);
  final String name;
  final String message;

  /// True when the user denied (or has previously denied) permission.
  bool get isPermissionDenied =>
      name == 'NotAllowedError' || name == 'PermissionDeniedError';

  /// True when there simply is no camera.
  bool get isMissingDevice => name == 'NotFoundError' || name == 'DevicesNotFoundError';

  @override
  String toString() => '$name: $message';
}

/// Captures webcam frames in the browser and converts them to packed RGB24.
///
/// The browser keeps ownership of the camera; frames go to the sidecar, which
/// holds the Presage SDK. See `docs/ARCHITECTURE.md` for why it is split.
class WebcamSource {
  WebcamSource({
    this.width = 640,
    this.height = 480,
    this.fps = 15,
  });

  /// Capture size. Presage is doing remote photoplethysmography — recovering a
  /// pulse from colour changes in skin — so resolution and light matter. 640x480
  /// at 15fps is about 13 MB/s over loopback, which is fine locally.
  final int width;
  final int height;
  final int fps;

  web.MediaStream? _stream;
  web.HTMLVideoElement? _video;
  web.HTMLCanvasElement? _canvas;
  web.CanvasRenderingContext2D? _ctx;
  Timer? _timer;
  int? _startedAtUs;

  bool get isRunning => _timer != null;

  /// The live video element, so the UI can show the user what the camera sees.
  /// Framing feedback is most of the difference between a good and bad reading.
  web.HTMLVideoElement? get videoElement => _video;

  /// Opens the camera and begins pumping frames to [onFrame].
  ///
  /// Throws [CameraError] on permission denial or missing hardware.
  Future<void> start({
    required void Function(Uint8List rgb, int width, int height, double timestampUs) onFrame,
  }) async {
    if (_timer != null) return;

    final constraints = web.MediaStreamConstraints(
      video: {
        'width': {'ideal': width},
        'height': {'ideal': height},
        'frameRate': {'ideal': fps},
        'facingMode': 'user',
      }.jsify()!,
      audio: false.toJS,
    );

    try {
      _stream = await web.window.navigator.mediaDevices
          .getUserMedia(constraints)
          .toDart;
    } catch (e) {
      throw _asCameraError(e);
    }

    final video = web.document.createElement('video') as web.HTMLVideoElement
      ..autoplay = true
      ..muted = true
      ..setAttribute('playsinline', 'true')
      ..srcObject = _stream;

    // Some browsers will not decode frames for a video that is not in the
    // document, which shows up as a canvas full of black. Keep it attached but
    // out of the way; the UI shows its own preview.
    video.style
      ..position = 'fixed'
      ..left = '-10000px'
      ..top = '0'
      ..width = '1px'
      ..height = '1px';
    web.document.body!.append(video);
    _video = video;

    await _waitForFirstFrame(video);

    _canvas = web.document.createElement('canvas') as web.HTMLCanvasElement
      ..width = width
      ..height = height;
    _ctx = _canvas!.getContext('2d') as web.CanvasRenderingContext2D;

    _startedAtUs = DateTime.now().microsecondsSinceEpoch;
    final interval = Duration(microseconds: (1000000 / fps).round());
    _timer = Timer.periodic(interval, (_) {
      final frame = _grab();
      if (frame != null) {
        onFrame(frame, width, height, _elapsedUs());
      }
    });
  }

  /// Waits until the video actually has pixels. `loadedmetadata` fires before
  /// the first frame is decodable, so drawing immediately yields black frames —
  /// which the SDK dutifully analyses into a useless reading.
  Future<void> _waitForFirstFrame(web.HTMLVideoElement video) async {
    final ready = Completer<void>();

    void done() {
      if (!ready.isCompleted) ready.complete();
    }

    if (video.readyState >= 2 && video.videoWidth > 0) {
      done();
    } else {
      // Event handlers are JS functions on the interop types, so they need .toJS.
      video.onloadeddata = ((web.Event _) => done()).toJS;
      video.oncanplay = ((web.Event _) => done()).toJS;
    }

    try {
      await video.play().toDart;
    } catch (_) {
      // Autoplay rejection is survivable for a muted stream; the readyState
      // check below is what actually matters.
    }

    await ready.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw const CameraError(
        'NoFrames',
        'The camera opened but never produced a frame.',
      ),
    );
  }

  double _elapsedUs() =>
      (DateTime.now().microsecondsSinceEpoch - (_startedAtUs ?? 0)).toDouble();

  /// Draws the current video frame and returns it as packed RGB24.
  /// Returns null when the video has no pixels yet.
  Uint8List? _grab() {
    final video = _video;
    final ctx = _ctx;
    if (video == null || ctx == null) return null;
    if (video.videoWidth == 0 || video.videoHeight == 0) return null;

    ctx.drawImage(video, 0, 0, width.toDouble(), height.toDouble());
    final data = ctx.getImageData(0, 0, width, height).data.toDart;
    final rgba = Uint8List.view(data.buffer, data.offsetInBytes, data.lengthInBytes);
    return FrameCodec.rgbaToRgb24(rgba, width, height);
  }

  /// Stops capture and releases the camera. Safe to call repeatedly.
  ///
  /// Stopping every track matters: a webcam light left on after a composure
  /// check is exactly the kind of thing that destroys trust in an app like this.
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;

    final tracks = _stream?.getTracks().toDart;
    if (tracks != null) {
      for (final track in tracks) {
        track.stop();
      }
    }
    _stream = null;

    _video?.remove();
    _video = null;
    _canvas = null;
    _ctx = null;
  }

  CameraError _asCameraError(Object e) {
    // DOMException carries the useful discriminator in `name`. Interop types
    // need isA<>() rather than `is`, which is not platform-consistent.
    // A rejected JS promise hands us an untyped Object, so discriminating it at
    // runtime is the whole job here; isA<>() narrows it once we know it is JS.
    // ignore: invalid_runtime_check_with_js_interop_types
    if (e is JSObject && e.isA<web.DOMException>()) {
      final dom = e as web.DOMException;
      return CameraError(dom.name, dom.message);
    }
    final text = '$e';
    for (final known in const [
      'NotAllowedError',
      'NotFoundError',
      'NotReadableError',
      'OverconstrainedError',
      'SecurityError',
    ]) {
      if (text.contains(known)) return CameraError(known, text);
    }
    return CameraError('CameraError', text);
  }
}
