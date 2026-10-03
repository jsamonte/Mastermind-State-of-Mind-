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
          return el;
        },
      );
    }
  }

  @override
  Widget build(BuildContext context) => HtmlElementView(viewType: _viewType);
}
