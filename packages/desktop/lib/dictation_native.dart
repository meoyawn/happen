import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:openai/dictation.dart';
import 'package:openai/openai.dart';
import 'package:protocol/protocol.dart';

import 'connection.dart';
import 'dictation_platform.dart';

typedef DictationAuthorization = ({String scope, Json credentials});

class DictationPlatform {
  DictationPlatform(this.client);
  final AgentClient client;
  HttpClient? _http;
  TranscriptionClient? _transcription;
  static const _audioEvents = EventChannel('happen/dictation/audio');

  late final Stream<DictationCaptureEvent> audio = _audioEvents.receiveBroadcastStream()
    .map<DictationCaptureEvent?>((event) => switch (event) {
      {'id': final String id, 'type': 'audio', 'pcm': final Uint8List pcm} =>
        DictationAudio(id, pcm, (event['rms'] as num?)?.toDouble() ?? 0),
      {'id': final String id, 'type': 'error'} => DictationCaptureFailure(id),
      _ => null,
    }).where((event) => event != null).cast<DictationCaptureEvent>();

  Future<DictationAuthorization> startCapture(String id, {required CancellationToken cancellation,
    required void Function() listenForAudio}) async {
    if (!Platform.isMacOS) throw StateError('Dictation is not available on this device');
    // A rebuilt native runner is required before authorizing or requesting microphone access.
    await dictationMethods.invokeMethod<void>('status').asCancellable(cancellation);
    final authorization = await client.desktopAuthorization(cancellation: cancellation);
    final scope = requiredString(authorization, 'account_id');
    cancellation.throwIfCancelled();
    listenForAudio();
    await dictationMethods.invokeMethod<void>('start', {'id': id}).asCancellable(cancellation);
    return (scope: scope, credentials: authorization);
  }

  Future<void> stopCapture(String id) async {
    try { await dictationMethods.invokeMethod<void>('stop', {'id': id}); }
    catch (_) { /* The native bridge may have already released the microphone. */ }
  }

  Future<void> Function()? get openMicrophoneSettings => _openMicrophoneSettings;
  Future<void> _openMicrophoneSettings() => dictationMethods.invokeMethod<void>('openMicrophoneSettings');

  Future<LiveDictation> openStream(DictationAuthorization authorization, {required CancellationToken cancellation,
    required void Function(String) onTranscript, required void Function() onError}) async {
    final stream = TranscriptionStream(onTranscript: onTranscript, onError: onError);
    await stream.connect(authorization.credentials, cancellation: cancellation);
    return (append: stream.append, finish: stream.finish, close: stream.close);
  }

  Future<String> transcribe(Uint8List pcm, String scope, {required CancellationToken cancellation}) {
    final http = _http ??= HttpClient()..connectionTimeout = const Duration(seconds: 30);
    final transcription = _transcription ??= TranscriptionClient(http: http, credentials: client.desktopAuthorization);
    return transcription.transcribe(dictationWav(pcm), accountId: scope, cancellation: cancellation);
  }

  void dispose() => _http?.close(force: true);
}
