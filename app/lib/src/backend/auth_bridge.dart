import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../config.dart';

/// Thrown when the Auth0 to Firebase exchange fails. Carries the sidecar's own
/// error code so the UI can distinguish "you need to log in again" from
/// "the sidecar is not configured".
class AuthBridgeError implements Exception {
  const AuthBridgeError(this.code, this.message);
  final String code;
  final String message;

  /// True when the bridge is simply not set up — no Auth0 tenant configured
  /// yet. The app treats this as "run unauthenticated" rather than an error.
  bool get isDisabled => code == 'auth_disabled';

  @override
  String toString() => '[$code] $message';
}

/// Exchanges an Auth0 `id_token` for a Firebase session.
///
/// The exchange happens in the sidecar, not here and not in a Cloud Function —
/// the project is on the Spark plan, and the sidecar is already the one trusted
/// local process. See docs/ARCHITECTURE.md. This class only moves the token.
class AuthBridge {
  AuthBridge({http.Client? client, FirebaseAuth? auth})
      : _client = client ?? http.Client(),
        _auth = auth ?? FirebaseAuth.instance;

  final http.Client _client;
  final FirebaseAuth _auth;

  /// The sidecar's HTTP origin, derived from its WebSocket URL so there is one
  /// address to configure rather than two that can disagree.
  Uri get _mintEndpoint {
    final ws = Uri.parse(Config.sidecarUrl);
    return ws.replace(
      scheme: ws.scheme == 'wss' ? 'https' : 'http',
      path: '/auth/firebase',
    );
  }

  /// Verifies the Auth0 token via the sidecar and signs into Firebase.
  ///
  /// Returns the signed-in Firebase user, whose uid is the Auth0 `sub`.
  Future<User> signInWithAuth0IdToken(String idToken) async {
    final http.Response response;
    try {
      response = await _client.post(
        _mintEndpoint,
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({'idToken': idToken}),
      );
    } catch (e) {
      throw AuthBridgeError(
        'sidecar_unreachable',
        'Could not reach the sidecar at $_mintEndpoint — is it running? ($e)',
      );
    }

    final Map<String, dynamic> body;
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw AuthBridgeError(
        'bad_response',
        'The sidecar returned ${response.statusCode} with a body that was not JSON.',
      );
    }

    if (response.statusCode != 200) {
      throw AuthBridgeError(
        '${body['error'] ?? 'mint_failed'}',
        '${body['message'] ?? 'The sidecar refused to mint a token.'}',
      );
    }

    final token = body['firebaseToken'];
    if (token is! String || token.isEmpty) {
      throw const AuthBridgeError('no_token', 'The sidecar returned no Firebase token.');
    }

    try {
      final credential = await _auth.signInWithCustomToken(token);
      final user = credential.user;
      if (user == null) {
        throw const AuthBridgeError('no_user', 'Firebase accepted the token but returned no user.');
      }
      return user;
    } on FirebaseAuthException catch (e) {
      throw AuthBridgeError('firebase_${e.code}', e.message ?? 'Firebase rejected the token.');
    }
  }

  /// Whether the sidecar's minter is configured. Lets the UI show an honest
  /// "login unavailable" state instead of a button that always fails.
  Future<bool> isAvailable() async {
    try {
      final health = _mintEndpoint.replace(path: '/health');
      final response = await _client.get(health);
      if (response.statusCode != 200) return false;
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return body['auth'] == 'ready';
    } catch (_) {
      return false;
    }
  }

  Future<void> signOut() => _auth.signOut();

  void dispose() => _client.close();
}
