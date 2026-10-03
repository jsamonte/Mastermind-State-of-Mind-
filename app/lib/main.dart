import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'src/auth/auth0_client.dart';
import 'src/backend/auth_bridge.dart';
import 'src/backend/firestore_store.dart';
import 'src/config.dart';
import 'src/counsel/counsel_client.dart';
import 'src/firebase_options.dart';
import 'src/models.dart';
import 'src/session_controller.dart';
import 'src/ui/camera_preview.dart';
import 'src/ui/palette.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  } catch (e) {
    // Persistence is a bonus, not a prerequisite. If Firebase cannot start, the
    // measurement and the conversation must still work.
    debugPrint('Mastermind: Firebase init failed, continuing without it: $e');
  }
  runApp(const MastermindApp());
}

class MastermindApp extends StatelessWidget {
  const MastermindApp({super.key});

  @override
  Widget build(BuildContext context) {
    final base = ThemeData.dark(useMaterial3: true);
    return MaterialApp(
      title: 'Mastermind',
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        scaffoldBackgroundColor: Palette.bg,
        colorScheme: base.colorScheme.copyWith(
          primary: Palette.gold,
          surface: Palette.surface,
        ),
        textTheme: base.textTheme.apply(
          bodyColor: const Color(0xFFE6E8EF),
          displayColor: Colors.white,
        ),
      ),
      home: const _Gate(),
    );
  }
}

/// Auth0 sits in front of everything. Nothing else is on screen until sign-in.
class _Gate extends StatefulWidget {
  const _Gate();

  @override
  State<_Gate> createState() => _GateState();
}

class _GateState extends State<_Gate> {
  late final Auth0Client _auth = Auth0Client(
    domain: Config.auth0Domain,
    clientId: Config.auth0ClientId,
  );

  bool _busy = true;
  String? _error;
  String? _idToken;

  /// Firebase uid, which is the Auth0 `sub`. Null when the exchange could not
  /// happen — the session then runs without persistence rather than failing.
  String? _uid;

  @override
  void initState() {
    super.initState();
    _resume();
  }

  /// Nothing in the bootstrap may hang the gate. Every await here is bounded,
  /// because the failure mode without a bound is not an error message - it is a
  /// spinner that never resolves, which reads as "the whole site is broken"
  /// when the real cause is a sidecar someone closed the terminal on.
  static const _bootstrapTimeout = Duration(seconds: 6);

  Future<void> _resume() async {
    String? token;
    try {
      // Returning from Auth0 with ?code=, or already holding a valid token.
      token = await _auth
              .completeLoginIfReturning()
              .timeout(_bootstrapTimeout) ??
          _auth.storedIdToken;
    } on Auth0Error catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _busy = false;
      });
      return;
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _error = 'Auth0 did not respond. Check your connection and try again.';
        _busy = false;
      });
      return;
    }

    // Trade the Auth0 token for a Firebase session so Firestore rules have an
    // identity. The sidecar does the minting; see docs/ARCHITECTURE.md.
    String? uid;
    if (token != null) {
      try {
        final user = await AuthBridge()
            .signInWithAuth0IdToken(token)
            .timeout(_bootstrapTimeout);
        uid = user.uid;
      } on AuthBridgeError catch (e) {
        // Being signed in to Auth0 but not Firebase is survivable: the whole
        // measurement and conversation work, only the history is lost.
        debugPrint('Mastermind: no Firebase session, continuing unsaved: $e');
      } on TimeoutException {
        // A sidecar that is down refuses fast, but one that is mid-restart
        // accepts the connection and then never answers. That used to hold the
        // gate open forever; now it just costs the history, which this path
        // was always willing to lose.
        debugPrint('Mastermind: sidecar did not answer in time, continuing unsaved');
      } catch (e) {
        debugPrint('Mastermind: Firebase sign-in failed, continuing unsaved: $e');
      }
    }

    if (!mounted) return;
    setState(() {
      _idToken = token;
      _uid = uid;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_busy) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(color: Palette.gold)),
      );
    }
    if (_idToken == null) {
      return _LoginScreen(
        error: _error,
        onLogin: () => _auth.login(),
      );
    }
    return SessionScreen(
      email: '${_auth.claims?['email'] ?? _auth.claims?['name'] ?? ''}',
      uid: _uid,
      onLogout: () => _auth.logout(),
    );
  }
}

