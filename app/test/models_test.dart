// Pure domain tests. These deliberately import only `models.dart`, which has no
// `package:web` dependency, so they run on the VM with plain `flutter test`.
//
// Widget tests are NOT here: the app imports `package:web` for camera and config,
// which cannot compile for the VM target. The UI is verified by running it in a
// real browser instead, which exercises getUserMedia and the sidecar socket for
// real rather than mocking them.
import 'package:flutter_test/flutter_test.dart';
import 'package:mastermind/src/models.dart';

void main() {
  group('the vault rule', () {
    test('only green opens the vault', () {
      expect(Verdict.green.opensVault, isTrue);
      // Everything else holds, including an unreadable measurement.
      expect(Verdict.amber.opensVault, isFalse);
      expect(Verdict.red.opensVault, isFalse);
      expect(Verdict.inconclusive.opensVault, isFalse);
    });

    test('an unrecognised verdict degrades to inconclusive, never green', () {
      expect(Verdict.parse(null), Verdict.inconclusive);
      expect(Verdict.parse('GREEN'), Verdict.inconclusive);
      expect(Verdict.parse(''), Verdict.inconclusive);
      expect(Verdict.parse('whatever'), Verdict.inconclusive);
      expect(Verdict.parse('green'), Verdict.green);
    });
  });

  group('blueprint', () {
    test('purchases below the ceiling skip the check', () {
      const blueprint = Blueprint(purchaseCeiling: 100);
      expect(
        blueprint.requiresCasing(
            Job(id: 'a', kind: JobKind.purchase, title: 'coffee', amount: 4)),
        isFalse,
      );
      expect(
        blueprint.requiresCasing(
            Job(id: 'b', kind: JobKind.purchase, title: 'laptop', amount: 1800)),
        isTrue,
      );
    });

    test('a purchase exactly at the ceiling still needs a check', () {
      const blueprint = Blueprint(purchaseCeiling: 100);
      expect(
        blueprint.requiresCasing(
            Job(id: 'c', kind: JobKind.purchase, title: 'thing', amount: 100)),
        isTrue,
      );
    });

    test('a purchase with no amount is treated as needing no check', () {
      const blueprint = Blueprint(purchaseCeiling: 100);
      expect(
        blueprint.requiresCasing(Job(id: 'd', kind: JobKind.purchase, title: '?')),
        isFalse,
      );
    });

    test('messages always require a check', () {
      expect(
        const Blueprint()
            .requiresCasing(Job(id: 'e', kind: JobKind.message, title: 'Alex')),
        isTrue,
      );
    });

    test('round-trips through json', () {
      const original = Blueprint(
          green: 80, amber: 55, purchaseCeiling: 250, lieLowMinutes: 45, casingSeconds: 40);
      final restored = Blueprint.fromJson(original.toJson());
      expect(restored.green, 80);
      expect(restored.amber, 55);
      expect(restored.purchaseCeiling, 250);
      expect(restored.lieLowMinutes, 45);
      expect(restored.casingSeconds, 40);
    });

    test('missing json falls back to defaults', () {
      final fallback = Blueprint.fromJson(null);
      expect(fallback.green, 70);
      expect(fallback.amber, 45);
    });
  });

  group('reading', () {
    test('a null composure stays null and is not coerced to zero', () {
      final reading = Reading.fromJson({
        'verdict': 'inconclusive',
        'composure': null,
        'parts': <String, dynamic>{},
        'reasons': ['not enough signal'],
      });
      expect(reading.composure, isNull);
      expect(reading.verdict, Verdict.inconclusive);
      expect(reading.reasons, ['not enough signal']);
    });

    test('parses signals and sub-scores from the sidecar payload', () {
      final reading = Reading.fromJson({
        'type': 'final',
        'verdict': 'green',
        'composure': 82,
        'parts': {'rmssd': 0.7, 'pulseRate': 0.9},
        'reasons': <String>[],
        'signals': {'pulseRate': 66.4, 'breathingRate': 13.1, 'rmssd': 58.0, 'stressIndex': 102.0},
        'remainingMs': 4200,
        'framesReceived': 310,
      });
      expect(reading.composure, 82);
      expect(reading.verdict, Verdict.green);
      expect(reading.isFinal, isTrue);
      expect(reading.parts['rmssd'], closeTo(0.7, 1e-9));
      expect(reading.pulseRate, closeTo(66.4, 1e-9));
      expect(reading.stressIndex, closeTo(102.0, 1e-9));
      expect(reading.remainingMs, 4200);
      expect(reading.framesReceived, 310);
    });

    test('survives a malformed payload without throwing', () {
      final reading = Reading.fromJson({
        'verdict': 'green',
        'composure': 'not a number',
        'parts': 'nonsense',
        'reasons': 'nonsense',
        'signals': 'nonsense',
        'remainingMs': double.nan,
      });
      expect(reading.composure, isNull);
      expect(reading.parts, isEmpty);
      expect(reading.reasons, isEmpty);
      expect(reading.signals, isEmpty);
      // NaN must not leak into the countdown.
      expect(reading.remainingMs, 0);
    });
  });

  group('lie low', () {
    test('blocks re-casing until the window expires', () {
      final job = Job(id: 'f', kind: JobKind.message, title: 'Alex')
        ..lieLowUntil = DateTime.now().add(const Duration(minutes: 5));
      expect(job.isLyingLow, isTrue);
      expect(job.lieLowRemaining.inMinutes, inInclusiveRange(4, 5));

      job.lieLowUntil = DateTime.now().subtract(const Duration(minutes: 1));
      expect(job.isLyingLow, isFalse);
      expect(job.lieLowRemaining, Duration.zero);
    });

    test('a job with no window is not lying low', () {
      final job = Job(id: 'g', kind: JobKind.message, title: 'Alex');
      expect(job.isLyingLow, isFalse);
      expect(job.lieLowRemaining, Duration.zero);
    });
  });

  test('a job round-trips through json', () {
    final job = Job(
      id: 'h',
      kind: JobKind.purchase,
      title: 'keyboard',
      body: 'the expensive one',
      amount: 240,
      state: JobState.locked,
    );
    final restored = Job.fromJson('h', job.toJson());
    expect(restored.kind, JobKind.purchase);
    expect(restored.title, 'keyboard');
    expect(restored.body, 'the expensive one');
    expect(restored.amount, 240);
    expect(restored.state, JobState.locked);
  });
}
