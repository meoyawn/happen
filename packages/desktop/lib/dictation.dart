import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:ai/ai.dart' show HttpConnections;
import 'package:openai/openai.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

enum DictationPhase { idle, starting, recording, transcribing, failed }
enum DictationAction { insert, send }

class DictationResult {
  const DictationResult(this.text, this.action);
  final String text;
  final DictationAction action;
}

/// One physical microphone, owned by the desktop session rather than a chat.
/// Both live and on-stop audio go directly to OpenAI and remain memory-only.
class DictationService extends ChangeNotifier {
  DictationService(this.client);
  final AgentClient client;
  HttpClient? _http;
  HttpConnections? _connections;
  TranscriptionClient? _transcription;
  static const methods = MethodChannel('happen/dictation');
  static const _audioEvents = EventChannel('happen/dictation/audio');
  static const _maximumAudioBytes = 16000 * 2 * 600;
  final amplitude = ValueNotifier<double>(0);
  DictationPhase phase = DictationPhase.idle;
  String? error;
  String transcript = '';
  bool liveTranscription = false;
  String? _liveStatus;
  String? get liveTranscriptionHint => !liveTranscription ? null : switch (_liveStatus) {
    'connecting' => 'Connecting live dictation…',
    'streaming' => 'Live dictation',
    'fallback' => 'Text will appear when you stop',
    _ => null,
  };
  Object? owner;
  bool microphonePermissionDenied = false;
  bool get active => phase == DictationPhase.starting || phase == DictationPhase.recording || phase == DictationPhase.transcribing;
  bool get canRetry => phase == DictationPhase.failed && _audioBytes > 0;
  bool _disposed = false;
  int _generation = 0, _audioBytes = 0;
  String? _accountId, _captureId;
  final _audio = <Uint8List>[];
  CancellationToken? _operation;
  StreamSubscription<dynamic>? _subscription;
  Stopwatch? _clock;
  Timer? _limit;
  VoidCallback? _onRecordingLimit;
  Future<void>? _releasing;
  TranscriptionStream? _stream;
  Future<TranscriptionStream?>? _streamOpening;

  Future<void> start({required Object owner, required VoidCallback onRecordingLimit, bool liveTranscription = false}) async {
    if (_disposed || active) return;
    final generation = ++_generation;
    _operation?.cancel();
    _clearAudio();
    _accountId = null;
    this.owner = owner;
    error = null;
    transcript = '';
    this.liveTranscription = liveTranscription;
    _liveStatus = liveTranscription ? 'connecting' : null;
    microphonePermissionDenied = false;
    phase = DictationPhase.starting;
    final id = newId();
    final cancellation = _operation = CancellationToken();
    _publish();
    try {
      if (!Platform.isMacOS) throw StateError('Dictation is not available on this device');
      // A rebuilt native runner is required before authorizing or asking for mic access.
      await methods.invokeMethod<dynamic>('status').asCancellable(cancellation);
      if (!_current(generation)) return;
      final authorization = await client.desktopAuthorization(cancellation: cancellation);
      if (!_current(generation)) return;
      _accountId = requiredString(authorization, 'account_id');
      await _releasing;
      if (!_current(generation)) return;
      _subscription ??= _audioEvents.receiveBroadcastStream().listen(_receiveAudio, onError: _captureFailed);
      _captureId = id;
      await methods.invokeMethod<dynamic>('start', {'id': id}).asCancellable(cancellation);
      if (!_current(generation)) return;
      _clock = Stopwatch()..start();
      _onRecordingLimit = onRecordingLimit;
      _limit = Timer(const Duration(seconds: 595), () {
        if (_current(generation) && phase == DictationPhase.recording) _onRecordingLimit?.call();
      });
      phase = DictationPhase.recording;
      _publish();
      if (liveTranscription) _streamOpening = _openStream(generation, authorization, cancellation);
    } catch (failure) {
      if (!_current(generation)) return;
      await _releaseCapture();
      if (!_current(generation)) return;
      cancellation.cancel();
      _clearAudio();
      microphonePermissionDenied = failure is PlatformException && failure.code == 'microphone_permission';
      error = _userError(failure, starting: true);
      phase = DictationPhase.failed;
      _publish();
    }
  }