class _LoginScreen extends StatelessWidget {
  const _LoginScreen({required this.onLogin, this.error});
  final VoidCallback onLogin;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          // This is the front door of the site, so it carries the pitch and the
          // hackathon credits as well as the button. That is taller than a
          // phone in landscape, so it scrolls rather than overflows.
          child: SingleChildScrollView(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(28, 32, 28, 36),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.lock_outline, size: 46, color: Palette.gold),
                      const SizedBox(height: 18),
                      const Text(
                        'MASTERMIND',
                        style: TextStyle(fontSize: 20, letterSpacing: 4, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'Know your state of mind before you decide.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Palette.muted, height: 1.5, fontSize: 13),
                      ),
                      const SizedBox(height: 28),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: onLogin,
                          style: FilledButton.styleFrom(
                            backgroundColor: Palette.gold,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 15),
                          ),
                          child: const Text('Sign in', style: TextStyle(fontWeight: FontWeight.w600)),
                        ),
                      ),
                      if (error != null) ...[
                        const SizedBox(height: 16),
                        Text(
                          error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Palette.red, fontSize: 12, height: 1.4),
                        ),
                      ],
                      const SizedBox(height: 32),
                      const Pitch(),
                      const SizedBox(height: 26),
                      const HackathonCredits(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The pitch, in the words we pitch it in. Sits on the landing screen so the
/// case for the product is made before anyone signs in.
class Pitch extends StatelessWidget {
  const Pitch({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: BoxDecoration(
        color: Palette.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Palette.surfaceAlt),
      ),
      child: const Column(
        children: [
          Text(
            "Don't get fooled by scammers, but more importantly don't fool yourself.",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13.5,
              height: 1.5,
              fontWeight: FontWeight.w700,
              color: Palette.gold,
            ),
          ),
          SizedBox(height: 10),
          Text(
            'Make sure you are in a good state of mind before doing anything '
            'important, such as before making a big purchase, giving information '
            'to sketchy calls, double-texting, confessing to your crush, or '
            'breaking up with your crush.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, height: 1.65, color: Palette.muted),
          ),
          SizedBox(height: 14),
          Divider(height: 1, thickness: 1, color: Palette.surfaceAlt),
          SizedBox(height: 14),
          Text(
            'It can help the elderly and the vulnerable avoid being scammed, by '
            'giving them a way to check their current state of mind before '
            'making a major decision.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, height: 1.65, color: Palette.muted),
          ),
          SizedBox(height: 14),
          Text(
            'Use Mastermind State of Mind today!',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, height: 1.4, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// What this was built for and which prizes it is in for. Judges land on the
/// sign-in screen, so it says so there.
class HackathonCredits extends StatelessWidget {
  const HackathonCredits({super.key});

  static const tracks = <String>[
    'Best Use of Gemini API',
    'Best Use of Presage',
    'Best Use of Auth0',
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Text(
          'BUILT FOR ROWDY HACKS 2026',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 10,
            letterSpacing: 2.2,
            fontWeight: FontWeight.w700,
            color: Palette.gold,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Submitted for',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 10.5, letterSpacing: 0.6, color: Palette.muted),
        ),
        const SizedBox(height: 10),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 7,
          runSpacing: 7,
          children: [for (final track in tracks) _TrackChip(label: track)],
        ),
      ],
    );
  }
}

class _TrackChip extends StatelessWidget {
  const _TrackChip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: Palette.gold.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Palette.gold.withValues(alpha: 0.32)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 10.5,
          letterSpacing: 0.3,
          fontWeight: FontWeight.w600,
          color: Palette.gold,
        ),
      ),
    );
  }
}

/// The whole product: camera, live stats, and the conversation.
class SessionScreen extends StatefulWidget {
  const SessionScreen({
    super.key,
    required this.email,
    required this.onLogout,
    this.uid,
  });
  final String email;
  final VoidCallback onLogout;

