import 'dart:async';

import 'package:flutter/material.dart';

import '../counsel/counsel_client.dart';
import '../models.dart';
import 'palette.dart';

/// The conversation that follows a reading.
///
/// It opens itself: the assistant speaks first, reporting what was measured and
/// asking what decision is being faced. The person then talks it through and
/// gets help deciding whether to act now or wait.
///
/// This is advisory only. It never changes the verdict — the vault is opened by
/// the physiological reading, not by talking the app round. Letting the
/// conversation unlock things would turn a commitment device into a negotiation.
class CounselPanel extends StatefulWidget {
  const CounselPanel({super.key, required this.reading, this.client});

  final Reading reading;
  final CounselClient? client;

  @override
  State<CounselPanel> createState() => _CounselPanelState();
}

class _CounselPanelState extends State<CounselPanel> {
  late final CounselClient _client;
  final _turns = <CounselTurn>[];
  final _input = TextEditingController();
  final _scroll = ScrollController();

  bool _thinking = false;
  bool _unavailable = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _client = widget.client ?? CounselClient();
    _openConversation();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    if (widget.client == null) _client.dispose();
    super.dispose();
  }

  Future<void> _openConversation() async {
    setState(() {
      _thinking = true;
      _error = null;
    });
    try {
      final reply = await _client.next(reading: widget.reading);
      if (!mounted) return;
      setState(() {
        _turns.add(CounselTurn(role: 'assistant', text: reply));
        _thinking = false;
      });
      _scrollToEnd();
    } on CounselError catch (e) {
      if (!mounted) return;
      setState(() {
        _thinking = false;
        // A missing API key is not an error worth shouting about — just hide
        // the feature rather than showing a dead chat box.
        _unavailable = e.isDisabled;
        _error = e.isDisabled ? null : e.message;
      });
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _thinking) return;

    setState(() {
      _turns.add(CounselTurn(role: 'user', text: text));
      _input.clear();
      _thinking = true;
      _error = null;
    });
    _scrollToEnd();

    try {
      final reply = await _client.next(reading: widget.reading, history: _turns);
      if (!mounted) return;
      setState(() {
        _turns.add(CounselTurn(role: 'assistant', text: reply));
        _thinking = false;
      });
      _scrollToEnd();
    } on CounselError catch (e) {
      if (!mounted) return;
      setState(() {
        _thinking = false;
        _error = e.message;
      });
    }
  }

  void _scrollToEnd() {
    // After the frame, or the extent is still the old one.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_unavailable) return const SizedBox.shrink();

    return Container(
      decoration: BoxDecoration(
        color: Palette.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Palette.surfaceAlt),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(
              children: [
                Icon(Icons.forum_outlined, size: 16, color: Palette.gold),
                SizedBox(width: 8),
                Text(
                  'TALK IT THROUGH',
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 1.8,
                    color: Palette.gold,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: ListView(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                shrinkWrap: true,
                children: [
                  for (final turn in _turns) _Bubble(turn: turn),
                  if (_thinking) const _Thinking(),
                  if (_error != null) _ErrorNote(message: _error!, onRetry: _retry),
                ],
              ),
            ),
          ),
          const Divider(height: 1, color: Palette.surfaceAlt),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    enabled: !_thinking,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    minLines: 1,
                    maxLines: 4,
                    style: const TextStyle(fontSize: 14),
                    decoration: const InputDecoration(
                      hintText: 'What are you deciding?',
                      hintStyle: TextStyle(color: Palette.muted, fontSize: 14),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                    ),
                  ),
                ),
                IconButton(
                  onPressed: _thinking ? null : _send,
                  icon: const Icon(Icons.arrow_upward_rounded, size: 20),
                  style: IconButton.styleFrom(
                    backgroundColor: Palette.gold,
                    foregroundColor: Colors.black,
                    disabledBackgroundColor: Palette.surfaceAlt,
                    minimumSize: const Size(36, 36),
                  ),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              'A tool for second-guessing a text or a purchase — not medical or '
              'mental-health advice. If things are heavier than that, talk to a person.',
              style: TextStyle(fontSize: 10, color: Palette.muted, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  void _retry() {
    // The last user turn is still in the list; just ask again from it.
    if (_turns.isEmpty) {
      _openConversation();
    } else {
      setState(() => _error = null);
      _send0();
    }
  }

  /// Re-asks without appending another copy of the user's message.
  Future<void> _send0() async {
    setState(() => _thinking = true);
    try {
      final reply = await _client.next(reading: widget.reading, history: _turns);
      if (!mounted) return;
      setState(() {
        _turns.add(CounselTurn(role: 'assistant', text: reply));
        _thinking = false;
      });
      _scrollToEnd();
    } on CounselError catch (e) {
      if (!mounted) return;
      setState(() {
        _thinking = false;
        _error = e.message;
      });
    }
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.turn});
  final CounselTurn turn;

  @override
  Widget build(BuildContext context) {
    final isUser = turn.isUser;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 420),
        decoration: BoxDecoration(
          color: isUser ? Palette.surfaceAlt : Palette.bg,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(12),
            topRight: const Radius.circular(12),
            bottomLeft: Radius.circular(isUser ? 12 : 3),
            bottomRight: Radius.circular(isUser ? 3 : 12),
          ),
        ),
        child: SelectableText(
          turn.text,
          style: TextStyle(
            fontSize: 14,
            height: 1.5,
            color: isUser ? const Color(0xFFE6E8EF) : const Color(0xFFD6DAE6),
          ),
        ),
      ),
    );
  }
}

/// A spinner that starts explaining itself if the reply is slow.
///
/// The model chain falls back through several models when the fast ones are
/// under load, which has been measured taking tens of seconds. A bare spinner
/// in that window reads as "frozen", and someone already agitated will close
/// the tab rather than wait.
class _Thinking extends StatefulWidget {
  const _Thinking();

  @override
  State<_Thinking> createState() => _ThinkingState();
}

class _ThinkingState extends State<_Thinking> {
  late final Stopwatch _elapsed = Stopwatch()..start();
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seconds = _elapsed.elapsed.inSeconds;
    final note = seconds >= 18
        ? 'Models are busy — still trying.'
        : seconds >= 6
            ? 'Thinking…'
            : null;

    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: Palette.muted),
            ),
            if (note != null) ...[
              const SizedBox(width: 10),
              Text(
                note,
                style: const TextStyle(fontSize: 12, color: Palette.muted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ErrorNote extends StatelessWidget {
  const _ErrorNote({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Palette.red.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message,
            style: const TextStyle(fontSize: 12, color: Palette.red, height: 1.4),
          ),
          const SizedBox(height: 6),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 28),
              foregroundColor: Palette.gold,
            ),
            child: const Text('Try again', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
