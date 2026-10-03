import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import 'casing/sidecar_client.dart';
import 'casing/webcam_source.dart';
import 'config.dart';
import 'models.dart';

/// Where a casing currently is.
enum CasingPhase { idle, connecting, measuring, done, failed }

/// Orchestrates one casing: opens the camera, streams frames to the sidecar,
/// collects readings, and decides what happens to the job.
///
/// Holds no persistence. [onAttempt] is the seam Firestore hangs off, so the
/// vault logic stays testable without a backend.
class VaultController extends ChangeNotifier {
  VaultController({
    SidecarClient? sidecar,
    WebcamSource? camera,
    this.onAttempt,
    this.onJobChanged,
  })  : _sidecar = sidecar ?? SidecarClient(),
        _camera = camera ??
            WebcamSource(
              width: Config.captureWidth,
              height: Config.captureHeight,
              fps: Config.captureFps,
            );

  final SidecarClient _sidecar;
  final WebcamSource _camera;

  /// Called with every completed attempt — wire this to Firestore. Receives the
  /// job and the final reading. Failures here must not break the vault.
  final Future<void> Function(Job job, Reading reading)? onAttempt;

  /// Called whenever a job's state changes, for persistence.
  final Future<void> Function(Job job)? onJobChanged;

  final List<Job> _jobs = [];
  List<Job> get jobs => List.unmodifiable(_jobs);

  Blueprint blueprint = const Blueprint();

  CasingPhase phase = CasingPhase.idle;
  Job? activeJob;
  Reading? latestReading;
  Reading? finalReading;
  String? statusLine;
  String? errorMessage;

  /// True when the sidecar is faking its signals, so the UI can say so loudly.
  /// Shipping a demo that silently reports mock vitals as real would be the
  /// single most dishonest thing this app could do.
  bool get isMockSource => _sidecar.sourceMode == 'mock';

  StreamSubscription<Reading>? _readingSub;
  StreamSubscription<String>? _statusSub;
  StreamSubscription<SidecarError>? _errorSub;

  void addJob(Job job) {
    _jobs.insert(0, job);
    onJobChanged?.call(job);
    notifyListeners();
  }

  void replaceJobs(List<Job> jobs) {
    _jobs
      ..clear()
      ..addAll(jobs);
    notifyListeners();
  }

  void abandon(Job job) {
    job.state = JobState.abandoned;
    onJobChanged?.call(job);
    notifyListeners();
  }

  /// The camera element, once capture has started, for the preview widget.
  web.HTMLVideoElement? get videoElement => _camera.videoElement;

  /// Runs a full casing for [job]. Returns the final reading, or null on failure.
  Future<Reading?> caseTheVault(Job job) async {
    if (phase == CasingPhase.measuring || phase == CasingPhase.connecting) return null;

    if (job.isLyingLow) {
      errorMessage = 'This job is lying low for another '
          '${job.lieLowRemaining.inMinutes + 1} min.';
      phase = CasingPhase.failed;
      notifyListeners();
      return null;
    }

    activeJob = job;
    latestReading = null;
    finalReading = null;
    errorMessage = null;
    statusLine = 'Connecting to the sidecar…';
    phase = CasingPhase.connecting;
    notifyListeners();

    try {
      await _sidecar.connect();
    } catch (e) {
      errorMessage = e is SidecarError
          ? e.message
          : 'Could not reach the Presage sidecar: $e';
      phase = CasingPhase.failed;
      notifyListeners();
      return null;
    }

    _readingSub = _sidecar.readings.listen((r) {
      latestReading = r;
      notifyListeners();
    });
    _statusSub = _sidecar.status.listen((s) {
      statusLine = s;
      notifyListeners();
    });
    _errorSub = _sidecar.errors.listen((e) {
      // Non-fatal sidecar errors are worth showing but must not abort the read.
      statusLine = e.message;
      notifyListeners();
    });

    try {
      statusLine = 'Opening the camera…';
      notifyListeners();

      await _camera.start(onFrame: (rgb, w, h, ts) {
        _sidecar.sendFrame(width: w, height: h, rgb: rgb, timestampUs: ts);
      });

      phase = CasingPhase.measuring;
      statusLine = 'Hold still. Good light. Face in frame.';
      notifyListeners();

      final reading = await _sidecar.beginCasing(blueprint: blueprint);
      finalReading = reading;
      latestReading = reading;
      phase = CasingPhase.done;

      _applyVerdict(job, reading);
      notifyListeners();

      // Persistence must never take the vault down with it.
      try {
        await onAttempt?.call(job, reading);
      } catch (e) {
        debugPrint('Mastermind: could not record attempt: $e');
      }

      return reading;
    } on CameraError catch (e) {
      errorMessage = e.isPermissionDenied
          ? 'Camera permission denied. Mastermind cannot read your state without it.'
          : e.isMissingDevice
              ? 'No camera found.'
              : 'Camera problem — $e';
      phase = CasingPhase.failed;
      notifyListeners();
      return null;
    } catch (e) {
      errorMessage = e is SidecarError ? e.message : '$e';
      phase = CasingPhase.failed;
      notifyListeners();
      return null;
    } finally {
      await _teardownCapture();
    }
  }

  /// Applies the vault rule. Only green releases; everything else holds.
  void _applyVerdict(Job job, Reading reading) {
    if (reading.verdict.opensVault) {
      job.state = JobState.released;
      job.releasedAt = DateTime.now();
      job.lieLowUntil = null;
    } else {
      job.state = JobState.locked;
      if (reading.verdict == Verdict.amber) {
        job.lieLowUntil = DateTime.now().add(Duration(minutes: blueprint.lieLowMinutes));
      }
    }
    onJobChanged?.call(job);
  }

  /// Stops early. The reading in flight still resolves, with whatever it has.
  void stopEarly() {
    _sidecar.endCasing();
  }

  Future<void> _teardownCapture() async {
    await _camera.stop();
    await _readingSub?.cancel();
    await _statusSub?.cancel();
    await _errorSub?.cancel();
    _readingSub = null;
    _statusSub = null;
    _errorSub = null;
  }

  void reset() {
    phase = CasingPhase.idle;
    activeJob = null;
    latestReading = null;
    finalReading = null;
    errorMessage = null;
    statusLine = null;
    notifyListeners();
  }

  @override
  Future<void> dispose() async {
    await _teardownCapture();
    await _sidecar.dispose();
    super.dispose();
  }
}
