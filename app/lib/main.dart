import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'src/config.dart';
import 'src/models.dart';
import 'src/ui/camera_preview.dart';
import 'src/vault_controller.dart';

void main() => runApp(const MastermindApp());

/// Heist palette. Vault gold on charcoal, with the three verdict colours doing
/// the real signalling work.
abstract final class Palette {
  static const bg = Color(0xFF0E0F13);
  static const surface = Color(0xFF171922);
  static const surfaceAlt = Color(0xFF1F222E);
  static const gold = Color(0xFFE8B931);
  static const green = Color(0xFF3DDC84);
  static const amber = Color(0xFFFFB020);
  static const red = Color(0xFFFF5A5A);
  static const muted = Color(0xFF8A90A6);

  static Color forVerdict(Verdict v) => switch (v) {
        Verdict.green => green,
        Verdict.amber => amber,
        Verdict.red => red,
        Verdict.inconclusive => muted,
      };
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
      home: const VaultScreen(),
    );
  }
}

class VaultScreen extends StatefulWidget {
  const VaultScreen({super.key});

  @override
  State<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends State<VaultScreen> {
  late final VaultController _vault;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _vault = VaultController()..addListener(_onChange);
    _seed();
    // Lie-low countdowns need to tick even when nothing else changes.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  /// Two example jobs so the vault is not empty on first load.
  void _seed() {
    _vault
      ..addJob(Job(
        id: 'seed-purchase',
        kind: JobKind.purchase,
        title: 'Mechanical keyboard, the expensive one',
        amount: 240,
        body: 'The cart has been open for three days.',
      ))
      ..addJob(Job(
        id: 'seed-message',
        kind: JobKind.message,
        title: 'Reply to Alex',
        body: 'The draft currently opens with "honestly, after everything".',
      ));
  }

  @override
  void dispose() {
    _tick?.cancel();
    _vault.removeListener(_onChange);
    _vault.dispose();
    super.dispose();
  }

  bool get _casingActive => _vault.phase != CasingPhase.idle;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 860;
        return Scaffold(
          appBar: _buildAppBar(isWide),
          floatingActionButton: (_casingActive && !isWide)
              ? null
              : FloatingActionButton.extended(
                  onPressed: _planJob,
                  backgroundColor: Palette.gold,
                  foregroundColor: Colors.black,
                  icon: const Icon(Icons.add),
                  label: const Text('Plan a job'),
                ),
          body: SafeArea(
            child: isWide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(flex: 5, child: _jobList()),
                      const VerticalDivider(width: 1, color: Palette.surfaceAlt),
                      Expanded(flex: 6, child: _panel()),
                    ],
                  )
                : (_casingActive ? _panel() : _jobList()),
          ),
        );
      },
    );
  }

  PreferredSizeWidget _buildAppBar(bool isWide) {
    return AppBar(
      backgroundColor: Palette.bg,
      elevation: 0,
      titleSpacing: 20,
      title: Row(
        children: [
          const Icon(Icons.lock_outline, color: Palette.gold, size: 22),
          const SizedBox(width: 10),
          const Text(
            'MASTERMIND',
            style: TextStyle(letterSpacing: 3, fontWeight: FontWeight.w700, fontSize: 16),
          ),
          if (isWide) ...[
            const SizedBox(width: 16),
            const Expanded(
              child: Text(
                "you can't rob a vault in a bad mood",
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Palette.muted, fontSize: 12, letterSpacing: 0.3),
              ),
            ),
          ],
        ],
      ),
      actions: [
        IconButton(
          tooltip: 'Diagnostics',
          onPressed: _showDiagnostics,
          icon: const Icon(Icons.info_outline, color: Palette.muted),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- job list

  Widget _jobList() {
    final jobs = _vault.jobs;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      children: [
        if (!Config.isSecureContext) const _InsecureContextWarning(),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text(
            'IN THE VAULT',
            style: TextStyle(
              color: Palette.muted,
              fontSize: 11,
              letterSpacing: 2,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (jobs.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Text(
              "Nothing waiting. Plan a job and it will be held here until you're "
              'in a state to be trusted with it.',
              style: TextStyle(color: Palette.muted, height: 1.5),
            ),
          ),
        for (final job in jobs)
          _JobCard(
            job: job,
            blueprint: _vault.blueprint,
            busy: _casingActive,
            onCase: () => _vault.caseTheVault(job),
            onAbandon: () => _vault.abandon(job),
          ),
      ],
    );
  }

  // -------------------------------------------------------------- side panel

  Widget _panel() {
    return switch (_vault.phase) {
      CasingPhase.idle => _IdlePanel(onPlan: _planJob),
      CasingPhase.connecting ||
      CasingPhase.measuring =>
        _CasingPanel(vault: _vault, onStop: _vault.stopEarly),
      CasingPhase.done => _VerdictPanel(vault: _vault, onDone: _vault.reset),
      CasingPhase.failed => _FailurePanel(vault: _vault, onDone: _vault.reset),
    };
  }

  // ------------------------------------------------------------------ dialogs

  Future<void> _planJob() async {
    final job = await showDialog<Job>(
      context: context,
      builder: (_) => const _PlanJobDialog(),
    );
    if (job != null) _vault.addJob(job);
  }

  void _showDiagnostics() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Palette.surface,
        title: const Text('Diagnostics'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _kv('Sidecar', Config.sidecarUrl),
              _kv('Secure context',
                  Config.isSecureContext ? 'yes' : 'NO — camera blocked'),
              _kv('Capture',
                  '${Config.captureWidth}x${Config.captureHeight} @ ${Config.captureFps}fps'),
              _kv('Uplink',
                  '${(Config.estimatedBytesPerSecond / 1e6).toStringAsFixed(1)} MB/s'),
              _kv('Source',
                  _vault.isMockSource ? 'MOCK (simulated vitals)' : 'Presage SmartSpectra'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  static Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 130,
              child: Text(k, style: const TextStyle(color: Palette.muted, fontSize: 13)),
            ),
            Expanded(child: SelectableText(v, style: const TextStyle(fontSize: 13))),
          ],
        ),
      );
}

// ------------------------------------------------------------------ widgets

class _InsecureContextWarning extends StatelessWidget {
  const _InsecureContextWarning();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Palette.red.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Palette.red.withValues(alpha: 0.4)),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: Palette.red, size: 20),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'This page is not a secure context, so the browser will refuse camera '
              'access. Serve it over HTTPS (or localhost) before casing anything.',
              style: TextStyle(fontSize: 13, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

class _JobCard extends StatelessWidget {
  const _JobCard({
    required this.job,
    required this.blueprint,
    required this.busy,
    required this.onCase,
    required this.onAbandon,
  });

  final Job job;
  final Blueprint blueprint;
  final bool busy;
  final VoidCallback onCase;
  final VoidCallback onAbandon;

  @override
  Widget build(BuildContext context) {
    final released = job.state == JobState.released;
    final abandoned = job.state == JobState.abandoned;
    final needsCasing = blueprint.requiresCasing(job);
    final lyingLow = job.isLyingLow;

    return Opacity(
      opacity: abandoned ? 0.45 : 1,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Palette.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: released ? Palette.green.withValues(alpha: 0.5) : Palette.surfaceAlt,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  job.kind == JobKind.purchase
                      ? Icons.shopping_bag_outlined
                      : Icons.chat_bubble_outline,
                  size: 16,
                  color: Palette.gold,
                ),
                const SizedBox(width: 8),
                Text(
                  job.kind.label.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 10,
                    letterSpacing: 1.6,
                    color: Palette.gold,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (job.amount != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    '\$${job.amount!.toStringAsFixed(0)}',
                    style: const TextStyle(fontSize: 12, color: Palette.muted),
                  ),
                ],
                const Spacer(),
                _StateChip(job: job),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              job.title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, height: 1.3),
            ),
            if (job.body != null) ...[
              const SizedBox(height: 6),
              Text(
                job.body!,
                style: const TextStyle(color: Palette.muted, fontSize: 13, height: 1.45),
              ),
            ],
            const SizedBox(height: 14),
            if (!needsCasing)
              Text(
                'Under your \$${blueprint.purchaseCeiling.toStringAsFixed(0)} ceiling — no check needed.',
                style: TextStyle(color: Palette.green.withValues(alpha: 0.9), fontSize: 12),
              )
            else
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: (busy || lyingLow || abandoned) ? null : onCase,
                    style: FilledButton.styleFrom(
                      backgroundColor: Palette.gold,
                      foregroundColor: Colors.black,
                      disabledBackgroundColor: Palette.surfaceAlt,
                    ),
                    icon: const Icon(Icons.visibility_outlined, size: 18),
                    label: Text(
                      lyingLow
                          ? 'Lying low — ${_fmt(job.lieLowRemaining)}'
                          : released
                              ? 'Case again'
                              : 'Case the vault',
                    ),
                  ),
                  if (!abandoned)
                    TextButton(
                      onPressed: onAbandon,
                      child: const Text('Walk away',
                          style: TextStyle(color: Palette.muted)),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return m > 0 ? '${m}m ${s}s' : '${s}s';
  }
}

