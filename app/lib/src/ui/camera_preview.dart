import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

/// Shows the live camera feed by handing the browser's own `<video>` element to
/// Flutter as a platform view.
///
/// The preview is not decoration: Presage is reading colour change in skin, so
/// a user who is half out of frame or badly lit gets a useless reading and no
/// idea why. Showing them the framing is the cheapest possible fix.
class CameraPreview extends StatefulWidget {
  const CameraPreview({super.key, required this.video});

  /// The element [WebcamSource] is already pumping frames from.
  final web.HTMLVideoElement video;

  @override
  State<CameraPreview> createState() => _CameraPreviewState();
}

class _CameraPreviewState extends State<CameraPreview> {
  /// Each element needs its own view type, and a view type can only be
  /// registered once per page — re-registering throws.
  static final Set<String> _registered = <String>{};
  late String _viewType;

  @override
  void initState() {
    super.initState();
    _register();
  }

  @override
  void didUpdateWidget(CameraPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.video != widget.video) _register();
  }

  void _register() {
    _viewType = 'mastermind-camera-${identityHashCode(widget.video)}';
    if (_registered.add(_viewType)) {
      ui_web.platformViewRegistry.registerViewFactory(
        _viewType,
        (int viewId) {
          final el = widget.video;
          el.style
            ..position = 'static'
            ..left = '0'
            ..top = '0'
            ..width = '100%'
            ..height = '100%'
            ..objectFit = 'cover'
            // Mirror it. An unmirrored self-view reads as wrong to everyone.
            ..transform = 'scaleX(-1)';
          _keepPlaying(el);
          return el;
        },
      );
    }
  }

  /// Returning the element from the view factory re-parents it into
  /// `<flt-platform-view>`, which removes it from the document first — and the
  /// HTML spec requires the user agent to pause a media element when it is
  /// removed. `autoplay` does not undo that.
  ///
  /// The consequence was not merely a frozen preview. [WebcamSource] grabs its
  /// frames from this same element, so a paused video meant Presage was fed one
  /// identical still — captured ~50ms in, before auto-exposure had settled, so
  /// also very dark — for the entire window. No colour change means no pulse,
  /// which is an `inconclusive` no amount of sitting still could fix.
  static void _keepPlaying(web.HTMLVideoElement el) {
    void resume() {
      final provider = el.srcObject;
      if (provider == null) return;
      final tracks = (provider as web.MediaStream).getVideoTracks().toDart;
      // Never fight a deliberate stop(): once the track has ended the element
      // is being torn down and must stay paused, or the camera light lingers.
      if (tracks.isEmpty || tracks.first.readyState != 'live') return;
      el.play().toDart.catchError((Object _) => null);
    }

    el.onpause = ((web.Event _) => resume()).toJS;
    resume();
  }

  @override
  Widget build(BuildContext context) => HtmlElementView(viewType: _viewType);
}