  Future<DictationResult?> stop(DictationAction action) async {
    if (_disposed || phase != DictationPhase.recording) return null;
    final generation = _generation;
    phase = DictationPhase.transcribing;
    _limit?.cancel();
    _publish();
    await _releaseCapture();
    if (!_current(generation)) return null;
    if ((_clock?.elapsedMilliseconds ?? 0) < 250 || _audioBytes == 0) {
      await cancel();
      return null;
    }
    return _finish(generation, action, useStreaming: true);
  }

  Future<DictationResult?> retry(DictationAction action) async {
    if (_disposed || !canRetry) return null;
    final generation = ++_generation;
    _operation?.cancel();
    _operation = CancellationToken();
    error = null;
    phase = DictationPhase.transcribing;
    _publish();
    return _finish(generation, action, useStreaming: false);
  }

  Future<TranscriptionStream?> _openStream(int generation, Json authorization, CancellationToken cancellation) async {
    void status(String value) {
      if (!_current(generation)) return;
      _liveStatus = value;
      _publish();
    }
    final stream = _stream = TranscriptionStream(onError: () => status('fallback'), onTranscript: (text) {
      if (!_current(generation)) return;
      transcript = text;
      _publish();
    });
    try {
      await stream.connect(authorization, cancellation: cancellation);
      if (!_current(generation)) { stream.close(); return null; }
      // Replay frames captured during the handshake exactly once. New frames
      // are forwarded only after this synchronous replay completes.
      for (final chunk in _audio) { stream.append(chunk); }
      status('streaming');
      return stream;
    } catch (_) {
      stream.close();
      if (identical(_stream, stream)) _stream = null;
      status('fallback');
      return null;
    }
  }

  Future<DictationResult?> _finish(int generation, DictationAction action, {required bool useStreaming}) async {
    try {
      String? text;
      if (useStreaming) {
        final stream = await _streamOpening;
        if (!_current(generation)) return null;
        if (stream != null) {
          try { text = await stream.finish(); }
          on CancelledException { rethrow; }
          catch (_) { /* Transcribe the retained PCM directly over HTTP. */ }
        }
      }
      if (!_current(generation)) return null;
      if (text == null) {
        final pcm = BytesBuilder(copy: false);
        for (final bytes in _audio) { pcm.add(bytes); }
        final http = _http ??= HttpClient()
          ..connectionTimeout = const Duration(seconds: 30)
          ..idleTimeout = const Duration(minutes: 5);
        final connections = _connections ??= HttpConnections(http: http);
        final transcription = _transcription ??= TranscriptionClient(
          http: http, connections: connections,
          credentials: client.desktopAuthorization,
        );
        text = await transcription.transcribe(_wav(pcm.takeBytes()), accountId: _accountId!, cancellation: _operation!);
      }
      if (!_current(generation)) return null;
      if (text.trim().isEmpty) throw StateError("Didn't quite catch that. Please try again");
      transcript = text.trim();
      final result = DictationResult(text.trim(), action);
      _closeStream();
      _clearAudio();
      _accountId = null;
      phase = DictationPhase.idle;
      error = null;
      _publish();
      return result;
    } catch (failure) {
      if (!_current(generation)) return null;
      _closeStream();
      error = _userError(failure);
      phase = DictationPhase.failed;
      _publish();
      return null;
    }
  }

  Future<void> cancel() async {
    if (_disposed) return;
    final generation = ++_generation;
    _operation?.cancel();
    _operation = null;
    _closeStream();
    _accountId = null;
    final release = _releaseCapture();
    _captureId = null;
    _clearAudio();
    owner = null;
    error = null;
    transcript = '';
    _liveStatus = null;
    microphonePermissionDenied = false;
    phase = DictationPhase.idle;
    await release;
    if (_current(generation)) _publish();
  }

  Future<void> openMicrophoneSettings() => methods.invokeMethod<void>('openMicrophoneSettings');

