import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

/// Auth0 Authorization Code flow with PKCE, implemented directly.
///
/// PKCE and not implicit flow: a single-page app is a public client and cannot
/// keep a secret, so the code is bound to a verifier this browser generated and
/// never sent. There is no client secret anywhere in this bundle.
class Auth0Client {
  Auth0Client({
    required this.domain,
    required this.clientId,
    this.audience,
  });

  /// e.g. `jared-v-samonte.us.auth0.com`
  final String domain;
  final String clientId;
  final String? audience;

  static const _verifierKey = 'mastermind.pkce_verifier';
  static const _stateKey = 'mastermind.auth_state';
  static const _tokenKey = 'mastermind.id_token';

  bool get isConfigured => domain.isNotEmpty && clientId.isNotEmpty;

  /// Where Auth0 sends the browser back. Must be listed in the application's
  /// Allowed Callback URLs, or Auth0 refuses the request outright.
  String get redirectUri {
    final l = web.window.location;
    return '${l.protocol}//${l.host}/';
  }

  /// The id_token from a previous login, if it is still valid.
  String? get storedIdToken {
    final token = _readPersistent(_tokenKey);
    if (token == null) return null;
    if (_isExpired(token)) {
      _removePersistent(_tokenKey);
      return null;
    }
    return token;
  }

  /// Decoded claims of the stored token, for showing who is signed in.
  Map<String, dynamic>? get claims {
    final token = storedIdToken;
    return token == null ? null : _decodeClaims(token);
  }

  /// Sends the browser to Auth0's Universal Login.
  Future<void> login() async {
    final verifier = _randomString(64);
    final state = _randomString(24);
    _write(_verifierKey, verifier);
    _write(_stateKey, state);

    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');

    final url = Uri.https(domain, '/authorize', {
      'response_type': 'code',
      'client_id': clientId,
      'redirect_uri': redirectUri,
      'scope': 'openid profile email',
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      'state': state,
      'audience': ?audience,
    });

    web.window.location.href = url.toString();
  }

  /// If the current URL carries `?code=`, exchanges it for tokens.
  ///
  /// Returns the id_token, or null when this is not a callback. Always clears
  /// the query string afterwards so a refresh cannot replay a used code.
  Future<String?> completeLoginIfReturning() async {
    final uri = Uri.parse(web.window.location.href);
    final code = uri.queryParameters['code'];
    final returnedState = uri.queryParameters['state'];
    final error = uri.queryParameters['error'];

    if (error != null) {
      _cleanUrl();
      throw Auth0Error(error, uri.queryParameters['error_description'] ?? error);
    }
    if (code == null) return null;

    final expectedState = _read(_stateKey);
    if (expectedState == null || returnedState != expectedState) {
      _cleanUrl();
      throw const Auth0Error('state_mismatch',
          'The login response did not match this browser session. Try again.');
    }

    final verifier = _read(_verifierKey);
    if (verifier == null) {
      _cleanUrl();
      throw const Auth0Error('no_verifier', 'The PKCE verifier is missing. Try again.');
    }

    final response = await http.post(
      Uri.https(domain, '/oauth/token'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'grant_type': 'authorization_code',
        'client_id': clientId,
        'code_verifier': verifier,
        'code': code,
        'redirect_uri': redirectUri,
      }),
    );

    _remove(_verifierKey);
    _remove(_stateKey);
    _cleanUrl();

    Map<String, dynamic> body;
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw Auth0Error('bad_response', 'Auth0 returned ${response.statusCode}.');
    }

    if (response.statusCode != 200) {
      throw Auth0Error(
        '${body['error'] ?? 'token_failed'}',
        '${body['error_description'] ?? 'Could not exchange the login code.'}',
      );
    }

    final idToken = body['id_token'];
    if (idToken is! String) {
      throw const Auth0Error('no_id_token', 'Auth0 returned no id_token.');
    }
    _writePersistent(_tokenKey, idToken);
    return idToken;
  }

  void logout({bool federated = false}) {
    _removePersistent(_tokenKey);
    final url = Uri.https(domain, '/v2/logout', {
      'client_id': clientId,
      'returnTo': redirectUri,
    });
    web.window.location.href = url.toString();
  }

  // --- helpers --------------------------------------------------------------

  /// Strips the OAuth query parameters without reloading the page.
  void _cleanUrl() {
    final l = web.window.location;
    web.window.history.replaceState(null, '', '${l.protocol}//${l.host}${l.pathname}');
  }

  static Map<String, dynamic>? _decodeClaims(String jwt) {
    final parts = jwt.split('.');
    if (parts.length != 3) return null;
    try {
      final payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
      return jsonDecode(payload) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Local expiry check only — this decides whether to bother asking, not
  /// whether to trust anything. The sidecar verifies the signature properly.
  static bool _isExpired(String jwt) {
    final claims = _decodeClaims(jwt);
    final exp = claims?['exp'];
    if (exp is! num) return true;
    final expiry = DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000);
    return DateTime.now().isAfter(expiry.subtract(const Duration(seconds: 30)));
  }

  static String _randomString(int length) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final rng = Random.secure();
    return List.generate(length, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  /// The id_token lives in localStorage so a sign-in survives new tabs and
  /// restarts — otherwise every tab demands a fresh Auth0 round trip.
  ///
  /// The PKCE verifier and the state nonce deliberately stay in sessionStorage
  /// (below): they are single-use, scoped to one in-flight authorization, and
  /// persisting them past that flow would widen the window for replay without
  /// buying anything.
  static String? _readPersistent(String key) {
    try {
      return web.window.localStorage.getItem(key);
    } catch (_) {
      return null;
    }
  }

  static void _writePersistent(String key, String value) {
    try {
      web.window.localStorage.setItem(key, value);
    } catch (_) {
      /* ignored */
    }
  }

  static void _removePersistent(String key) {
    try {
      web.window.localStorage.removeItem(key);
    } catch (_) {
      /* ignored */
    }
  }

  // sessionStorage can throw in private windows; never let that break login.
  static String? _read(String key) {
    try {
      return web.window.sessionStorage.getItem(key);
    } catch (_) {
      return null;
    }
  }

  static void _write(String key, String value) {
    try {
      web.window.sessionStorage.setItem(key, value);
    } catch (_) {
      /* ignored */
    }
  }

  static void _remove(String key) {
    try {
      web.window.sessionStorage.removeItem(key);
    } catch (_) {
      /* ignored */
    }
  }
}

class Auth0Error implements Exception {
  const Auth0Error(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => '[$code] $message';
}
