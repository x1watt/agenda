import 'package:flutter/material.dart';

import '../src/ui/theme.dart';
import 'voice_pipeline.dart';

sealed class _Line {}

class _UserLine extends _Line {
  _UserLine(this.text);
  final String text;
}

class _AssistantLine extends _Line {
  _AssistantLine(this.text, {this.claudeLatency});
  final String text;
  final Duration? claudeLatency;
  Duration? ttsLatency;
}

enum _Status { starting, listening, thinking, speaking, error }

class VoiceDemoPage extends StatefulWidget {
  const VoiceDemoPage({super.key, required this.modelsDir, this.language = 'en'});
  final String modelsDir;

  /// `de` or `en`.
  final String language;

  @override
  State<VoiceDemoPage> createState() => _VoiceDemoPageState();
}

class _VoiceDemoPageState extends State<VoiceDemoPage> {
  late final VoicePipeline _pipeline;
  final _lines = <_Line>[];
  final _scroll = ScrollController();
  final _typed = TextEditingController();
  String _partial = '';
  _Status _status = _Status.starting;
  String? _error;

  @override
  void initState() {
    super.initState();
    _pipeline = VoicePipeline(modelsDir: widget.modelsDir, language: widget.language);
    _pipeline.events.listen(_onEvent);
    _pipeline.start();
  }

  @override
  void dispose() {
    _pipeline.dispose();
    _scroll.dispose();
    _typed.dispose();
    super.dispose();
  }

  void _onEvent(VoiceEvent e) {
    setState(() {
      switch (e) {
        case ListeningStarted():
          _status = _Status.listening;
        case PartialTranscript(:final text):
          _partial = text;
        case UserTurnFinal(:final text):
          _partial = '';
          _lines.add(_UserLine(text));
        case AssistantThinking():
          _status = _Status.thinking;
        case AssistantReply(:final text, :final claudeLatency):
          _lines.add(_AssistantLine(text, claudeLatency: claudeLatency));
        case AssistantSpeaking():
          _status = _Status.speaking;
        case AssistantDone(:final ttsLatency):
          _status = _Status.listening;
          final last = _lines.lastOrNull;
          if (last is _AssistantLine) last.ttsLatency = ttsLatency;
        case PipelineError(:final message):
          _status = _Status.error;
          _error = message;
      }
    });
    _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
    });
  }

  void _sendTyped() {
    final text = _typed.text;
    _typed.clear();
    _pipeline.sendTypedText(text);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ui.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  const Text('Voice demo', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Ui.text)),
                  const SizedBox(width: 12),
                  _StatusChip(status: _status),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(_error!, style: const TextStyle(color: Ui.danger, fontSize: 12.5)),
              ),
            Expanded(
              child: ListView(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                children: [
                  for (final line in _lines) _Bubble(line: line),
                  if (_partial.isNotEmpty) _Bubble(line: _UserLine(_partial), faded: true),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _typed,
                      style: const TextStyle(color: Ui.text),
                      decoration: const InputDecoration(
                        hintText: 'Or type instead of speaking (debug fallback)',
                        hintStyle: TextStyle(color: Ui.muted),
                      ),
                      onSubmitted: (_) => _sendTyped(),
                    ),
                  ),
                  IconButton(onPressed: _sendTyped, icon: const Icon(Icons.send, color: Ui.accent)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});
  final _Status status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      _Status.starting => ('Loading models...', Ui.muted),
      _Status.listening => ('Listening', Ui.ok),
      _Status.thinking => ('Thinking...', Ui.warn),
      _Status.speaking => ('Speaking...', Ui.accent),
      _Status.error => ('Error', Ui.danger),
    };
    return Chip2(label, color: color);
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.line, this.faded = false});
  final _Line line;
  final bool faded;

  @override
  Widget build(BuildContext context) {
    final isUser = line is _UserLine;
    final text = switch (line) {
      _UserLine(:final text) => text,
      _AssistantLine(:final text) => text,
    };
    String? caption;
    if (line case _AssistantLine(:final claudeLatency, :final ttsLatency)) {
      final parts = [
        if (claudeLatency != null) 'Claude ${claudeLatency.inMilliseconds} ms',
        if (ttsLatency != null) 'TTS ${ttsLatency.inMilliseconds} ms',
      ];
      if (parts.isNotEmpty) caption = parts.join('  |  ');
    }
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Opacity(
        opacity: faded ? 0.55 : 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Panel(
              color: isUser ? Ui.accentSoft : Ui.surface2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(text, style: const TextStyle(color: Ui.text, fontSize: 14, height: 1.4)),
                  if (caption != null) ...[
                    const SizedBox(height: 4),
                    Text(caption, style: const TextStyle(color: Ui.muted, fontSize: 11)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
