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

  /// True when the camera exists but something else already holds it — another
  /// tab running this app, a video call, or any other program using the webcam.
  /// Common and user-fixable, so it earns its own message rather than leaking
  /// the browser's `NotReadableError`.
  bool get isInUse => name == 'NotReadableError' || name == 'TrackStartError';

  @override
  String toString() => '$name: $message';
}

/// One camera the browser will admit to having.
typedef CameraOption = ({String id, String label});

/// Captures webcam frames in the browser and converts them to packed RGB24.
///
/// The browser keeps ownership of the camera; frames go to the sidecar, which
/// holds the Presage SDK. See `docs/ARCHITECTURE.md` for why it is split.
class WebcamSource {
  WebcamSource({
    this.width = 640,
    this.height = 480,
    this.fps = 15,
    this.deviceId,
  });

  /// Which camera to open, or null to let the browser choose.
  ///
  /// Letting it choose is wrong often enough to be worth overriding: a laptop
  /// can expose several video inputs - an infrared sensor for face unlock, a
  /// vendor pipeline, the actual colour camera - and `facingMode: 'user'` does
  /// not distinguish them. Picking the wrong one yields a near-black image that
  /// looks like a broken app and is really just the wrong device.
  String? deviceId;

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

  /// The cameras available to this page.
  ///
  /// Labels are empty until camera permission has been granted at least once,
  /// so this is worth calling after [start], not before.
  static Future<List<CameraOption>> listCameras() async {
    final devices = await web.window.navigator.mediaDevices.enumerateDevices().toDart;
    final out = <CameraOption>[];
    for (final device in devices.toDart) {
      if (device.kind != 'videoinput') continue;
      final label = device.label.isEmpty ? 'Camera ${out.length + 1}' : device.label;
      out.add((id: device.deviceId, label: label));
    }
    return out;
  }

  web.MediaStreamTrack? get _videoTrack {
    final tracks = _stream?.getVideoTracks().toDart;
    return (tracks == null || tracks.isEmpty) ? null : tracks.first;
  }

  /// The camera that actually opened - not necessarily the one that was asked
  /// for, since a non-exact constraint is only a preference.
  String? get activeDeviceId => _videoTrack?.getSettings().deviceId;

  /// Its human-readable name, for showing the user which camera is in use.
  String? get activeLabel {
    final label = _videoTrack?.label;
    return (label == null || label.isEmpty) ? null : label;
  }

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

    // `exact` on an explicit choice: a preference would silently fall back to
    // the same wrong camera the user is trying to get away from. Without a
    // choice, keep the front-facing preference.
    // Presage refuses to produce metrics below 25fps, so ask for the floor as a
    // hard `min` rather than hoping. A soft `ideal` let the browser hand back
    // 15fps, and the measurement then ran its full window and resolved nothing.
    Map<String, Object> constraintsFor({required bool enforceMinFps}) => {
          'width': {'ideal': width},
          'height': {'ideal': height},
          'frameRate': enforceMinFps ? {'ideal': fps, 'min': 25} : {'ideal': fps},
          if (deviceId != null) 'deviceId': {'exact': deviceId} else 'facingMode': 'user',
        };

    Future<web.MediaStream> open(Map<String, Object> video) => web.window
        .navigator.mediaDevices
        .getUserMedia(web.MediaStreamConstraints(video: video.jsify()!, audio: false.toJS))
        .toDart;

    try {
      _stream = await open(constraintsFor(enforceMinFps: true));
    } catch (e) {
      // A camera with no >=25fps mode fails the hard constraint outright. Opening
      // anyway beats refusing to run: the reading will not land, but the user
      // sees their own framing and Presage's own "at least 25 frames per second"
      // hint, which is a far better diagnosis than a dead preview.
      try {
        _stream = await open(constraintsFor(enforceMinFps: false));
      } catch (_) {
        throw _asCameraError(e);
      }
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
    // A paused video hands back the frame before it, forever. Presage reads a
    // pulse from how the picture changes, so duplicates are worse than sending
    // nothing: they look like a perfectly still subject, and the window closes
    // on a confident-looking reading of a single still frame.
    //
    // CameraPreview keeps the element playing through the re-parenting that
    // mounting a platform view does. This is the backstop for anything else
    // that pauses it, and it fails loudly (no frames) rather than quietly
    // (wrong frames).
    if (video.paused) return null;

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