  void _receiveAudio(dynamic event) {
    if (_disposed || !active || event is! Map || event['id'] != _captureId) return;
    if (event['type'] == 'error') {
      _captureFailed(StateError('Close other apps using the microphone'));
      return;
    }
    final bytes = event['pcm'];
    if (event['type'] != 'audio' || bytes is! Uint8List || _audioBytes + bytes.length > _maximumAudioBytes) return;
    _audio.add(bytes);
    _audioBytes += bytes.length;
    if (_liveStatus == 'streaming') _stream?.append(bytes);
    final rms = (event['rms'] as num?)?.toDouble() ?? 0;
    amplitude.value = rms.isFinite ? rms : 0;
  }

  void _captureFailed(Object failure) {
    if (_disposed || _captureId == null || !active) return;
    final generation = ++_generation;
    _operation?.cancel();
    _closeStream();
    unawaited(_releaseCapture().then((_) {
      if (!_current(generation)) return;
      error = _userError(failure, starting: true);
      phase = DictationPhase.failed;
      _publish();
    }));
  }

  Future<void> _releaseCapture() async {
    _limit?.cancel();
    _limit = null;
    _onRecordingLimit = null;
    final id = _captureId;
    if (id == null) { await _releasing; return; }
    // Keep accepting the last queued frames until native stop has drained them.
    final clock = _clock;
    final release = _releasing = methods.invokeMethod<void>('stop', {'id': id}).catchError((Object _) {});
    await release;
    if (_captureId == id) _captureId = null;
    if (identical(_releasing, release)) _releasing = null;
    clock?.stop();
    if (!_disposed && _captureId == null) amplitude.value = 0;
  }

  void _clearAudio() {
    _audio.clear();
    _audioBytes = 0;
    _clock = null;
    _limit?.cancel();
    _limit = null;
    _onRecordingLimit = null;
  }

  void _closeStream() {
    _stream?.close();
    _stream = null;
    _streamOpening = null;
  }

  bool _current(int generation) => !_disposed && _generation == generation;
  void _publish() { if (!_disposed) notifyListeners(); }

  @override
  void dispose() {
    if (_disposed) return;
    ++_generation;
    _operation?.cancel();
    _closeStream();
    unawaited(_releaseCapture());
    _disposed = true;
    owner = null;
    unawaited(_subscription?.cancel());
    _clearAudio();
    unawaited(_connections?.close());
    _http?.close(force: true);
    amplitude.dispose();
    super.dispose();
  }
}

String _userError(Object failure, {bool starting = false}) {
  if (failure is MissingPluginException) return 'Reopen Happen to enable microphone capture';
  if (failure is PlatformException) {
    return switch (failure.code) {
      'microphone_permission' => 'Enable mic access to dictate',
      'microphone_missing' => 'Connect a microphone to use dictation',
      'microphone_busy' => 'The microphone is already in use by dictation',
      _ => 'Close other apps using the microphone',
    };
  }
  final message = failure.toString();
  for (final known in ["Didn't quite catch that. Please try again", 'Check your connection and try again',
    'Sign in to ChatGPT on this computer to use dictation', 'Finish signing in before starting dictation',
    'Dictation is temporarily limited. Please try again later.', 'The signed-in workspace changed. Start dictation again.',
    'Your current IP address is not authorized for this workspace.', 'Start dictation again',
    'Dictation is not available on this device', 'Close other apps using the microphone']) {
    if (message.contains(known)) return known;
  }
  if (message.contains('signed in') || message.contains('login') || message.contains('refresh')) {
    return 'Sign in to ChatGPT on this computer to use dictation';
  }
  return starting ? 'Unable to start dictation' : 'Unable to transcribe audio';
}

Uint8List _wav(Uint8List pcm) {
  final data = ByteData(44);
  final bytes = data.buffer.asUint8List();
  bytes.setRange(0, 4, ascii.encode('RIFF'));
  data.setUint32(4, 36 + pcm.length, Endian.little);
  bytes.setRange(8, 16, ascii.encode('WAVEfmt '));
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  bytes.setRange(36, 40, ascii.encode('data'));
  data.setUint32(40, pcm.length, Endian.little);
  return (BytesBuilder(copy: false)..add(bytes)..add(pcm)).takeBytes();
}
