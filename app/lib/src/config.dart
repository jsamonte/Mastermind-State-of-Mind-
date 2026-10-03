import 'package:web/web.dart' as web;

/// Runtime configuration, resolved once at startup.
///
/// The sidecar address is NOT hardcoded to loopback, because a phone browser
/// cannot reach the laptop's 127.0.0.1. See `docs/MOBILE.md`.
class Config {
  /// Where the Presage sidecar is listening.
  ///
  /// Resolution order:
  ///   1. `?sidecar=` query parameter — handy for testing from a phone
  ///   2. `--dart-define=SIDECAR_URL=...` at build time
  ///   3. loopback on the default port
  ///
  /// A page served over HTTPS may only open a `wss://` socket; browsers block
  /// mixed content. If the page is secure and the configured socket is not,
  /// this upgrades the scheme so the failure is a clear connection error rather
  /// than a silent security block.
  static String get sidecarUrl {
    final fromQuery = Uri.base.queryParameters['sidecar'];
    final configured = (fromQuery != null && fromQuery.isNotEmpty)
        ? fromQuery
        : const String.fromEnvironment(
            'SIDECAR_URL',
            defaultValue: 'ws://127.0.0.1:8787',
          );

    if (isSecureContext && configured.startsWith('ws://')) {
      final host = Uri.tryParse(configured)?.host;
      final isLoopback = host == '127.0.0.1' || host == 'localhost' || host == '::1';
      // Loopback is a secure context even over ws://, so leave it alone.
      if (!isLoopback) {
        return configured.replaceFirst('ws://', 'wss://');
      }
    }
    return configured;
  }

  /// Auth0 tenant domain. Resolved by probing the OIDC discovery endpoint:
  /// `jared-v-samonte.us.auth0.com` answers, the other regions 404.
  static const auth0Domain = String.fromEnvironment(
    'AUTH0_DOMAIN',
    defaultValue: 'jared-v-samonte.us.auth0.com',
  );

  /// Auth0 SPA application client id. Not a secret — a public client cannot
  /// keep one, which is why the login uses PKCE.
  static const auth0ClientId = String.fromEnvironment(
    'AUTH0_CLIENT_ID',
    defaultValue: 'k4cT3lZn2h2zV8Twe30lIlfCglgwtbD6',
  );

  static bool get hasAuth0 => auth0Domain.isNotEmpty && auth0ClientId.isNotEmpty;

  /// True when the browser will allow camera access.
  ///
  /// `getUserMedia` requires a secure context: HTTPS, or localhost. This is the
  /// single most common reason the app works on the dev machine and fails on a
  /// phone over the LAN.
  static bool get isSecureContext => web.window.isSecureContext;

  /// Rough mobile detection, used only to pick capture defaults and layout —
  /// never to gate behaviour.
  static bool get isLikelyMobile {
    final ua = web.window.navigator.userAgent.toLowerCase();
    return ua.contains('android') ||
        ua.contains('iphone') ||
        ua.contains('ipad') ||
        ua.contains('mobile');
  }

  /// Capture size. Smaller on mobile: the frames cross a network rather than
  /// loopback, and phone uplink is the binding constraint.
  static int get captureWidth => isLikelyMobile ? 320 : 640;
  static int get captureHeight => isLikelyMobile ? 240 : 480;
  static int get captureFps => 15;

  /// Bytes per second this configuration will push at the sidecar.
  /// Surfaced in the diagnostics panel because it is easy to get wrong.
  static int get estimatedBytesPerSecond =>
      captureWidth * captureHeight * 3 * captureFps;
}
