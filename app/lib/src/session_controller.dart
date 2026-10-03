import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import 'casing/sidecar_client.dart';
import 'casing/webcam_source.dart';
import 'config.dart';
import 'counsel/counsel_client.dart';
import 'models.dart';

/// Where the session is.
enum SessionPhase {
  /// Nothing started yet.
  idle,

  /// Camera opening and sidecar handshaking.
  starting,

  /// Camera live, Presage measuring, stats streaming.
  measuring,

  /// Measurement done; the conversation is open.
  talking,

  failed,
}

/// Drives the whole experience: camera on, Presage measuring, stats live, then
/// a conversation that opens itself with the state assessment.
///
/// There is one screen and one session. No jobs, no lists, no navigation.
class SessionController extends ChangeNotifier {
  SessionController({
    SidecarClient? sidecar,
    WebcamSource? camera,
    CounselClient? counsel,
    this.onReading,
  })  : _sidecar = sidecar ?? SidecarClient(),
        _counsel = counsel ?? CounselClient(),
        _camera = camera ??
            WebcamSource(
              width: Config.captureWidth,
              height: Config.captureHeight,
              fps: Config.captureFps,
            );

  final SidecarClient _sidecar;
  final WebcamSource _camera;
  final CounselClient _counsel;

  /// Called once with the final reading, for persistence. Null when the user is
  /// not signed into Firebase. Failures here are logged and swallowed —
  /// persistence must never break the measurement the user is looking at.
  final Future<void> Function(Reading reading)? onReading;

  SessionPhase phase = SessionPhase.idle;

  /// The most recent reading — live during measurement, final afterwards.
  Reading? reading;

  String? statusLine;
  String? errorMessage;

  final List<CounselTurn> turns = [];
  bool awaitingReply = false;

  bool _mock = false;

  web.HTMLVideoElement? get videoElement => _camera.videoElement;
  bool get cameraLive => _camera.isRunning;
  bool get sourceIsMock => _mock;

  StreamSubscription<Reading>? _readingSub;
  StreamSubscription<String>? _statusSub;
  StreamSubscription<SidecarError>? _errorSub;

  /// Opens the camera, measures, then opens the conversation. One call runs the
  /// whole flow; the UI just watches.
  Future<void> start() async {
    if (phase == SessionPhase.starting || phase == SessionPhase.measuring) return;

    phase = SessionPhase.starting;
    errorMessage = null;
    reading = null;
    turns.clear();
    statusLine = 'Connecting…';
    notifyListeners();

    try {
      await _sidecar.connect();
      _mock = _sidecar.sourceMode == 'mock';
    } catch (e) {
      _fail(e is SidecarError
          ? e.message
          : 'Could not reach the sidecar. Start it with `npm start` in sidecar/.');
      return;
    }

    _readingSub = _sidecar.readings.listen((r) {
      reading = r;
      notifyListeners();
    });
    _statusSub = _sidecar.status.listen((s) {
      statusLine = s;
      notifyListeners();
    });
    _errorSub = _sidecar.errors.listen((e) {
      // Presage's validation hints ("Place more of the chest in view.") are the
      // only feedback that tells someone how to FIX a failing measurement.
      // Retryable SDK noise must not overwrite them — doing so replaced the one
      // useful instruction with "SmartSpectra is not in a valid state", which
      // is both unactionable and alarming.
      if (e.fatal) {
        errorMessage = e.message;
        notifyListeners();
      } else {
        debugPrint('Mastermind: non-fatal sidecar error: ${e.code} ${e.message}');
      }
    });

    try {
      statusLine = 'Opening the camera…';
      notifyListeners();

      await _camera.start(onFrame: (rgb, w, h, ts) {
        _sidecar.sendFrame(width: w, height: h, rgb: rgb, timestampUs: ts);
      });

      phase = SessionPhase.measuring;
      statusLine = 'Hold still. Good light. Face in frame.';
      notifyListeners();

      final finalReading = await _sidecar.beginCasing(blueprint: const Blueprint());
      reading = finalReading;
      phase = SessionPhase.talking;
      statusLine = null;
      notifyListeners();

      // Persist before talking, so the record exists even if the model is slow
      // or unreachable. Never let a storage failure surface as a broken session.
      try {
        await onReading?.call(finalReading);
      } catch (e) {
        debugPrint('Mastermind: could not record the reading: $e');
      }

      await _openConversation(finalReading);
    } on CameraError catch (e) {
      _fail(e.isPermissionDenied
          ? 'Camera permission denied. Mastermind cannot read your state without it.'
          : e.isMissingDevice
              ? 'No camera found.'
              : 'Camera problem — $e');
    } catch (e) {
      _fail(e is SidecarError ? e.message : '$e');
    }
    // The camera deliberately stays live through the conversation: seeing
    // yourself is part of the point. It is stopped on restart and on dispose,
    // and the UI shows a live indicator so it is never ambiguous.
  }

  /// Gemini speaks first: the state assessment, then the question.
  Future<void> _openConversation(Reading r) async {
    awaitingReply = true;
    notifyListeners();
    try {
      final reply = await _counsel.next(reading: r);
      turns.add(CounselTurn(role: 'assistant', text: reply));
    } on CounselError catch (e) {
      turns.add(CounselTurn(
        role: 'assistant',
        text: e.isDisabled
            ? 'The conversation is not configured — set GEMINI_API_KEY in sidecar/.env.'
            : 'I could not reach the model: ${e.message}',
        failed: true,
      ));
    } finally {
      awaitingReply = false;
      notifyListeners();
    }
  }

  /// Sends one message and appends the reply.
  Future<void> send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || awaitingReply) return;
    final current = reading;
    if (current == null) return;

    turns.add(CounselTurn(role: 'user', text: trimmed));
    awaitingReply = true;
    notifyListeners();

    try {
      final reply = await _counsel.next(reading: current, history: turns);
      turns.add(CounselTurn(role: 'assistant', text: reply));
    } on CounselError catch (e) {
      turns.add(CounselTurn(role: 'assistant', text: e.message, failed: true));
    } finally {
      awaitingReply = false;
      notifyListeners();
    }
  }

  /// Re-measures: back to the camera for another reading, keeping nothing.
  Future<void> restart() async {
    await _teardown();
    phase = SessionPhase.idle;
    reading = null;
    turns.clear();
    notifyListeners();
    await start();
  }

  void _fail(String message) {
    errorMessage = message;
    phase = SessionPhase.failed;
    notifyListeners();
  }

  Future<void> _teardown() async {
    await _camera.stop();
    await _readingSub?.cancel();
    await _statusSub?.cancel();
    await _errorSub?.cancel();
    _readingSub = null;
    _statusSub = null;
    _errorSub = null;
  }

  @override
  Future<void> dispose() async {
    await _teardown();
    await _sidecar.dispose();
    _counsel.dispose();
    super.dispose();
  }
}
