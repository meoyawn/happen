import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:protocol/protocol.dart';

/// Direct desktop audio streaming. Transport failures leave HTTP recovery to
/// the recording owner; credentials and server messages never enter errors.
class TranscriptionStream {
  TranscriptionStream({required this.onTranscript, required this.onError}) {
    unawaited(_started.future.catchError((Object _) {}));
    unawaited(_finished.future.catchError((Object _) {}));
  }
  final void Function(String) onTranscript;
  final void Function() onError;
  final _started = Completer<void>(), _finished = Completer<void>();
  final _utterances = <String, ({int revision, String text, bool finalText})>{};
  HttpClient? _http;
  WebSocket? _socket;
  StreamSubscription<dynamic>? _input;
  CancellationHook? _hook;
  CancellationToken? _cancellation;
  Object? _error;
  bool _closed = false, _closing = false;
  bool get acceptingAudio => !_closed && !_closing && _started.isCompleted && _error == null && _socket?.readyState == WebSocket.open;

  Future<void> connect(Json authorization, {required CancellationToken cancellation, Uri? endpoint}) async {
    cancellation.throwIfCancelled();
    _cancellation = cancellation;
    _hook = CancellationHook(cancellation, close);
    try {
      final http = _http = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      final uri = endpoint ?? Uri.parse('wss://chatgpt.com/backend-api/dictation/stream?dictation_surface=composer');
      final socket = await WebSocket.connect(uri.toString(), protocols: ['chatgpt-dictation', 'codex-desktop'],
        headers: {
          'Authorization': 'Bearer ${requiredString(authorization, 'access_token')}',
          'ChatGPT-Account-Id': requiredString(authorization, 'account_id'),
          'originator': 'agent', 'User-Agent': 'agent/0.1.0 (Dart)',
        }, customClient: _HandshakeClient(http), maxPayloadLength: 8 * 1024 * 1024).then((socket) {
          if (_closed) unawaited(socket.close());
          return socket;
        }).timeout(const Duration(seconds: 10)).asCancellable(cancellation);
      cancellation.throwIfCancelled();
      if (_closed) throw StateError('Dictation stream closed');
      _socket = socket;
      _input = socket.listen(_receive, onError: (Object _) => _fail(), onDone: () {
        if (!_closed && !_finished.isCompleted) _fail();
      });
      socket.add(jsonEncode({
        'type': 'session.start',
        'config': {
          'input_audio_format': 'pcm16', 'sample_rate_hz': 16000, 'num_channels': 1,
          'max_buffer_size_bytes': 4194304, 'max_utterance_duration_ms': 30000,
          'session_ttl_ms': 300000, 'provider_mode': 'streaming_sse',
          'transcript_delivery_mode': 'segment',
          'vad': {'type': 'server_vad', 'threshold': 0.5, 'prefix_padding_ms': 300, 'silence_duration_ms': 500},
        },
      }));
      await _started.future.timeout(const Duration(seconds: 10)).asCancellable(cancellation);
      if (_closed) throw StateError('Dictation stream closed');
    } catch (_) {
      close();
      cancellation.throwIfCancelled();
      throw StateError('Unable to connect live dictation');
    }
  }

  void append(Uint8List pcm) {
    if (acceptingAudio) _socket?.add(jsonEncode({'type': 'audio.append', 'audio': base64Encode(pcm)}));
  }

  Future<String> finish() async {
    try {
      _cancellation!.throwIfCancelled();
      if (_error != null) throw _error!;
      if (_closed) throw StateError('Dictation stream closed');
      _closing = true;
      _socket!.add(jsonEncode({'type': 'session.close'}));
      await _finished.future.timeout(const Duration(seconds: 8)).asCancellable(_cancellation!);
      if (_utterances.values.any((value) => !value.finalText) || _text.isEmpty) {
        throw StateError('Dictation stream did not finish every segment');
      }
      return _text;
    } finally { close(); }
  }

  String get _text => _utterances.values.map((value) => value.text).where((text) => text.isNotEmpty).join(' ').trim();

  void _receive(dynamic raw) {
    if (_closed) return;
    if (raw is! String || raw.length > 8 * 1024 * 1024 || utf8.encode(raw).length > 8 * 1024 * 1024) { _fail(); return; }
    final Json value;
    try { value = jsonObject(jsonDecode(raw)); } catch (_) { _fail(); return; }
    final type = value['type'];
    if (type == 'session.started') {
      if (!_started.isCompleted) _started.complete();
    } else if (type == 'transcript.segment' || type == 'transcript.final') {
      final id = value['utterance_id'], text = value['text'], revision = value['revision'];
      if (id is! String || text is! String || revision is! int || revision < 0) return;
      final old = _utterances[id];
      final finalText = type == 'transcript.final';
      // Final and partial revisions are independent counters in the protocol.
      final accept = finalText ? old?.finalText != true || revision >= old!.revision
        : old?.finalText != true && revision >= (old?.revision ?? 0);
      if (accept) {
        _utterances[id] = (revision: revision, text: text, finalText: finalText);
        final transcript = _text;
        if (transcript.length > 1024 * 1024) { _fail(); return; }
        onTranscript(transcript);
      }
    } else if (type == 'session.updated' && value['session'] is Map && value['session']['status'] == 'closed') {
      if (!_closing) { _fail(); return; }
      if (!_finished.isCompleted) _finished.complete();
    } else if (type == 'transcript.failed' || type == 'session.error' && value['fatal'] == true) {
      _fail();
    }
  }

  void _fail() {
    if (_closed) return;
    _error = StateError('Unable to transcribe audio');
    close();
    onError();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    final failure = _cancellation?.isCancelled == true ? _cancellation!.exception! :
      _error ?? StateError('Dictation stream closed');
    if (!_started.isCompleted) _started.completeError(failure);
    if (!_finished.isCompleted) _finished.completeError(failure);
    _hook?.dispose();
    final input = _input, socket = _socket;
    if (socket != null) {
      unawaited(socket.close().whenComplete(() => input?.cancel()));
    } else { unawaited(input?.cancel()); }
    _socket = null;
    _http?.close(force: true);
    _http = null;
  }
}

// Keep SDK upgrade validation, but never forward account headers to redirects.
class _HandshakeClient implements HttpClient {
  _HandshakeClient(this.http);
  final HttpClient http;
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async => _HandshakeRequest(await http.openUrl(method, url));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HandshakeRequest implements HttpClientRequest {
  _HandshakeRequest(this.request);
  final HttpClientRequest request;
  @override
  HttpHeaders get headers => request.headers;
  @override
  Future<HttpClientResponse> close() {
    request.followRedirects = false;
    request.headers.removeAll(HttpHeaders.cacheControlHeader);
    return request.close();
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
