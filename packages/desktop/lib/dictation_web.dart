import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:openai/dictation.dart';
import 'package:protocol/protocol.dart';
import 'package:web/web.dart' as web;

import 'connection_web.dart';
import 'dictation_platform.dart';

typedef DictationAuthorization = ({String scope});

class DictationPlatform {
  DictationPlatform(this.client);
  final AgentClient client;
  final _events = StreamController<DictationCaptureEvent>.broadcast(sync: true);
  Stream<DictationCaptureEvent> get audio => _events.stream;
  _Microphone? _microphone;

  Future<DictationAuthorization> startCapture(String id, {required CancellationToken cancellation,
    required void Function() listenForAudio}) async {
    final navigator = web.window.navigator;
    if (!web.window.isSecureContext || !navigator.has('mediaDevices') || !globalContext.has('AudioContext')) {
      throw PlatformException(code: 'microphone_unavailable');
    }
    final microphone = _microphone = _Microphone(id, web.AudioContext(web.AudioContextOptions(sampleRate: dictationSampleRate)));
    // Start resuming the context while the browser still has the click's user activation.
    final resumed = microphone.context.resume().toDart..ignore();
    final scope = await client.dictationScope(cancellation: cancellation);
    cancellation.throwIfCancelled();
    try {
      final media = await navigator.mediaDevices.getUserMedia(web.MediaStreamConstraints(audio: true.toJS)).toDart.then((media) {
        // The browser can resolve a permission request after the composer has cancelled it.
        if (cancellation.isCancelled) {
          for (final track in media.getTracks().toDart) { track.stop(); }
        } else { microphone.media = media; }
        return media;
      }).asCancellable(cancellation);
      await resumed.timeout(const Duration(seconds: 5)).asCancellable(cancellation);
      cancellation.throwIfCancelled();
      listenForAudio();
      final source = microphone.source = microphone.context.createMediaStreamSource(media);
      final processor = microphone.processor = microphone.context.createScriptProcessor(2048, 1, 1);
      processor.onaudioprocess = ((web.AudioProcessingEvent event) {
        final samples = event.inputBuffer.getChannelData(0).toDart;
        final pcm = ByteData(samples.length * 2);
        var power = 0.0;
        for (var i = 0; i < samples.length; i++) {
          final sample = samples[i].clamp(-1.0, 1.0);
          power += sample * sample;
          pcm.setInt16(i * 2, (sample * 32767).round(), Endian.little);
        }
        _events.add(DictationAudio(id, pcm.buffer.asUint8List(), math.sqrt(power / samples.length)));
      }).toJS;
      for (final track in media.getAudioTracks().toDart) {
        track.onended = ((web.Event _) => _events.add(DictationCaptureFailure(id))).toJS;
      }
      source.connect(processor);
      // The processor emits silence while delivering input frames to Dart.
      processor.connect(microphone.context.destination);
      return (scope: scope);
    } catch (failure) {
      cancellation.throwIfCancelled();
      if (!failure.isA<web.DOMException>()) rethrow;
      throw PlatformException(code: switch ((failure as web.DOMException).name) {
        'NotAllowedError' || 'SecurityError' => 'microphone_permission',
        'NotFoundError' => 'microphone_missing',
        _ => 'microphone_capture',
      });
    }
  }

  Future<void> stopCapture(String id) async {
    final microphone = _microphone;
    if (microphone == null || microphone.id != id) return;
    _microphone = null;
    microphone.processor?.onaudioprocess = null;
    microphone.source?.disconnect();
    microphone.processor?.disconnect();
    for (final track in microphone.media?.getTracks().toDart ?? const <web.MediaStreamTrack>[]) {
      track.onended = null;
      track.stop();
    }
    try { await microphone.context.close().toDart; }
    catch (_) { /* The browser can close the context during page teardown. */ }
  }

  Future<void> Function()? get openMicrophoneSettings => null;

  Future<LiveDictation> openStream(DictationAuthorization authorization, {required CancellationToken cancellation,
    required void Function(String) onTranscript, required void Function() onError}) async {
    final socket = await client.openDictationSocket(authorization.scope, live: true, cancellation: cancellation,
      onTranscript: onTranscript, onError: onError);
    return (append: socket.append, finish: socket.finish, close: socket.close);
  }

  Future<String> transcribe(Uint8List pcm, String scope, {required CancellationToken cancellation}) async {
    final timeout = TimeoutCancellationToken(const Duration(minutes: 2));
    final token = cancellation.merge(timeout);
    try {
      final socket = await client.openDictationSocket(scope, live: false, cancellation: token);
      try {
        for (var offset = 0; offset < pcm.length; offset += dictationMaxFrameBytes) {
          await socket.waitForCapacity();
          final end = math.min(offset + dictationMaxFrameBytes, pcm.length);
          socket.append(Uint8List.sublistView(pcm, offset, end));
        }
        return await socket.finish();
      } finally { socket.close(); }
    } finally { timeout.cancel(); }
  }

  void dispose() => unawaited(_events.close());
}

class _Microphone {
  _Microphone(this.id, this.context);
  final String id;
  final web.AudioContext context;
  web.MediaStream? media;
  web.MediaStreamAudioSourceNode? source;
  web.ScriptProcessorNode? processor;
}
