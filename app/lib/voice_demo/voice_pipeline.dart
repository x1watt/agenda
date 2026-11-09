import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'claude_cli_bridge.dart';

const _sampleRate = 16000;

/// `de` or `en`: picks `voice_models/<lang>/{asr,tts}`.
String _spokenStyleSystemPrompt(String language) {
  final name = language == 'de' ? 'German' : 'English';
  return 'You are a voice assistant having a spoken conversation in $name. '
      'Reply only in $name, in plain spoken sentences a text-to-speech engine will read aloud: '
      'no Markdown, no lists, no headings, no emoji, no code blocks. Keep replies short, '
      'like a real conversational turn, not an essay.';
}

/// One event out of the pipeline, for the UI to render.
sealed class VoiceEvent {}

class ListeningStarted extends VoiceEvent {}

class PartialTranscript extends VoiceEvent {
  PartialTranscript(this.text);
  final String text;
}

class UserTurnFinal extends VoiceEvent {
  UserTurnFinal(this.text);
  final String text;
}

class AssistantThinking extends VoiceEvent {}

class AssistantReply extends VoiceEvent {
  AssistantReply(this.text, this.claudeLatency);
  final String text;
  final Duration claudeLatency;
}

class AssistantSpeaking extends VoiceEvent {}

class AssistantDone extends VoiceEvent {
  AssistantDone(this.ttsLatency);
  final Duration ttsLatency;
}

class PipelineError extends VoiceEvent {
  PipelineError(this.message);
  final String message;
}

/// Mic capture -> streaming German ASR (with built-in endpoint/silence
/// detection) -> the `claude` CLI -> German TTS -> playback via paplay/aplay.
///
/// No agenda awareness, no file tools: a bare conversation loop.
class VoicePipeline {
  VoicePipeline({required this.modelsDir, this.language = 'en'});

  /// Base `voice_models` folder; the actual models live under `<modelsDir>/<language>`.
  final String modelsDir;

  /// `de` or `en`.
  final String language;

  final _events = StreamController<VoiceEvent>.broadcast();
  Stream<VoiceEvent> get events => _events.stream;

  late final ClaudeCliBridge _claude;
  late final sherpa.OnlineRecognizer _recognizer;
  late final sherpa.OfflineTts _tts;
  sherpa.OnlineStream? _stream;
  final _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _micSub;
  Directory? _scratchDir;

  /// True while we want mic audio fed to the recognizer. Muted while the
  /// assistant is thinking/speaking so it doesn't hear its own reply.
  bool _listening = false;

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    sherpa.initBindings();

    _scratchDir = await Directory.systemTemp.createTemp('voice-demo-');

    _claude = ClaudeCliBridge(
      workingDirectory: _scratchDir!.path,
      systemPrompt: _spokenStyleSystemPrompt(language),
    );

    final asr = '$modelsDir/$language/asr';
    _recognizer = sherpa.OnlineRecognizer(
      sherpa.OnlineRecognizerConfig(
        model: sherpa.OnlineModelConfig(
          transducer: sherpa.OnlineTransducerModelConfig(
            encoder: '$asr/encoder.onnx',
            decoder: '$asr/decoder.onnx',
            joiner: '$asr/joiner.onnx',
          ),
          tokens: '$asr/tokens.txt',
          modelType: 'zipformer2',
          numThreads: 2,
          debug: false,
        ),
        // Library defaults (2.4s / 1.2s / 20s). Earlier overrides here
        // (especially a 2s max-utterance cap) force-ended ordinary longer
        // sentences partway through, losing the first half.
        enableEndpoint: true,
      ),
    );

