import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../config.dart';

/// Finds out where the Presage companion app is currently reachable.
///
/// Measurement runs in a companion process, because the Presage SDK computes
/// on-device and has no cloud API. When that process is exposed through a
/// tunnel its hostname is **ephemeral** — Cloudflare quick tunnels expire on
/// their own and get a new name on every restart — so a link containing the
/// address goes stale and whoever has it sees a connection failure.
///
/// The sidecar therefore publishes its current address to a public Firestore
/// document (`config/sidecar`, see `sidecar/publish_sidecar_url.mjs`), and the
/// app looks it up at startup. Nobody has to pass URLs around.
///
/// An explicit `?sidecar=` always wins — this is a fallback, not an override.
class SidecarDirectory {
  SidecarDirectory({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  /// Looks up the published address and adopts it. Returns the address used, or
  /// null if none was published.
  ///
  /// Never throws: Firestore may be unreachable, unconfigured, or the document
  /// may not exist. Any of those just means "fall back to whatever Config says"
  /// — discovery is an improvement on the default, never a prerequisite.
  Future<String?> discover({
    Duration timeout = const Duration(seconds: 6),
  }) async {
    // Only an explicit `?sidecar=` on this page load skips discovery. A
    // remembered address must NOT, or a dead tunnel stays cached forever.
    if (Config.hasPinnedSidecar) return null;

    try {
      final snap =
          await _db.collection('config').doc('sidecar').get().timeout(timeout);
      final data = snap.data();
      if (data == null) return null;

      // `online: false` is a deliberate signal that the operator shut the
      // companion app down. Drop any remembered address too — otherwise the app
      // keeps dialling a tunnel we have just been told is gone, and the user
      // waits through a timeout instead of being told plainly.
      if (data['online'] != true) {
        Config.forgetSidecar();
        return null;
      }

      final url = data['url'];
      if (url is! String || url.isEmpty) return null;

      Config.adoptDiscovered(url);
      return url;
    } catch (e) {
      debugPrint('Mastermind: sidecar discovery failed, using default: $e');
      return null;
    }
  }
}
