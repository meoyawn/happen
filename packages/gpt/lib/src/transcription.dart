import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:protocol/protocol.dart';

typedef TranscriptionCredentials = Future<Json> Function({bool refresh, required CancellationToken cancellation});

/// Harness's non-streaming composer protocol, sent directly by the desktop.
/// Audio and response bodies never enter task history or diagnostics.
class TranscriptionClient {
  TranscriptionClient({required this.http, required this.credentials, Uri? endpoint})
    : endpoint = endpoint ?? Uri.parse('https://chatgpt.com/backend-api/transcribe');

  final HttpClient http;
  final TranscriptionCredentials credentials;
  final Uri endpoint;

  Future<String> transcribe(Uint8List wav, {required String accountId,
    required CancellationToken cancellation}) async {
    Future<Json> authorize({bool refresh = false}) async {
      cancellation.throwIfCancelled();
      final auth = await credentials(refresh: refresh, cancellation: cancellation).asCancellable(cancellation);
      cancellation.throwIfCancelled();
      if (auth['account_id'] != accountId) {
        throw StateError('The signed-in workspace changed. Start dictation again.');
      }
      return auth;
    }
    var auth = await authorize();
    final boundary = '----codex-transcribe-${newId()}';
    final body = (BytesBuilder(copy: false)
      ..add(utf8.encode('--$boundary\r\nContent-Disposition: form-data; name="file"; filename="codex.wav"\r\nContent-Type: audio/wav\r\n\r\n'))
      ..add(wav)
      ..add(utf8.encode('\r\n--$boundary--\r\n'))).takeBytes();
    for (var attempt = 0; ; attempt++) {
      try {
        var refreshed = false;
        while (true) {
          cancellation.throwIfCancelled();
          final result = await _post(body, boundary, auth, cancellation);
          if (result.status == 401 && !refreshed && !result.workspaceRefusal) {
            refreshed = true;
            auth = await authorize(refresh: true);
            continue;
          }
          if (result.status >= 200 && result.status < 300) {
            final text = result.body['text'];
            if (text is! String) throw StateError('Unable to transcribe audio');
            if (text.trim().isEmpty) throw StateError("Didn't quite catch that. Please try again");
            return text.trim();
          }
          throw result;
        }
      } on _TranscriptionFailure catch (failure) {
        cancellation.throwIfCancelled();
        final delay = failure.retryDelay(attempt);
        if (delay == null) throw StateError(failure.message);
        await cancellableDelay(delay, cancellation);
      }
    }
  }

  Future<_TranscriptionFailure> _post(Uint8List body, String boundary, Json auth,
    CancellationToken cancellation) async {
    HttpClientRequest? request;
    StreamIterator<List<int>>? input;
    final hook = CancellationHook(cancellation, () {
      request?.abort(cancellation.exception);
      unawaited(input?.cancel());
    });
    try {
      request = await http.postUrl(endpoint).then((value) {
        if (cancellation.isCancelled) value.abort(cancellation.exception);
        return value;
      }).asCancellable(cancellation);
      cancellation.throwIfCancelled();
      request.followRedirects = false;
      request.headers.set('Content-Type', 'multipart/form-data; boundary=$boundary');
      request.headers.set('Authorization', 'Bearer ${requiredString(auth, 'access_token')}');
      request.headers.set('ChatGPT-Account-Id', requiredString(auth, 'account_id'));
      request.headers.set('originator', 'agent');
      request.headers.set('User-Agent', 'agent/0.1.0 (Dart)');
      request.contentLength = body.length;
      request.add(body);
      final response = await request.close().asCancellable(cancellation);
      input = StreamIterator(response);
      final bytes = BytesBuilder(copy: false);
      while (await input.moveNext().asCancellable(cancellation)) {
        if (bytes.length + input.current.length > 1024 * 1024) {
          throw StateError('Unable to transcribe audio');
        }
        bytes.add(input.current);
      }
      cancellation.throwIfCancelled();
      Json decoded = {};
      try { decoded = jsonObject(jsonDecode(utf8.decode(bytes.takeBytes()))); }
      on FormatException { /* Never expose response bodies in errors. */ }
      return _TranscriptionFailure.response(response, decoded);
    } on SocketException {
      cancellation.throwIfCancelled();
      throw const _TranscriptionFailure.network();
    } on HandshakeException {
      cancellation.throwIfCancelled();
      throw const _TranscriptionFailure.network();
    } on HttpException {
      cancellation.throwIfCancelled();
      throw const _TranscriptionFailure.network();
    } finally {
      hook.dispose();
      await input?.cancel();
      request?.abort();
    }
  }
}

class _TranscriptionFailure implements Exception {
  const _TranscriptionFailure(this.status, this.body, this.canRetry, this.retryAt, this.workspaceRefusal, this.message);
  const _TranscriptionFailure.network() : this(0, const {}, null, null, false, 'Check your connection and try again');
  final int status;
  final Json body;
  final bool? canRetry;
  final double? retryAt;
  final bool workspaceRefusal;
  final String message;

  factory _TranscriptionFailure.response(HttpClientResponse response, Json body) {
    final detail = body['detail'] is Map ? jsonObject(body['detail']) : <String, dynamic>{};
    final error = body['error'] is Map ? jsonObject(body['error']) : <String, dynamic>{};
    final refusal = response.statusCode == 401 && (error['type'] == 'ip_not_authorized' ||
      const ['ip_not_authorized', 'validate_whitelist_failed', 'workspace_ip_not_authorized'].contains(error['code']));
    String? header(String name) => response.headers[name]?.join(', ');
    final retry = header('cf-mitigated') == 'challenge' ? null : detail['can_retry'] ?? body['can_retry'];
    final dates = <double>[];
    final retryAfter = header('retry-after');
    if (retryAfter != null) {
      final seconds = double.tryParse(retryAfter);
      if (seconds != null && seconds.isFinite) {
        dates.add(DateTime.now().millisecondsSinceEpoch + math.max(0, seconds) * 1000);
      } else {
        DateTime? date = DateTime.tryParse(retryAfter);
        try { date ??= HttpDate.parse(retryAfter); } catch (_) { /* Invalid date. */ }
        if (date != null) dates.add(date.millisecondsSinceEpoch.toDouble());
      }
    }
    final reset = double.tryParse(header('x-ratelimit-reset') ?? '');
    if (header('x-ratelimit-remaining') == '0' && reset != null && reset.isFinite && reset > 0) dates.add(reset * 1000);
    final message = refusal ? 'Your current IP address is not authorized for this workspace.'
      : detail['code'] == 'audio_too_short' || detail['message'] == 'Audio too short'
      ? "Didn't quite catch that. Please try again" : response.statusCode == 429
      ? 'Dictation is temporarily limited. Please try again later.' : 'Unable to transcribe audio';
    return _TranscriptionFailure(response.statusCode, body, retry is bool ? retry : null,
      dates.isEmpty ? null : dates.reduce(math.max), refusal, message);
  }

  Duration? retryDelay(int attempt) {
    if (attempt >= 2 || canRetry == false || !const [0, 408, 500, 502, 503, 504].contains(status)) return null;
    final milliseconds = math.max(500 * (1 << attempt), (retryAt ?? 0) - DateTime.now().millisecondsSinceEpoch);
    return milliseconds > 10000 ? null : Duration(milliseconds: milliseconds.toInt());
  }
}
