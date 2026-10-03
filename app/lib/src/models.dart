// Core domain types. Deliberately plain — they are the contract between the
// sidecar, the UI, and Firestore, so they stay free of framework imports.

/// The vault's answer.
enum Verdict {
  /// Vault opens. The job is released.
  green,

  /// Close, but not clear. Lie low, then case it again.
  amber,

  /// Vault stays shut.
  red,

  /// Not enough confident signal to judge. Treated as "shut" everywhere —
  /// see the fail-closed rule in `sidecar/src/composure.mjs`.
  inconclusive;

  static Verdict parse(String? raw) => switch (raw) {
        'green' => Verdict.green,
        'amber' => Verdict.amber,
        'red' => Verdict.red,
        _ => Verdict.inconclusive,
      };

  /// Only [green] releases a job. Anything else — including [inconclusive] —
  /// keeps it locked. This getter is the single place that decision lives.
  bool get opensVault => this == Verdict.green;

  String get headline => switch (this) {
        Verdict.green => 'VAULT OPEN',
        Verdict.amber => 'LIE LOW',
        Verdict.red => 'VAULT SEALED',
        Verdict.inconclusive => 'NO READ',
      };

  /// How the state is named to the user, matching the three words the
  /// conversation is instructed to use.
  String get stateLabel => switch (this) {
        Verdict.green => 'GOOD STATE',
        Verdict.amber => 'CONFLICTED',
        Verdict.red => 'BAD STATE',
        Verdict.inconclusive => 'READING…',
      };
}

/// What kind of action is being gated.
enum JobKind {
  message,
  purchase;

  static JobKind parse(String? raw) =>
      raw == 'purchase' ? JobKind.purchase : JobKind.message;

  String get label => switch (this) {
        JobKind.message => 'Message',
        JobKind.purchase => 'Purchase',
      };
}

/// Where a job sits in its lifecycle.
enum JobState { planned, locked, released, abandoned }

/// One live or final composure reading from the sidecar.
class Reading {
  const Reading({
    required this.verdict,
    required this.composure,
    required this.parts,
    required this.reasons,
    required this.signals,
    this.provisional,
    this.elapsedMs = 0,
    this.remainingMs = 0,
    this.framesReceived = 0,
    this.isFinal = false,
  });

  /// `null` when the reading is inconclusive — never coerce this to 0, which
  /// would read as "maximally agitated" instead of "unknown".
  final int? composure;
  final Verdict verdict;

  /// A score over whatever signal did survive, when coverage was too thin to
  /// commit to [composure]. Null on a confident reading (where [composure] is
  /// the answer) and null when nothing at all came through.
  ///
  /// This is NOT a verdict and must never be shown as one: the vault still
  /// stays shut, because a number computed from half the signal is exactly the
  /// kind of thing a commitment device must not be talked round by. It exists
  /// so a weak reading can say "here is what I saw, and why I don't trust it"
  /// instead of only "I cannot tell", which reads as the app being broken.
  final int? provisional;

  /// Per-signal sub-scores, 0..1, keyed as in `composure.mjs` (`stressIndex`,
  /// `rmssd`, `pulseRate`, `breathingRate`, `expression`, `eda`).
  final Map<String, double> parts;

  /// Plain-language reasons the vault is holding back. Shown verbatim.
  final List<String> reasons;

  /// Raw physiological values, for the diagnostics panel.
  final Map<String, dynamic> signals;

  final int elapsedMs;
  final int remainingMs;
  final int framesReceived;
  final bool isFinal;

  double? get pulseRate => _num('pulseRate');
  double? get breathingRate => _num('breathingRate');
  double? get rmssd => _num('rmssd');
  double? get stressIndex => _num('stressIndex');

  double? _num(String key) {
    final v = signals[key];
    return v is num ? v.toDouble() : null;
  }

  static Reading fromJson(Map<String, dynamic> json) {
    final rawParts = json['parts'];
    final rawReasons = json['reasons'];
    final rawSignals = json['signals'];
    return Reading(
      composure: json['composure'] is num ? (json['composure'] as num).round() : null,
      verdict: Verdict.parse(json['verdict'] as String?),
      parts: {
        if (rawParts is Map)
          for (final entry in rawParts.entries)
            if (entry.value is num) '${entry.key}': (entry.value as num).toDouble(),
      },
      reasons: [
        if (rawReasons is List)
          for (final r in rawReasons) '$r',
      ],
      signals: rawSignals is Map ? Map<String, dynamic>.from(rawSignals) : const {},
      provisional: json['provisional'] is num ? (json['provisional'] as num).round() : null,
      elapsedMs: _int(json['elapsedMs']),
      remainingMs: _int(json['remainingMs']),
      framesReceived: _int(json['framesReceived']),
      isFinal: json['type'] == 'final',
    );
  }

