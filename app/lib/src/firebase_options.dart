import 'package:firebase_core/firebase_core.dart';

/// Firebase configuration for the `mastermind-web` app.
///
/// These values are NOT secrets. A Firebase web apiKey identifies the project
/// to Google's APIs; it does not authorise anything. Access is controlled by
/// `firebase/firestore.rules`, which is the file to be careful about.
///
/// Notes on this project's console state, so nobody wastes time rediscovering it:
///   - Spark (no-cost) plan, so Cloud Functions are unavailable. The Auth0
///     token exchange runs in the sidecar instead — see docs/ARCHITECTURE.md.
///   - Firestore is in **us-central1** (single region), chosen by Jared. This is
///     permanent and cannot be migrated.
///   - No Firebase Auth providers are enabled, and that is deliberate: Auth0 is
///     the identity provider and we enter Firebase via signInWithCustomToken.
///   - Analytics is NOT linked to a stream despite `measurementId` existing, so
///     do not call `getAnalytics()` — it can throw. measurementId is omitted
///     below for that reason.
class DefaultFirebaseOptions {
  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyByPcP9Bj5X2gDDABNjsTHKJpnRRWVKKgY',
    appId: '1:981957401598:web:2284e7beca4462146d3eaf',
    messagingSenderId: '981957401598',
    projectId: 'mastermind-state-of-mind',
    authDomain: 'mastermind-state-of-mind.firebaseapp.com',
    storageBucket: 'mastermind-state-of-mind.firebasestorage.app',
  );

  /// The app is web-only, so there is one option set. Asking for any other
  /// platform is a programming error rather than something to paper over.
  static FirebaseOptions get currentPlatform => web;
}