  /// Firebase uid, when the Auth0 exchange succeeded. Null means this session
  /// runs without persistence.
  final String? uid;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  late final SessionController _session;

  @override
  void initState() {
    super.initState();
    final uid = widget.uid;
    _session = SessionController(
      // Persist only when we actually hold a Firebase identity. Writing without
      // one would be denied by firestore.rules anyway.
      onReading: uid == null
          ? null
          : (reading) => FirestoreStore(uid: uid).recordReading(reading),
    )..addListener(_onChange);
    // The session starts itself: camera on, measurement running, no button to
    // press. The point of the product is the reading, so get to it.
    WidgetsBinding.instance.addPostFrameCallback((_) => _session.start());
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _session.removeListener(_onChange);
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Palette.bg,
        elevation: 0,
        titleSpacing: 18,
        title: Row(
          children: [
            const Icon(Icons.lock_outline, color: Palette.gold, size: 18),
            const SizedBox(width: 9),
            const Text(
              'MASTERMIND',
              style: TextStyle(letterSpacing: 3, fontWeight: FontWeight.w700, fontSize: 14),
            ),
            // Only where there is room for it; on a phone the bar already
            // carries the account and the sign-out.
            if (MediaQuery.sizeOf(context).width >= 880) ...[
              const SizedBox(width: 14),
              const Text(
                'ROWDY HACKS 2026',
                style: TextStyle(letterSpacing: 1.6, fontSize: 9, color: Palette.muted),
              ),
            ],
          ],
        ),
        actions: [
          if (widget.email.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Center(
                child: Text(
                  widget.email,
                  style: const TextStyle(color: Palette.muted, fontSize: 11),
                ),
              ),
            ),
          IconButton(
            tooltip: 'Sign out',
            onPressed: widget.onLogout,
            icon: const Icon(Icons.logout, size: 18, color: Palette.muted),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 880;
            final left = _CameraAndStats(session: _session);
            final right = _Chat(session: _session);

            if (isWide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // The camera and the numbers ARE the product; the chat is
                  // empty for the whole measuring window. Give the left side
                  // real estate proportional to the window, with a floor so it
                  // stays usable and a ceiling so the conversation keeps room.
                  SizedBox(
                    width: (constraints.maxWidth * 0.42).clamp(360.0, 560.0).toDouble(),
                    child: left,
                  ),
                  const VerticalDivider(width: 1, color: Palette.surfaceAlt),
                  Expanded(child: right),
                ],
              );
            }
            return Column(
              children: [
                SizedBox(
                  height: (constraints.maxHeight * 0.52).clamp(320.0, 560.0).toDouble(),
                  child: left,
                ),
                const Divider(height: 1, color: Palette.surfaceAlt),
                Expanded(child: right),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Camera feed with the live Presage numbers under it.
class _CameraAndStats extends StatelessWidget {
  const _CameraAndStats({required this.session});
  final SessionController session;

  @override
  Widget build(BuildContext context) {
    final video = session.videoElement;
    final reading = session.reading;

    // Scrollable: the preview is deliberately large now, and on a short window
    // a fixed column would overflow rather than letting the user reach the
    // numbers underneath it.
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            child: AspectRatio(
              aspectRatio: 4 / 3,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (video == null)
                      Container(
                        color: Palette.surfaceAlt,
                        child: const Center(
                          child: CircularProgressIndicator(color: Palette.gold, strokeWidth: 2),
                        ),
                      )
                    else
                      CameraPreview(video: video),
                    if (session.cameraLive)
                      const Positioned(top: 8, left: 8, child: _LiveDot()),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _CameraPicker(session: session),
          const SizedBox(height: 14),
          _StateChip(reading: reading, measuring: session.phase == SessionPhase.measuring),
          const SizedBox(height: 12),
          _Stats(reading: reading),
          if (session.sourceIsMock) ...[
            const SizedBox(height: 10),
            const Text(
              'MOCK SOURCE — simulated, not measured',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 9, letterSpacing: 0.8, color: Palette.amber),
            ),
          ],
          // Framing/lighting guidance lives in the coaching panel beside the
          // camera, not here — repeating it under the stats just competed with
          // itself. What belongs here is Presage's LIVE hint, below.
          if (session.statusLine != null) ...[
            const SizedBox(height: 8),
            Text(
              session.statusLine!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Palette.muted, height: 1.45),
            ),
          ],
          if (session.errorMessage != null) ...[
            const SizedBox(height: 10),
            Text(
              session.errorMessage!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Palette.red, height: 1.45),
            ),
            // A dead end with no way out is the thing that makes a stopped
            // sidecar look like a broken product. Starting it takes seconds;
            // reloading the page to pick it up should not be the only route.
            if (session.phase == SessionPhase.failed) ...[
              const SizedBox(height: 14),
              Center(
                child: FilledButton.icon(
                  onPressed: () => unawaited(session.restart()),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Try again'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Palette.gold,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 13),
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _LiveDot extends StatelessWidget {
  const _LiveDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.fiber_manual_record, size: 8, color: Palette.red),
          SizedBox(width: 5),
          Text('LIVE', style: TextStyle(fontSize: 9, letterSpacing: 1.2, color: Colors.white)),
        ],
      ),
    );
  }
}

/// Which camera is in use, and a way to change it.
///
/// A laptop can expose several video inputs - an infrared sensor for face
/// unlock, a vendor pipeline, the actual colour camera - and the browser picks
/// one without asking. When it picks wrong the preview is near-black, which
/// reads as a broken app; without this there is nothing the user can do about
/// it from inside the page.
class _CameraPicker extends StatelessWidget {
  const _CameraPicker({required this.session});
  final SessionController session;

  @override
  Widget build(BuildContext context) {
    final cameras = session.cameras;
    if (cameras.isEmpty) return const SizedBox.shrink();

    // One camera is not a choice, but saying which one is in use is still the
    // difference between "the app is broken" and "that is the wrong lens".
    if (cameras.length == 1) {
      return Text(
        cameras.first.label,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 11, color: Palette.muted),
      );
    }

    final activeId = session.activeCameraId;
    final value = cameras.any((c) => c.id == activeId) ? activeId : null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      decoration: BoxDecoration(
        color: Palette.surface,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.videocam_outlined, size: 16, color: Palette.muted),
          const SizedBox(width: 10),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: value,
                isExpanded: true,
                isDense: true,
                hint: const Text(
                  'Choose a camera',
                  style: TextStyle(fontSize: 12, color: Palette.muted),
                ),
                dropdownColor: Palette.surface,
                iconEnabledColor: Palette.muted,
                style: const TextStyle(fontSize: 12, color: Color(0xFFE6E8EF)),
                items: [
                  for (final camera in cameras)
                    DropdownMenuItem(
                      value: camera.id,
                      child: Text(camera.label, overflow: TextOverflow.ellipsis),
                    ),
                ],
                // Switching restarts the measurement: the frames already sent
                // came from a different camera and cannot be part of this one.
                onChanged: (id) {
                  if (id != null) unawaited(session.useCamera(id));
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The headline verdict: good / conflicted / bad, with the composure number.
class _StateChip extends StatelessWidget {
  const _StateChip({required this.reading, required this.measuring});
  final Reading? reading;
  final bool measuring;

  @override
  Widget build(BuildContext context) {
    final verdict = reading?.verdict ?? Verdict.inconclusive;
    final color = Palette.forVerdict(verdict);
    final score = reading?.composure;

    // "READING…" is right while a measurement is running, but after one has
    // finished without a confident result it reads as if it were still working.
    // Say plainly that there was no read.
    final label = (!measuring && verdict == Verdict.inconclusive)
        ? 'NO READ'
        : verdict.stateLabel;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 18),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 17,
              letterSpacing: 1.8,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
          if (score != null) ...[
            const SizedBox(width: 10),
            Text(
              '$score',
              style: TextStyle(fontSize: 30, fontWeight: FontWeight.w300, color: color),
            ),
          ],
          if (measuring && reading?.remainingMs != null && reading!.remainingMs > 0) ...[
            const SizedBox(width: 10),
            Text(
              '${(reading!.remainingMs / 1000).ceil()}s',
              style: const TextStyle(fontSize: 14, color: Palette.muted),
            ),
          ],
        ],
      ),
    );
  }
}

/// The Presage numbers.
class _Stats extends StatelessWidget {
  const _Stats({required this.reading});
  final Reading? reading;