class _StateChip extends StatelessWidget {
  const _StateChip({required this.job});
  final Job job;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (job.state) {
      JobState.released => ('RELEASED', Palette.green),
      JobState.locked => (job.isLyingLow ? 'LYING LOW' : 'SEALED', Palette.red),
      JobState.abandoned => ('WALKED AWAY', Palette.muted),
      JobState.planned => ('WAITING', Palette.muted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          letterSpacing: 1.2,
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _IdlePanel extends StatelessWidget {
  const _IdlePanel({required this.onPlan});
  final VoidCallback onPlan;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lock_outline, size: 56, color: Palette.gold.withValues(alpha: 0.5)),
            const SizedBox(height: 20),
            const Text('The vault is shut',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            const Text(
              'Pick a job and case the vault. Mastermind reads your pulse, '
              'breathing and heart-rate variability, and only opens if you are '
              'actually in a state to go through with it.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Palette.muted, height: 1.55, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _CasingPanel extends StatelessWidget {
  const _CasingPanel({required this.vault, required this.onStop});
  final VaultController vault;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final reading = vault.latestReading;
    final video = vault.videoElement;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          if (vault.isMockSource) const _MockBanner(),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: SizedBox(
                        width: 240,
                        height: 180,
                        child: video == null
                            ? Container(
                                color: Palette.surfaceAlt,
                                child: const Center(
                                  child: CircularProgressIndicator(color: Palette.gold),
                                ),
                              )
                            : CameraPreview(video: video),
                      ),
                    ),
                    const SizedBox(height: 22),
                    _ComposureDial(
                      composure: reading?.composure,
                      verdict: reading?.verdict ?? Verdict.inconclusive,
                      remainingMs: reading?.remainingMs ?? 0,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      vault.statusLine ?? 'Casing the vault…',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Palette.muted, fontSize: 13),
                    ),
                    if (reading != null) ...[
                      const SizedBox(height: 18),
                      _SignalRow(reading: reading),
                    ],
                  ],
                ),
              ),
            ),
          ),
          TextButton.icon(
            onPressed: onStop,
            icon: const Icon(Icons.stop_circle_outlined, size: 18),
            label: const Text('Call it off'),
            style: TextButton.styleFrom(foregroundColor: Palette.muted),
          ),
        ],
      ),
    );
  }
}

