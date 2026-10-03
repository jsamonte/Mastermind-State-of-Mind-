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
  /// Where a `?sidecar=` value is remembered across the Auth0 round trip.
  static const _sidecarKey = 'mastermind.sidecar_url';

  static String get sidecarUrl {
    final fromQuery = Uri.base.queryParameters['sidecar'];

    // The Auth0 redirect_uri is the bare origin, so the query string is GONE by
    // the time the user comes back signed in. Without remembering it, a hosted
    // page pointed at a tunnel silently reverts to loopback after login — which
    // the browser then blocks. Persist it so the choice survives the redirect.
    if (fromQuery != null && fromQuery.isNotEmpty) {
      _remember(_sidecarKey, fromQuery);
    }
    final remembered = fromQuery?.isNotEmpty == true ? fromQuery : _recall(_sidecarKey);

    final configured = (remembered != null && remembered.isNotEmpty)
        ? remembered
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

  /// Captures URL overrides at startup, before anything navigates away.
  ///
  /// Must be called from `main()`. The persistence inside [sidecarUrl] is lazy,
  /// and on the login screen nothing reads it — so without this the `?sidecar=`
  /// value is never saved and is lost the moment Auth0 redirects.
  static void captureOverrides() {
    final fromQuery = Uri.base.queryParameters['sidecar'];
    if (fromQuery != null && fromQuery.isNotEmpty) {
      _remember(_sidecarKey, fromQuery);
    }
  }

  /// localStorage can throw in a private window or with site data blocked, and
  /// a remembered convenience is never worth breaking startup over.
  static void _remember(String key, String value) {
    try {
      web.window.localStorage.setItem(key, value);
    } catch (_) {
      /* ignored */
    }
  }

  static String? _recall(String key) {
    try {
      return web.window.localStorage.getItem(key);
    } catch (_) {
      return null;
    }
  }

  /// Clears a remembered sidecar address, so a stale tunnel URL can be dropped
  /// without clearing all site data.
  static void forgetSidecar() {
    try {
      web.window.localStorage.removeItem(_sidecarKey);
    } catch (_) {
      /* ignored */
    }
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
  /// Presage rejects anything under 25fps outright — its validation stream says
  /// "Use a camera mode that provides at least 25 frames per second", and until
  /// it is satisfied no metric ever resolves, so the casing just runs out. 15
  /// produced a measurement that could never land. 30 is the next standard
  /// camera mode above the floor; asking for exactly 25 risks a camera that has
  /// no 25fps mode quietly handing back 15 again.
  static int get captureFps => 30;

  /// Bytes per second this configuration will push at the sidecar.
  /// Surfaced in the diagnostics panel because it is easy to get wrong.
  static int get estimatedBytesPerSecond =>
      captureWidth * captureHeight * 3 * captureFps;
}