  @override
  Widget build(BuildContext context) {
    // Presage reports zero confidence for a metric until its own window has
    // elapsed - 30s for breathing, a full 60s for HRV - so a dash early on is
    // the system working, not failing. Saying which window each one is waiting
    // for turns a row of dashes into visible progress.
    final rows = <(String, String, String?)>[
      ('PULSE', reading?.pulseRate == null ? '—' : '${reading!.pulseRate!.round()} bpm', null),
      ('BREATHING', reading?.breathingRate == null ? '—' : '${reading!.breathingRate!.round()} /min', 'needs 30s'),
      ('HRV (RMSSD)', reading?.rmssd == null ? '—' : '${reading!.rmssd!.round()} ms', 'needs 60s'),
      ('STRESS INDEX', reading?.stressIndex == null ? '—' : '${reading!.stressIndex!.round()}', 'needs 60s'),
    ];

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 18),
      decoration: BoxDecoration(
        color: Palette.surface,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          for (final (label, value, window) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 12,
                      letterSpacing: 1.2,
                      color: Palette.muted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      if (value == '—' && window != null) ...[
                        Text(
                          window,
                          style: const TextStyle(fontSize: 11, color: Palette.muted),
                        ),
                        const SizedBox(width: 10),
                      ],
                      Text(
                        value,
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The conversation. One thread, always open — no list, no new-chat, no picker.
class _Chat extends StatefulWidget {
  const _Chat({required this.session});
  final SessionController session;

  @override
  State<_Chat> createState() => _ChatState();
}

class _ChatState extends State<_Chat> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  int _lastCount = 0;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send() {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    widget.session.send(text);
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final turns = session.turns;

    // Follow the conversation as it grows.
    if (turns.length != _lastCount) {
      _lastCount = turns.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOut,
          );
        }
      });
    }

