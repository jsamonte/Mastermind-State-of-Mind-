import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../config.dart';
import '../models.dart';
import 'frame_codec.dart';

/// Why a casing stopped. Anything other than [windowElapsed] means the reading
/// is incomplete, and incomplete never opens the vault.
enum CasingEnd { windowElapsed, clientEnded, disconnected, failed }

/// A problem reported by the sidecar. `fatal` means the session is over.
class SidecarError {
  const SidecarError(this.code, this.message, {this.fatal = false});
  final String code;
  final String message;
  final bool fatal;

  @override
  String toString() => '[$code] $message';
}

/// Talks to the Presage sidecar over a loopback WebSocket.
///
/// The sidecar exists because SmartSpectra has no browser SDK — see
/// `docs/ARCHITECTURE.md`. This class owns the socket and the message protocol;
/// it does not touch the camera. [WebcamSource] does that and hands frames here.
class SidecarClient {
  SidecarClient({String? url}) : url = url ?? Config.sidecarUrl;

  final String url;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;

  final _readings = StreamController<Reading>.broadcast();
  final _errors = StreamController<SidecarError>.broadcast();
  final _status = StreamController<String>.broadcast();

  Completer<void>? _ready;
  Completer<Reading>? _final;

  /// Live readings during a casing, roughly twice a second.
  Stream<Reading> get readings => _readings.stream;

  /// Errors from the sidecar — bad frames, SDK faults, startup failures.
  Stream<SidecarError> get errors => _errors.stream;

  /// Human-readable pipeline status, including Presage's validation hints
  /// ("face not centred", "too dark") which are genuinely useful to surface.
  Stream<String> get status => _status.stream;

  bool get isConnected => _channel != null;

  /// Which source the sidecar is running: `smartspectra` or `mock`.
  String? sourceMode;

  /// Connects and waits for the sidecar's `ready` handshake.
  ///
  /// Throws [SidecarError] if the sidecar is not running — which is the common
  /// case worth a good message, since the whole app is useless without it.
  Future<void> connect({Duration timeout = const Duration(seconds: 5)}) async {
    if (_channel != null) return;

    _ready = Completer<void>();
    try {
      final channel = WebSocketChannel.connect(Uri.parse(url));
      _channel = channel;
      _sub = channel.stream.listen(
        _onMessage,
        onError: (Object e) => _fail(SidecarError('socket_error', '$e', fatal: true)),
        onDone: () => _fail(
          SidecarError('disconnected', 'The sidecar closed the connection.', fatal: true),
        ),
        cancelOnError: false,
      );
      await _ready!.future.timeout(timeout);
    } on TimeoutException {
      await disconnect();
      throw const SidecarError(
        'no_sidecar',
        'No reply from the Presage sidecar. Start it with `npm start` in sidecar/.',
        fatal: true,
      );
    } catch (e) {
      await disconnect();
      if (e is SidecarError) rethrow;
      throw SidecarError('connect_failed', '$e', fatal: true);
    }
  }

  /// Starts a casing and completes with the final reading when the window ends.
  ///
  /// Frames must be pushed with [sendFrame] for the duration, or the reading
  /// will come back inconclusive.
  Future<Reading> beginCasing({
    required Blueprint blueprint,
  }) async {
    final channel = _channel;
    if (channel == null) {
      throw const SidecarError('not_connected', 'Connect to the sidecar first.');
    }
    if (_final != null && !_final!.isCompleted) {
      throw const SidecarError('already_casing', 'A casing is already running.');
    }

    _final = Completer<Reading>();
    channel.sink.add(jsonEncode({
      'type': 'begin',
      'durationMs': blueprint.casingSeconds * 1000,
      'thresholds': {'green': blueprint.green, 'amber': blueprint.amber},
    }));
    return _final!.future;
  }

  /// Asks the sidecar to stop early. The pending [beginCasing] future still
  /// completes, with whatever reading was reached.
  void endCasing() {
    _channel?.sink.add(jsonEncode({'type': 'end'}));
  }

  /// Pushes one RGB24 frame. Cheap enough to call at 15fps.
  void sendFrame({
    required int width,
    required int height,
    required Uint8List rgb,
    required double timestampUs,
  }) {
    final channel = _channel;
    if (channel == null) return;
    channel.sink.add(FrameCodec.encode(
      width: width,
      height: height,
      timestampUs: timestampUs,
      pixels: rgb,
    ));
  }

  void _onMessage(dynamic raw) {
    if (raw is! String) return; // the sidecar only sends text
    final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    switch (msg['type']) {
      case 'ready':
        sourceMode = msg['source'] as String?;
        if (_ready != null && !_ready!.isCompleted) _ready!.complete();
        final scenario = msg['scenario'];
        _status.add(sourceMode == 'mock'
            ? 'Sidecar ready — MOCK source${scenario == null ? '' : ' ($scenario)'}'
            : 'Sidecar ready — Presage SmartSpectra');

      case 'casing':
        _status.add('Casing the vault…');

      case 'reading':
        _readings.add(Reading.fromJson(msg));

      case 'final':
        final reading = Reading.fromJson(msg);
        _readings.add(reading);
        if (_final != null && !_final!.isCompleted) _final!.complete(reading);

      case 'status':
        // Presage's validation hints are the useful half of this stream.
        final hint = msg['hint'] ?? msg['status'] ?? msg['note'];
        if (hint != null) _status.add('$hint');

      case 'error':
        final err = SidecarError(
          '${msg['code'] ?? 'error'}',
          '${msg['message'] ?? 'Unknown sidecar error'}',
          fatal: msg['fatal'] == true,
        );
        _errors.add(err);
        if (err.fatal && _final != null && !_final!.isCompleted) {
          _final!.completeError(err);
        }
    }
  }

  void _fail(SidecarError err) {
    _errors.add(err);
    if (_ready != null && !_ready!.isCompleted) _ready!.completeError(err);
    if (_final != null && !_final!.isCompleted) _final!.completeError(err);
  }

  Future<void> disconnect() async {
    await _sub?.cancel();
    _sub = null;
    await _channel?.sink.close();
    _channel = null;
  }

  Future<void> dispose() async {
    await disconnect();
    await _readings.close();
    await _errors.close();
    await _status.close();
  }
}