  static int _int(Object? v) => v is num && v.isFinite ? v.round() : 0;
}

/// The user's rules: which jobs need a check, and how calm they must be.
class Blueprint {
  const Blueprint({
    this.green = 70,
    this.amber = 45,
    this.purchaseCeiling = 100,
    this.lieLowMinutes = 20,
    this.casingSeconds = 60,
  });

  /// Composure needed to open the vault.
  final int green;

  /// Below this is a flat refusal; between the two is a cooling-off period.
  final int amber;

  /// Purchases at or above this amount need a reading. Below it, pass through.
  final double purchaseCeiling;

  /// How long to lie low after an amber verdict.
  final int lieLowMinutes;

  /// Length of one casing. Presage's own model cards state the thresholds this
  /// has to clear: breathing confidence stays 0 until a full 30s window, and HRV
  /// confidence stays 0 until a full 60s window. A 30s casing therefore could
  /// never return a confident HRV, and only just scraped breathing — so readings
  /// landed as `inconclusive` for a reason no amount of sitting still would fix.
  /// 60s is the first value at which every requested metric can actually resolve.
  /// The UI refuses to go below 20s.
  final int casingSeconds;

  bool requiresCasing(Job job) => switch (job.kind) {
        JobKind.message => true,
        JobKind.purchase => (job.amount ?? 0) >= purchaseCeiling,
      };

  Map<String, dynamic> toJson() => {
        'green': green,
        'amber': amber,
        'purchaseCeiling': purchaseCeiling,
        'lieLowMinutes': lieLowMinutes,
        'casingSeconds': casingSeconds,
      };

  static Blueprint fromJson(Map<String, dynamic>? json) {
    if (json == null) return const Blueprint();
    return Blueprint(
      green: (json['green'] as num?)?.round() ?? 70,
      amber: (json['amber'] as num?)?.round() ?? 45,
      purchaseCeiling: (json['purchaseCeiling'] as num?)?.toDouble() ?? 100,
      lieLowMinutes: (json['lieLowMinutes'] as num?)?.round() ?? 20,
      casingSeconds: (json['casingSeconds'] as num?)?.round() ?? 60,
    );
  }
}

/// An action held in the vault.
class Job {
  Job({
    required this.id,
    required this.kind,
    required this.title,
    this.body,
    this.amount,
    this.state = JobState.planned,
    DateTime? createdAt,
    this.releasedAt,
    this.lieLowUntil,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  final JobKind kind;

  /// Recipient, or what is being bought.
  final String title;

  /// The message text, or a note on the purchase.
  final String? body;

  /// Purchase amount, when [kind] is [JobKind.purchase].
  final double? amount;

  JobState state;
  final DateTime createdAt;
  DateTime? releasedAt;

  /// Set after an amber verdict — the job cannot be cased again until this passes.
  DateTime? lieLowUntil;

  bool get isLyingLow {
    final until = lieLowUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  Duration get lieLowRemaining {
    final until = lieLowUntil;
    if (until == null) return Duration.zero;
    final left = until.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'title': title,
        'body': body,
        'amount': amount,
        'state': state.name,
        'createdAt': createdAt.toIso8601String(),
        'releasedAt': releasedAt?.toIso8601String(),
        'lieLowUntil': lieLowUntil?.toIso8601String(),
      };

  static Job fromJson(String id, Map<String, dynamic> json) => Job(
        id: id,
        kind: JobKind.parse(json['kind'] as String?),
        title: '${json['title'] ?? ''}',
        body: json['body'] as String?,
        amount: (json['amount'] as num?)?.toDouble(),
        state: JobState.values.firstWhere(
          (s) => s.name == json['state'],
          orElse: () => JobState.planned,
        ),
        createdAt: DateTime.tryParse('${json['createdAt']}') ?? DateTime.now(),
        releasedAt: DateTime.tryParse('${json['releasedAt']}'),
        lieLowUntil: DateTime.tryParse('${json['lieLowUntil']}'),
      );
}
