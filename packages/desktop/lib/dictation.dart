import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:openai/dictation.dart';
import 'package:protocol/protocol.dart';

import 'connection.dart';
import 'dictation_native.dart' if (dart.library.js_interop) 'dictation_web.dart';
import 'dictation_platform.dart';
import 'dictation_state.dart';

enum DictationAction { insert, send }
enum _LiveStatus { connecting, streaming, fallback }
typedef DictationConversation = ({Object scope, String draftKey});

class DictationResult {
  const DictationResult(this.text, this.action);
  final String text;
  final DictationAction action;
}

/// Owns the recording across composers and retains audio in memory for retry.
class DictationService extends ChangeNotifier {
  DictationService(AgentClient client) : _platform = DictationPlatform(client);
  final DictationPlatform _platform;
  static const methods = dictationMethods;
  final amplitude = ValueNotifier<double>(0);
  DictationState _state = const DictationIdle();
  DictationState get state => _state;
  String? get error => switch (_state) { DictationFailed(:final error) => error, _ => null };
  String _transcript = '';
  String get transcript => _transcript;
  _LiveStatus? _liveStatus;
  String? get liveTranscriptionHint => switch (_liveStatus) {
    _LiveStatus.connecting => 'Connecting live dictation…',
    _LiveStatus.streaming => 'Live dictation',
    _LiveStatus.fallback => 'Text will appear when you stop',
    null => null,
  };
  Object? _owner;
  Object? get owner => _owner;
  DictationConversation? _conversation;
  DictationConversation? get conversation => _conversation;
  bool get microphonePermissionDenied => switch (_state) {
    DictationFailed(microphonePermissionDenied: true) => true, _ => false,
  };
  bool get active => switch (_state) {
    DictationStarting() || DictationRecording() || DictationTranscribing() => true,
    DictationIdle() || DictationFailed() || DictationDisposed() => false,
  };
  bool get canRetry => switch (_state) { DictationFailed(canRetry: true) => true, _ => false };
  bool get _disposed => _state is DictationDisposed;
  int _generation = 0, _audioBytes = 0;
  String? _accountScope, _captureId;
  final _audio = <Uint8List>[];
  CancellationToken? _operation;
  StreamSubscription<DictationCaptureEvent>? _subscription;
  Stopwatch? _clock;
  Timer? _limit;
  Future<void>? _releasing;
  LiveDictation? _stream;
  Future<LiveDictation?>? _streamOpening;

  Future<void> start({required Object owner, required DictationConversation conversation,
    required VoidCallback onRecordingLimit, bool liveTranscription = false}) async {
    if (_disposed || active) return;
    final generation = ++_generation;
    _operation?.cancel();
    _clearAudio();
    _accountScope = null;
    _owner = owner;
    _conversation = conversation;
    _transcript = '';
    _liveStatus = liveTranscription ? _LiveStatus.connecting : null;
    final id = newId();
    final cancellation = _operation = CancellationToken();
    _transition(const DictationStarting());
    try {
      if (_releasing case final releasing?) await releasing;
      if (!_current(generation)) return;
      _captureId = id;
      final authorization = await _platform.startCapture(id, cancellation: cancellation,
        listenForAudio: () => _subscription ??= _platform.audio.listen(_receiveAudio, onError: _captureFailed));
      if (!_current(generation)) return;
      _accountScope = authorization.scope;
      _clock = Stopwatch()..start();
      _limit = Timer(const Duration(seconds: 595), () {
        if (_current(generation) && _state is DictationRecording) onRecordingLimit();
      });
      _transition(const DictationRecording());
      if (liveTranscription) _streamOpening = _openStream(generation, authorization, cancellation);
    } catch (failure) {
      if (!_current(generation)) return;
      await _releaseCapture();
      if (!_current(generation)) return;
      cancellation.cancel();
      _clearAudio();
      _transition(DictationFailed(_userError(failure, starting: true),
        microphonePermissionDenied: failure is PlatformException && failure.code == 'microphone_permission'));
    }
  }

  Future<DictationResult?> stop(DictationAction action) async {
    if (_state is! DictationRecording) return null;
    final generation = _generation;
    _limit?.cancel();
    _transition(const DictationTranscribing());
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
    _transition(const DictationTranscribing());
    return _finish(generation, action, useStreaming: false);
  }