    final measuring = session.phase == SessionPhase.measuring ||
        session.phase == SessionPhase.starting;

    return Column(
      children: [
        Expanded(
          // The empty state only applies when nothing is in flight. Once the
          // reading lands, the first Gemini call takes several seconds — showing
          // "Waiting for a reading" through that reads as if nothing happened,
          // when in fact the measurement is done and a reply is on its way.
          child: (turns.isEmpty && !session.awaitingReply)
              ? (measuring
                  ? _MeasuringGuide(session: session)
                  : Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          session.phase == SessionPhase.talking
                              ? 'The measurement landed, but no reply came back.'
                              : 'Waiting for a reading.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Palette.muted, height: 1.6, fontSize: 13),
                        ),
                      ),
                    ))
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
                  itemCount: turns.length + (session.awaitingReply ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i >= turns.length) return const _Typing();
                    return _Bubble(turn: turns[i]);
                  },
                ),
        ),
        const Divider(height: 1, color: Palette.surfaceAlt),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  enabled: session.phase == SessionPhase.talking && !session.awaitingReply,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  minLines: 1,
                  maxLines: 4,
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    hintText: session.phase == SessionPhase.talking
                        ? 'Type your reply'
                        : 'Measuring…',
                    hintStyle: const TextStyle(color: Palette.muted, fontSize: 14),
                    filled: true,
                    fillColor: Palette.surface,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: (session.phase == SessionPhase.talking && !session.awaitingReply)
                    ? _send
                    : null,
                icon: const Icon(Icons.arrow_upward_rounded, size: 20),
                style: IconButton.styleFrom(
                  backgroundColor: Palette.gold,
                  foregroundColor: Colors.black,
                  disabledBackgroundColor: Palette.surfaceAlt,
                  minimumSize: const Size(44, 44),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// What to do during the window, shown from the moment it starts.
///
/// Presage's live hints are corrective: they arrive only once it has judged
/// frames that are already spoiled. Someone who was never told to hold still
/// has moved by then, and the opening seconds of a thirty-second window are
/// gone. So the instructions lead and the hints correct, rather than the hints
/// being the first place anyone learns what the measurement needs.
///
/// It lives in the conversation pane because that pane is empty for the whole
/// measurement anyway, and a line of grey text was all it had to say.
class _MeasuringGuide extends StatelessWidget {
  const _MeasuringGuide({required this.session});
  final SessionController session;

  static const _rules = <(IconData, String, String)>[
    (
      Icons.self_improvement,
      'Hold still, and stay quiet',
      "Don't talk or chew — talking breaks the breathing measurement outright. This matters more than anything else.",
    ),
    (
      Icons.person_outline,
      'Head and chest in frame',
      'Sit back so both are visible and unobstructed. Breathing is read from chest movement, so very dark or tightly striped clothing works against it.',
    ),
    (
      Icons.light_mode_outlined,
      'Steady light on your face',
      'A lamp or window in front of you, not behind. Avoid a TV or screen flickering behind you — the pulse is read from colour change in skin.',
    ),
    (
      Icons.laptop_mac,
      'Put the camera down',
      'Rest the laptop on a surface. Breathing detection needs a stable camera; handheld does not work.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final reading = session.reading;
    final elapsedMs = reading?.elapsedMs ?? 0;
    final remainingMs = reading?.remainingMs ?? 0;
    final total = elapsedMs + remainingMs;
    // Null until the first reading lands, which renders an indeterminate bar -
    // honest about the fact that the window has not actually started counting.
    final progress = total > 0 ? (elapsedMs / total).clamp(0.0, 1.0) : null;
    final secondsLeft = remainingMs > 0 ? (remainingMs / 1000).ceil() : null;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'HOLD STILL',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 22,
                  letterSpacing: 3,
                  fontWeight: FontWeight.w700,
                  color: Palette.gold,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                secondsLeft == null ? '--' : '$secondsLeft',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 68,
                  height: 1.0,
                  fontWeight: FontWeight.w200,
                  color: Color(0xFFE6E8EF),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                secondsLeft == null ? 'getting the camera ready' : 'seconds left',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, letterSpacing: 1.4, color: Palette.muted),
              ),
              const SizedBox(height: 22),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 6,
                  backgroundColor: Palette.surfaceAlt,
                  valueColor: const AlwaysStoppedAnimation<Color>(Palette.gold),
                ),
              ),
              const SizedBox(height: 32),
              for (final (icon, title, detail) in _rules) ...[
                _Rule(icon: icon, title: title, detail: detail),
                const SizedBox(height: 18),
              ],
              const SizedBox(height: 6),
              const Text(
                'The conversation starts when the measurement lands.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Palette.muted, height: 1.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Rule extends StatelessWidget {
  const _Rule({required this.icon, required this.title, required this.detail});
  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: Palette.gold),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 3),
              Text(
                detail,
                style: const TextStyle(fontSize: 12.5, color: Palette.muted, height: 1.5),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.turn});
  final CounselTurn turn;

  @override
  Widget build(BuildContext context) {
    final isUser = turn.isUser;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(
          color: turn.failed
              ? Palette.red.withValues(alpha: 0.12)
              : isUser
                  ? Palette.gold.withValues(alpha: 0.14)
                  : Palette.surface,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(isUser ? 14 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 14),
          ),
        ),
        child: SelectableText(
          turn.text,
          style: TextStyle(
            fontSize: 14,
            height: 1.55,
            color: turn.failed ? Palette.red : const Color(0xFFE6E8EF),
          ),
        ),
      ),
    );
  }
}

/// Explains itself if the model is slow, rather than looking frozen.
class _Typing extends StatefulWidget {
  const _Typing();

  @override
  State<_Typing> createState() => _TypingState();
}

class _TypingState extends State<_Typing> {
  late final Stopwatch _elapsed = Stopwatch()..start();
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _elapsed.elapsed.inSeconds;
    final note = s >= 18 ? 'Models are busy — still trying.' : (s >= 6 ? 'Thinking…' : null);
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 15,
              height: 15,
              child: CircularProgressIndicator(strokeWidth: 2, color: Palette.muted),
            ),
            if (note != null) ...[
              const SizedBox(width: 10),
              Text(note, style: const TextStyle(fontSize: 12, color: Palette.muted)),
            ],
          ],
        ),
      ),
    );
  }
}
