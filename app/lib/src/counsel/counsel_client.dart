import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models.dart';

/// One line of the conversation.
class CounselTurn {
  const CounselTurn({required this.role, required this.text, this.failed = false});

  /// `user` or `assistant`.
  final String role;
  final String text;

  /// True for a turn that could not be delivered, so the UI can offer a retry
  /// rather than silently losing what the person typed.
  final bool failed;

  bool get isUser => role == 'user';

  Map<String, dynamic> toJson() => {'role': role, 'text': text};
}

/// Raised when the sidecar cannot produce a reply.
class CounselError implements Exception {
  const CounselError(this.code, this.message);
  final String code;
  final String message;

  /// True when no Gemini key is configured. The UI hides the conversation
  /// rather than offering something that cannot work.
  bool get isDisabled => code == 'counsel_disabled';

  @override
  String toString() => '[$code] $message';
}

/// Talks to the sidecar's `/counsel` endpoint.
///
/// The Gemini key lives in the sidecar, never here — anything compiled into a
/// Flutter web bundle is readable by anyone who opens devtools.
class CounselClient {
  CounselClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// Derived from the sidecar's WebSocket URL so there is one address to set.
  Uri _endpoint(String path) {
    final ws = Uri.parse(Config.sidecarUrl);
    return ws.replace(
      scheme: ws.scheme == 'wss' ? 'https' : 'http',
      path: path,
    );
  }

  /// Asks for the next turn.
  ///
  /// Pass an empty [history] for the opening turn — the assistant speaks first,
  /// reporting the measured state and asking what decision is being faced.
  Future<String> next({
    required Reading reading,
    List<CounselTurn> history = const [],
  }) async {
    final http.Response response;
    try {
      response = await _client.post(
        _endpoint('/counsel'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({
          'reading': {
            'composure': reading.composure,
            'verdict': reading.verdict.name,
            'reasons': reading.reasons,
            'signals': {
              if (reading.pulseRate != null) 'pulseRate': reading.pulseRate,
              if (reading.breathingRate != null) 'breathingRate': reading.breathingRate,
              if (reading.rmssd != null) 'rmssd': reading.rmssd,
              if (reading.stressIndex != null) 'stressIndex': reading.stressIndex,
            },
          },
          'messages': [for (final turn in history.where((t) => !t.failed)) turn.toJson()],
        }),
      );
    } catch (e) {
      throw CounselError('unreachable', 'Could not reach the sidecar ($e).');
    }

    final Map<String, dynamic> body;
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw CounselError(
        'bad_response',
        'The sidecar returned ${response.statusCode} and not JSON.',
      );
    }

    if (response.statusCode != 200) {
      throw CounselError(
        '${body['error'] ?? 'counsel_failed'}',
        '${body['message'] ?? 'No reply could be generated.'}',
      );
    }

    final reply = body['reply'];
    if (reply is! String || reply.trim().isEmpty) {
      throw const CounselError('empty_reply', 'The model returned nothing to say.');
    }
    return reply.trim();
  }

  /// Whether the conversation is available at all, so the UI can omit it
  /// instead of showing a feature that will fail on first use.
  Future<bool> isAvailable() async {
    try {
      final response = await _client.get(_endpoint('/health'));
      if (response.statusCode != 200) return false;
      return (jsonDecode(response.body) as Map<String, dynamic>)['counsel'] == 'ready';
    } catch (_) {
      return false;
    }
  }

  void dispose() => _client.close();
}