  Future<LiveDictation?> _openStream(int generation, DictationAuthorization authorization, CancellationToken cancellation) async {
    void status(_LiveStatus value) {
      if (!_current(generation) || _liveStatus == value) return;
      _liveStatus = value;
      _publish();
    }
    LiveDictation? opened;
    try {
      final stream = opened = await _platform.openStream(authorization, cancellation: cancellation,
        onError: () => status(_LiveStatus.fallback), onTranscript: (text) {
          if (!_current(generation)) return;
          _transcript = text;
          _publish();
        });
      if (!_current(generation)) { stream.close(); return null; }
      // Replay frames captured during the handshake exactly once. New frames
      // are forwarded only after this synchronous replay completes.
      for (final chunk in _audio) {
        stream.append(chunk);
        if (_liveStatus == _LiveStatus.fallback) { stream.close(); return null; }
      }
      _stream = stream;
      status(_LiveStatus.streaming);
      return stream;
    } catch (_) {
      opened?.close();
      status(_LiveStatus.fallback);
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
          catch (_) { /* Transcribe the retained recording. */ }
        }
      }
      if (!_current(generation)) return null;
      if (text == null) {
        final pcm = BytesBuilder(copy: false);
        for (final bytes in _audio) { pcm.add(bytes); }
        text = await _platform.transcribe(pcm.takeBytes(), _accountScope!, cancellation: _operation!);
      }
      if (!_current(generation)) return null;
      if (text.trim().isEmpty) throw StateError("Didn't quite catch that. Please try again");
      _transcript = text.trim();
      final result = DictationResult(_transcript, action);
      _closeStream();
      _clearAudio();
      _accountScope = null;
      _liveStatus = null;
      _transition(const DictationIdle());
      return result;
    } catch (failure) {
      if (!_current(generation)) return null;
      _closeStream();
      _transition(DictationFailed(_userError(failure), canRetry: _audioBytes > 0));
      return null;
    }
  }

  Future<void> cancel() async {
    if (_disposed) return;
    final generation = ++_generation;
    _operation?.cancel();
    _operation = null;
    _closeStream();
    _accountScope = null;
    final release = _releaseCapture();
    _captureId = null;
    _clearAudio();
    _owner = null;
    _conversation = null;
    _transcript = '';
    _liveStatus = null;
    _transition(const DictationIdle(), notify: false);
    await release;
    if (_current(generation)) _publish();
  }

  Future<void> Function()? get openMicrophoneSettings => _platform.openMicrophoneSettings;

  void _receiveAudio(DictationCaptureEvent event) {
    if (_disposed || !active || event.id != _captureId) return;
    switch (event) {
      case DictationCaptureFailure():
        _captureFailed(StateError('The microphone stopped. Check your microphone and try again'));
      case DictationAudio(:final pcm, :final rms):
        if (_audioBytes + pcm.length > dictationMaxAudioBytes) return;
        _audio.add(pcm);
        _audioBytes += pcm.length;
        if (_liveStatus == _LiveStatus.streaming) _stream?.append(pcm);
        amplitude.value = rms.isFinite ? rms : 0;
    }
  }

  void _captureFailed(Object failure) {
    if (_disposed || _captureId == null || !active) return;
    final generation = ++_generation;
    _operation?.cancel();
    _closeStream();
    unawaited(_releaseCapture().then((_) {
      if (!_current(generation)) return;
      _transition(DictationFailed(_userError(failure, starting: true), canRetry: _accountScope != null && _audioBytes > 0));
    }));
  }

  Future<void> _releaseCapture() {
    _limit?.cancel();
    _limit = null;
    if (_releasing case final releasing?) return releasing;
    final id = _captureId;
    if (id == null) return Future<void>.value();
    final clock = _clock;
    // Native stop drains any queued frames before clearing the capture ID.
    return _releasing = _platform.stopCapture(id).whenComplete(() {
      if (_captureId == id) _captureId = null;
      _releasing = null;
      clock?.stop();
      if (!_disposed && _captureId == null) amplitude.value = 0;
    });
  }

  void _clearAudio() {
    _audio.clear();
    _audioBytes = 0;
    _clock = null;
    _limit?.cancel();
    _limit = null;
  }

  void _closeStream() {
    _stream?.close();
    _stream = null;
    _streamOpening = null;
  }

  bool _current(int generation) => !_disposed && _generation == generation;
  void _transition(DictationState next, {bool notify = true}) {
    _state = transitionDictation(_state, next);
    if (notify) _publish();
  }
  void _publish() { if (!_disposed) notifyListeners(); }

  @override
  void dispose() {
    if (_disposed) return;
    ++_generation;
    _operation?.cancel();
    _closeStream();
    unawaited(_releaseCapture());
    _transition(const DictationDisposed());
    _owner = null;
    _conversation = null;
    unawaited(_subscription?.cancel());
    _clearAudio();
    _platform.dispose();
    amplitude.dispose();
    super.dispose();
  }
}

String _userError(Object failure, {bool starting = false}) {
  if (failure is MissingPluginException) return 'Reopen Happen to enable microphone capture';
  if (failure is PlatformException) {
    return switch (failure.code) {
      'microphone_permission' => kIsWeb ? 'Allow microphone access for this site, then try again' : 'Enable mic access to dictate',
      'microphone_unavailable' => 'Dictation needs a secure page and browser microphone access',
      'microphone_missing' => 'Connect a microphone to use dictation',
      'microphone_busy' => 'The microphone is already in use by dictation',
      _ => 'Close other apps using the microphone',
    };
  }
  const signIn = 'Sign in to ChatGPT on this computer to use dictation';
  if (dictationErrorMessage(failure) case final known?) {
    return kIsWeb && known == signIn ? 'Sign in to ChatGPT in Settings to use dictation' : known;
  }
  final message = failure.toString();
  for (final known in ['Dictation is not available on this device', 'Close other apps using the microphone',
    'The microphone stopped. Check your microphone and try again', 'Sign in with your owner key',
    'The server is unavailable. Try again shortly.']) {
    if (message.contains(known)) return known;
  }
  if (message.contains('signed in') || message.contains('login') || message.contains('refresh')) {
    return kIsWeb ? 'Sign in to ChatGPT in Settings to use dictation' : signIn;
  }
  return starting ? 'Unable to start dictation' : 'Unable to transcribe audio';
}
