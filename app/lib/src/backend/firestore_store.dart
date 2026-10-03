import 'package:cloud_firestore/cloud_firestore.dart';

import '../models.dart';

/// Persistence for jobs, the blueprint, and the attempts log.
///
/// Every path is scoped under `users/{uid}`, matching `firebase/firestore.rules`.
/// The uid is the Auth0 `sub`, which the sidecar puts in the Firebase custom
/// token — see docs/ARCHITECTURE.md.
class FirestoreStore {
  FirestoreStore({required this.uid, FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final String uid;
  final FirebaseFirestore _db;

  DocumentReference<Map<String, dynamic>> get _user => _db.collection('users').doc(uid);
  CollectionReference<Map<String, dynamic>> get _jobs => _user.collection('jobs');
  CollectionReference<Map<String, dynamic>> get _attempts => _user.collection('attempts');

  /// Live job list, newest first.
  Stream<List<Job>> watchJobs() => _jobs
      .orderBy('createdAt', descending: true)
      .snapshots()
      .map((snap) => snap.docs.map((d) => Job.fromJson(d.id, d.data())).toList());

  Future<void> saveJob(Job job) => _jobs.doc(job.id).set(job.toJson());

  Future<void> deleteJob(String jobId) => _jobs.doc(jobId).delete();

  Future<Blueprint> loadBlueprint() async {
    final snap = await _user.get();
    return Blueprint.fromJson(snap.data()?['blueprint'] as Map<String, dynamic>?);
  }

  /// Stored with merge so writing the blueprint never clobbers other user fields.
  Future<void> saveBlueprint(Blueprint blueprint) =>
      _user.set({'blueprint': blueprint.toJson()}, SetOptions(merge: true));

  /// Appends one attempt to the record.
  ///
  /// The rules make this collection append-only: no update, no delete. That is
  /// deliberate. A commitment device whose history you can quietly edit after a
  /// bad night is not a commitment device.
  ///
  /// Note what is stored and what is not: the derived numbers are kept, the
  /// camera frames are never uploaded anywhere. They go to the local sidecar
  /// and are discarded.
  Future<void> recordAttempt(Job job, Reading reading) => _attempts.add({
        'jobId': job.id,
        'jobKind': job.kind.name,
        'verdict': reading.verdict.name,
        'composure': reading.composure,
        'parts': reading.parts,
        'reasons': reading.reasons,
        'signals': _summariseSignals(reading),
        'measuredAt': FieldValue.serverTimestamp(),
      });

  /// Keeps the vitals worth reviewing later and drops the raw traces, which are
  /// large, un-plottable at this granularity, and not worth the storage.
  static Map<String, dynamic> _summariseSignals(Reading reading) => {
        if (reading.pulseRate != null) 'pulseRate': reading.pulseRate,
        if (reading.breathingRate != null) 'breathingRate': reading.breathingRate,
        if (reading.rmssd != null) 'rmssd': reading.rmssd,
        if (reading.stressIndex != null) 'stressIndex': reading.stressIndex,
        'framesReceived': reading.framesReceived,
      };

  /// The record: every attempt, newest first. This is the product's real
  /// payload — a log of when you reached for something and what state you were
  /// in when you did.
  Stream<List<AttemptRecord>> watchAttempts({int limit = 100}) => _attempts
      .orderBy('measuredAt', descending: true)
      .limit(limit)
      .snapshots()
      .map((snap) => snap.docs.map((d) => AttemptRecord.fromJson(d.id, d.data())).toList());
}

/// One row of the record.
class AttemptRecord {
  const AttemptRecord({
    required this.id,
    required this.jobId,
    required this.verdict,
    required this.composure,
    required this.measuredAt,
    this.reasons = const [],
  });

  final String id;
  final String jobId;
  final Verdict verdict;
  final int? composure;

  /// Null while the server timestamp is still resolving on a just-written doc.
  final DateTime? measuredAt;
  final List<String> reasons;

  static AttemptRecord fromJson(String id, Map<String, dynamic> json) {
    final ts = json['measuredAt'];
    return AttemptRecord(
      id: id,
      jobId: '${json['jobId'] ?? ''}',
      verdict: Verdict.parse(json['verdict'] as String?),
      composure: json['composure'] is num ? (json['composure'] as num).round() : null,
      measuredAt: ts is Timestamp ? ts.toDate() : null,
      reasons: [
        if (json['reasons'] is List)
          for (final r in json['reasons'] as List) '$r',
      ],
    );
  }
}