class _MockBanner extends StatelessWidget {
  const _MockBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Palette.amber.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Palette.amber.withValues(alpha: 0.45)),
      ),
      child: const Row(
        children: [
          Icon(Icons.science_outlined, size: 18, color: Palette.amber),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'MOCK SOURCE — these vitals are simulated, not measured.',
              style: TextStyle(
                  fontSize: 12, color: Palette.amber, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

/// The vault dial. Arc fills with composure; colour carries the verdict.
class _ComposureDial extends StatelessWidget {
  const _ComposureDial({
    required this.composure,
    required this.verdict,
    required this.remainingMs,
  });

  final int? composure;
  final Verdict verdict;
  final int remainingMs;

  @override
  Widget build(BuildContext context) {
    final color = Palette.forVerdict(verdict);
    return SizedBox(
      width: 190,
      height: 190,
      child: CustomPaint(
        painter: _DialPainter(value: (composure ?? 0) / 100, color: color),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                composure?.toString() ?? '--',
                style: TextStyle(
                  fontSize: 50,
                  fontWeight: FontWeight.w200,
                  color: color,
                  height: 1,
                ),
              ),
              const SizedBox(height: 4),
              const Text('COMPOSURE',
                  style: TextStyle(fontSize: 9, letterSpacing: 2, color: Palette.muted)),
              if (remainingMs > 0) ...[
                const SizedBox(height: 8),
                Text('${(remainingMs / 1000).ceil()}s left',
                    style: const TextStyle(fontSize: 11, color: Palette.muted)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  _DialPainter({required this.value, required this.color});
  final double value;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(10, 10, size.width - 20, size.height - 20);
    const start = math.pi * 0.75;
    const sweep = math.pi * 1.5;

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round
      ..color = Palette.surfaceAlt;
    canvas.drawArc(rect, start, sweep, false, track);

    if (value > 0) {
      final fill = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10
        ..strokeCap = StrokeCap.round
        ..color = color;
      canvas.drawArc(rect, start, sweep * value.clamp(0, 1), false, fill);
    }
  }

  @override
  bool shouldRepaint(_DialPainter old) => old.value != value || old.color != color;
}

class _SignalRow extends StatelessWidget {
  const _SignalRow({required this.reading});
  final Reading reading;

  @override
  Widget build(BuildContext context) {
    final items = <(String, String)>[
      ('PULSE', reading.pulseRate == null ? '--' : '${reading.pulseRate!.round()} bpm'),
      ('BREATH',
          reading.breathingRate == null ? '--' : '${reading.breathingRate!.round()}/min'),
      ('HRV', reading.rmssd == null ? '--' : '${reading.rmssd!.round()} ms'),
      ('STRESS',
          reading.stressIndex == null ? '--' : reading.stressIndex!.round().toString()),
    ];
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 22,
      runSpacing: 12,
      children: [
        for (final (label, value) in items)
          Column(
            children: [
              Text(value,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(label,
                  style: const TextStyle(
                      fontSize: 9, letterSpacing: 1.4, color: Palette.muted)),
            ],
          ),
      ],
    );
  }
}

class _VerdictPanel extends StatelessWidget {
  const _VerdictPanel({required this.vault, required this.onDone});
  final VaultController vault;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final reading = vault.finalReading;
    if (reading == null) return _FailurePanel(vault: vault, onDone: onDone);

    final color = Palette.forVerdict(reading.verdict);
    final opens = reading.verdict.opensVault;

    return Padding(
      padding: const EdgeInsets.all(28),
      child: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(opens ? Icons.lock_open_rounded : Icons.lock_rounded,
                  size: 56, color: color),
              const SizedBox(height: 18),
              Text(
                reading.verdict.headline,
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2,
                  color: color,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                reading.composure == null
                    ? 'No confident reading'
                    : 'Composure ${reading.composure}',
                style: const TextStyle(color: Palette.muted),
              ),
              const SizedBox(height: 22),
              if (reading.reasons.isNotEmpty)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Palette.surface,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final reason in reading.reasons)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('— ', style: TextStyle(color: Palette.muted)),
                              Expanded(
                                child: Text(reason,
                                    style: const TextStyle(fontSize: 13, height: 1.45)),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 18),
              Text(
                opens
                    ? 'The job is released. Go and do it.'
                    : vault.activeJob?.isLyingLow == true
                        ? 'Lie low for ${vault.blueprint.lieLowMinutes} minutes, then case it again.'
                        : 'The job is still there tomorrow.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Palette.muted, height: 1.5, fontSize: 13),
              ),
              const SizedBox(height: 26),
              FilledButton(
                onPressed: onDone,
                style: FilledButton.styleFrom(
                  backgroundColor: Palette.surfaceAlt,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Back to the vault'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FailurePanel extends StatelessWidget {
  const _FailurePanel({required this.vault, required this.onDone});
  final VaultController vault;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Palette.red),
              const SizedBox(height: 16),
              const Text('The job could not be cased',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              Text(
                vault.errorMessage ?? 'Something went wrong.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Palette.muted, height: 1.5, fontSize: 13),
              ),
              const SizedBox(height: 10),
              SelectableText(
                'Sidecar: ${Config.sidecarUrl}',
                style: const TextStyle(color: Palette.muted, fontSize: 11),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: onDone,
                style: FilledButton.styleFrom(
                  backgroundColor: Palette.surfaceAlt,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Back to the vault'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlanJobDialog extends StatefulWidget {
  const _PlanJobDialog();

  @override
  State<_PlanJobDialog> createState() => _PlanJobDialogState();
}

class _PlanJobDialogState extends State<_PlanJobDialog> {
  JobKind _kind = JobKind.message;
  final _title = TextEditingController();
  final _body = TextEditingController();
  final _amount = TextEditingController();

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Palette.surface,
      title: const Text('Plan a job'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SegmentedButton<JobKind>(
                segments: const [
                  ButtonSegment(
                      value: JobKind.message,
                      label: Text('Message'),
                      icon: Icon(Icons.chat_bubble_outline)),
                  ButtonSegment(
                      value: JobKind.purchase,
                      label: Text('Purchase'),
                      icon: Icon(Icons.shopping_bag_outlined)),
                ],
                selected: {_kind},
                onSelectionChanged: (s) => setState(() => _kind = s.first),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: _title,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: _kind == JobKind.message ? 'Who is it to?' : 'What is it?',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              if (_kind == JobKind.purchase) ...[
                TextField(
                  controller: _amount,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Amount',
                    prefixText: '\$',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: _body,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: _kind == JobKind.message ? 'The message' : 'Note to self',
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Palette.gold,
            foregroundColor: Colors.black,
          ),
          onPressed: () {
            final title = _title.text.trim();
            if (title.isEmpty) return;
            Navigator.of(context).pop(Job(
              id: DateTime.now().microsecondsSinceEpoch.toString(),
              kind: _kind,
              title: title,
              body: _body.text.trim().isEmpty ? null : _body.text.trim(),
              amount:
                  _kind == JobKind.purchase ? double.tryParse(_amount.text.trim()) : null,
            ));
          },
          child: const Text('Into the vault'),
        ),
      ],
    );
  }
}