    final tts = '$modelsDir/$language/tts';
    _tts = sherpa.OfflineTts(
      sherpa.OfflineTtsConfig(
        model: sherpa.OfflineTtsModelConfig(
          vits: sherpa.OfflineTtsVitsModelConfig(
            model: '$tts/model.onnx',
            tokens: '$tts/tokens.txt',
            dataDir: '$tts/espeak-ng-data',
          ),
          numThreads: 2,
          debug: false,
        ),
        maxNumSenetences: 100,
      ),
    );
  }

  /// Starts the mic -> ASR path. A failure here (no mic, missing capture
  /// backend) is reported through [events] but is not fatal: [sendTypedText]
  /// works regardless, since it never touches the recorder.
  Future<void> start() async {
    await init();
    await _startMic();
  }

  /// Opens the mic and starts trusting what it captures. Used as-is only for
  /// the very first open (from [start], nothing playing yet to overlap
  /// with); turns use [_prewarmMic] instead so the process can be spawned
  /// ahead of when it's actually trusted (see [_handleTurn]).
  Future<void> _startMic() async {
    await _prewarmMic();
    if (_micSub == null) return; // prewarm failed; it already reported why
    final s = _stream;
    if (s != null) _recognizer.reset(s);
    _listening = true;
    _events.add(ListeningStarted());
  }

  /// Actually opens the mic (a real `parecord`/PipeWire capture stream, not
  /// just a Dart-side flag) without trusting its audio yet — `_listening`
  /// stays whatever it already was. A capture stream left open *and
  /// listened to* during playback both gets ducked by PipeWire (quiet,
  /// seemingly-truncated replies — confirmed twice) and, worse, can end up
  /// capturing the assistant's own voice as if it were the user's. Opening
  /// the process early while still gated by `_listening == false` sidesteps
  /// both: nothing it captures is processed until the caller decides to
  /// trust it, but the process-spawn latency happens ahead of time instead
  /// of being on the critical path when the user starts their next turn.
  Future<void> _prewarmMic() async {
    if (_micSub != null) return; // already running
    try {
      if (!await _recorder.hasPermission()) {
        _events.add(PipelineError('No microphone permission. You can still type below.'));
        return;
      }
      _stream = _recognizer.createStream();
      final micStream = await _recorder.startStream(
        const RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: _sampleRate, numChannels: 1),
      );
      _micSub = micStream.listen(_onChunk, onError: (Object e) => _events.add(PipelineError('$e')));
    } catch (e) {
      _events.add(PipelineError('Microphone unavailable ($e). You can still type below.'));
    }
  }

  Future<void> stop() async {
    _listening = false;
    await _micSub?.cancel();
    _micSub = null;
    await _recorder.stop();
    _stream?.free();
    _stream = null;
  }

  /// Bypass the mic/ASR entirely and run a turn from typed text (debug fallback).
  Future<void> sendTypedText(String text) async {
    if (text.trim().isEmpty) return;
    unawaited(_handleTurn(text.trim()));
  }

  void _onChunk(Uint8List bytes) {
    final stream = _stream;
    if (stream == null || !_listening) return;

    stream.acceptWaveform(samples: _pcm16ToFloat32(bytes), sampleRate: _sampleRate);
    while (_recognizer.isReady(stream)) {
      _recognizer.decode(stream);
    }

    final partial = _recognizer.getResult(stream).text;
    if (partial.isNotEmpty) _events.add(PartialTranscript(partial));

    if (_recognizer.isEndpoint(stream)) {
      final text = _recognizer.getResult(stream).text.trim();
      _recognizer.reset(stream);
      if (text.isNotEmpty) {
        unawaited(_handleTurn(text));
      }
    }
  }

  /// How long [_prewarmMic] needs, roughly, to have the capture process
  /// actually flowing data (process spawn + PipeWire negotiation). Started
  /// this far before the reply finishes playing, so it's already warm the
  /// moment listening resumes. Tune this if the opening of the next turn
  /// still gets clipped (raise it) or echo reappears (lower it, or check
  /// `_listening`'s ordering below first — it should never be the cause).
  static const _micWarmupLead = Duration(milliseconds: 450);

  Future<void> _handleTurn(String text) async {
    // Genuinely stop (not pause, not just gate) for thinking + generation +
    // (most of) playback: an open capture stream during playback gets
    // PipeWire's echo-cancellation ducking applied to the *output*, which
    // truncates/quiets the reply — confirmed twice now, under two different
    // designs that both left the stream open throughout. Pausing
    // (SIGSTOP) doesn't avoid this either, and separately caused real echo
    // (frozen process, buffered audio flooding through on resume). So: off
    // for the bulk of the turn, and to avoid paying the stop() version's
    // respawn-latency cost at the start of the *next* turn, the mic gets
    // reopened — but not yet trusted — during the last stretch of this
    // reply's own playback, where the overlap is harmless because
    // `_listening` stays false until playback is actually over.
    final wasListening = _micSub != null;
    await stop();
    _events.add(UserTurnFinal(text));
    _events.add(AssistantThinking());
    Timer? prewarmTimer;
    try {
      final turn = await _claude.ask(text);
      _events.add(AssistantReply(turn.text, turn.elapsed));
      _events.add(AssistantSpeaking());

      final sw = Stopwatch()..start();
      final audio = _tts.generate(text: turn.text);
      _normalizeVolume(audio.samples);
      final path = '${_scratchDir!.path}/reply-${DateTime.now().microsecondsSinceEpoch}.wav';
      sherpa.writeWave(filename: path, samples: audio.samples, sampleRate: audio.sampleRate);

      if (wasListening) {
        final playDuration = Duration(milliseconds: (audio.samples.length / audio.sampleRate * 1000).round());
        final lead = playDuration - _micWarmupLead;
        prewarmTimer = Timer(lead > Duration.zero ? lead : Duration.zero, () => unawaited(_prewarmMic()));
      }

      await _play(path); // blocks until the speaker is genuinely done, confirmed earlier
      sw.stop();

      _events.add(AssistantDone(sw.elapsed));
    } catch (e) {
      _events.add(PipelineError('$e'));
    } finally {
      // Runs on both success and failure, so the mic never gets stuck off:
      // on success this is usually a no-op (the timer already got it
      // running during the reply's tail); on an early failure (e.g. before
      // any audio was generated) this is what brings the mic back at all.
      prewarmTimer?.cancel();
      if (wasListening) {
        await _prewarmMic();
        final s = _stream;
        if (s != null) _recognizer.reset(s);
        _listening = true;
        _events.add(ListeningStarted());
      }
    }
  }

  /// Tries each player in turn (this machine runs PipeWire without the
  /// separate pulseaudio-utils package, so `pw-play` is tried before
  /// `paplay`); falls through on a missing binary or a nonzero exit.
  Future<void> _play(String path) async {
    for (final cmd in const ['pw-play', 'paplay', 'aplay']) {
      try {
        final r = await Process.run(cmd, [path]);
        if (r.exitCode == 0) return;
      } on ProcessException {
        // Try the next player.
      }
    }
    _events.add(PipelineError('No working audio player found (tried pw-play, paplay, aplay).'));
  }

  Future<void> dispose() async {
    await stop();
    if (_initialized) {
      await _claude.dispose();
      _tts.free();
      _recognizer.free();
    }
    await _scratchDir?.delete(recursive: true);
    await _events.close();
  }
}

/// Scales [samples] in place so their peak reaches [targetPeak]. The
/// Thorsten voice renders quietly (peak around 0.4 of full scale); a plain
/// WAV at that level plays back faint on typical output volume.
void _normalizeVolume(Float32List samples, {double targetPeak = 0.95}) {
  var peak = 0.0;
  for (final s in samples) {
    final a = s.abs();
    if (a > peak) peak = a;
  }
  if (peak == 0) return;
  final gain = targetPeak / peak;
  for (var i = 0; i < samples.length; i++) {
    samples[i] *= gain;
  }
}

Float32List _pcm16ToFloat32(Uint8List bytes) {
  final n = bytes.length ~/ 2;
  final out = Float32List(n);
  final bd = ByteData.sublistView(bytes);
  for (var i = 0; i < n; i++) {
    out[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}
