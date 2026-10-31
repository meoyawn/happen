import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ai/ai.dart' show ModelFailure, decodeSse, postWebSearch;
import 'package:protocol/protocol.dart';

import 'web_pages.dart';

typedef Credentials = Future<Json> Function({bool refresh});

class ResponsesReply {
  const ResponsesReply(this.output, this.usage);
  final List<Json> output;
  final Json usage;
  String get text => output
      .where((item) => item['type'] == 'message')
      .expand((item) => (item['content'] as List? ?? []).whereType<Map>())
      .where((part) => part['type'] == 'output_text')
      .map((part) => part['text'] as String? ?? '')
      .join('\n');
}

/// Transport only. The network owner supplies a shared HTTP connection pool.
class ResponsesClient {
  ResponsesClient({required this.credentials, Uri? endpoint, HttpClient? http})
    : endpoint =
          endpoint ??
          Uri.parse('https://chatgpt.com/backend-api/codex/responses'),
      _http = http ?? HttpClient(),
      _ownsHttp = http == null;
  final Credentials credentials;
  final Uri endpoint;
  final HttpClient _http;
  final bool _ownsHttp;

  Future<String> search({
    required String model,
    required String sessionId,
    required Json commands,
    required List<Json> input,
    required CancellationToken cancellation,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      cancellation.throwIfCancelled();
      final auth = await credentials(refresh: attempt != 0).asCancellable(cancellation);
      cancellation.throwIfCancelled();
      final response = await postWebSearch(_http, endpoint.resolve('alpha/search'), {
        'id': sessionId,
        'model': model,
        if (input.isNotEmpty) 'input': input,
        'commands': commands,
        'settings': {'external_web_access': true, 'allowed_callers': ['direct']},
        'max_output_tokens': 10000,
      }, cancellation: cancellation, headers: {
        HttpHeaders.authorizationHeader: 'Bearer ${requiredString(auth, 'access_token')}',
        'chatgpt-account-id': requiredString(auth, 'account_id'),
        'originator': 'agent',
        'session-id': sessionId,
        'x-client-request-id': newId(),
      });
      if (response.status == 401 && attempt == 0) continue;
      if (response.status != 200) {
        throw ModelFailure('web_search_http', 'OpenAI search failed (HTTP ${response.status})');
      }
      final output = response.body['output'];
      if (output is! String) {
        throw const ModelFailure('web_search_response', 'OpenAI search returned an invalid response');
      }
      return clippedText(await recoverWebPages(_http, commands, output, cancellation: cancellation));
    }
    throw const ModelFailure('web_search_auth', 'OpenAI search authentication failed');
  }

  Future<ResponsesReply> respond({
    required String model,
    required String instructions,
    required List<Json> input,
    required List<Json> tools,
    required String sessionId,
    required CancellationToken cancellation,
    String reasoning = 'xhigh',
    String toolChoice = 'auto',
    String transport = 'http',
    String verbosity = 'low',
    String reasoningSummary = 'none',
    int? maxOutputTokens,
    void Function(Json event)? onEvent,
  }) async {
    if (!{'http', 'websocket'}.contains(transport)) {
      throw ArgumentError('GPT transport must be http or websocket');
    }
    final body = <String, dynamic>{
      'model': model,
      'instructions': instructions,
      'input': input,
      'tools': tools,
      'tool_choice': toolChoice,
      'parallel_tool_calls': true,
      'store': false,
      if (transport == 'http') 'stream': true,
      'include': ['reasoning.encrypted_content'],
      'prompt_cache_key': sessionId,
      'reasoning': {
        'effort': reasoning,
        if (reasoningSummary != 'none') 'summary': reasoningSummary,
      },
      'text': {'verbosity': verbosity},
      'max_output_tokens': ?maxOutputTokens,
    };
    const maxRetries = 5;
    for (var retries = 0; ; retries++) {
      try {
        return await _respond(body, sessionId, transport, cancellation, onEvent);
      } on CancelledException {
        rethrow;
      } catch (error) {
        cancellation.throwIfCancelled();
        final retryable = switch (error) {
          SocketException() || HttpException() || WebSocketException() || TimeoutException() => true,
          ModelFailure(:final code) => {
            'stream_disconnected', 'stream_idle_timeout', 'retryable_provider_error',
          }.contains(code),
          _ => false,
        };
        if (!retryable || retries >= maxRetries) rethrow;
        onEvent?.call({'type': 'model.retrying', 'attempt': retries + 1, 'max_retries': maxRetries});
        final milliseconds = (200 * (1 << retries) * (.9 + Random().nextDouble() * .2)).round();
        await cancellableDelay(Duration(milliseconds: milliseconds), cancellation);
      }
    }
  }

  Future<ResponsesReply> _respond(
    Json body,
    String sessionId,
    String transport,
    CancellationToken cancellation,
    void Function(Json)? onEvent,
  ) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      cancellation.throwIfCancelled();
      final auth = await credentials(refresh: attempt != 0)
          .asCancellable(cancellation);
      cancellation.throwIfCancelled();
      final headers = <String, String>{
        HttpHeaders.authorizationHeader:
            'Bearer ${requiredString(auth, 'access_token')}',
        'chatgpt-account-id': requiredString(auth, 'account_id'),
        'originator': 'agent',
        HttpHeaders.userAgentHeader: 'agent/0.1.0 (Dart)',
        'OpenAI-Beta': transport == 'websocket'
            ? 'responses_websockets=2026-02-06'
            : 'responses=experimental',
        'session-id': sessionId,
        'x-client-request-id': newId(),
      };
      if (transport == 'websocket') {
        return _websocket(body, headers, cancellation, onEvent);
      }
      HttpClientRequest? request;
      Future<void> Function()? closeBody;
      final hook = CancellationHook(
        cancellation,
        () => request?.abort(cancellation.exception),
      );
      try {
        request = await _http
            .postUrl(endpoint)
            .then((value) {
              if (cancellation.isCancelled) value.abort(cancellation.exception);
              return value;
            })
            .asCancellable(cancellation);
        cancellation.throwIfCancelled();
        headers.forEach(request.headers.set);
        request.headers
          ..set(HttpHeaders.acceptHeader, 'text/event-stream')
          ..contentType = ContentType.json;
        request.write(jsonEncode(body));
        final response = await request.close().asCancellable(cancellation);
        if (response.statusCode != 200) {
          final detail = await _errorBody(response, cancellation);
          if (response.statusCode == 401 && attempt == 0) continue;
          throw _failure(detail, status: response.statusCode);
        }
        final incoming = ownStream(response, cancellation);
        closeBody = incoming.close;
        return await _consume(
          decodeSse(incoming.stream),
          cancellation,
          onEvent,
        );
      } catch (_) {
        cancellation.throwIfCancelled();
        rethrow;
      } finally {
        hook.dispose();
        request?.abort();
        await closeBody?.call();
      }
    }
    throw const ModelFailure(
      'authentication_failed',
      'GPT authentication failed after refresh',
    );
  }

  Future<ResponsesReply> _websocket(
    Json body,
    Map<String, String> headers,
    CancellationToken cancellation,
    void Function(Json)? onEvent,
  ) async {
    WebSocket? socket;
    var abandoned = false;
    final hook = CancellationHook(cancellation, () {
      if (socket != null) unawaited(socket.close());
    });
    try {
      final uri = endpoint.replace(
        scheme: endpoint.scheme == 'https' ? 'wss' : 'ws',
      );
      socket =
          await WebSocket.connect(
                uri.toString(),
                headers: headers,
                customClient: _http,
              )
              .then((value) {
                if (cancellation.isCancelled || abandoned) {
                  unawaited(value.close());
                }
                return value;
              })
              .timeout(const Duration(seconds: 15))
              .asCancellable(cancellation);
      cancellation.throwIfCancelled();
      socket.add(jsonEncode({'type': 'response.create', ...body}));
      final events = socket.map((raw) {
        final text = raw is String ? raw : utf8.decode(raw as List<int>);
        if (utf8.encode(text).length > 8 * 1024 * 1024) {
          throw const FormatException('GPT event too large');
        }
        return jsonObject(jsonDecode(text));
      });
      return await _consume(events, cancellation, onEvent);
    } catch (_) {
      cancellation.throwIfCancelled();
      rethrow;
    } finally {
      abandoned = true;
      hook.dispose();
      await socket?.close();
    }
  }

  Future<ResponsesReply> _consume(
    Stream<Json> events,
    CancellationToken cancellation,
    void Function(Json)? onEvent,
  ) async {
    final items = <int, Json>{};
    // Match the pinned Codex provider's event-idle limit, not a response or turn
    // wall-clock deadline. Parsed SSE events and WebSocket messages both reset it.
    final iterator = StreamIterator(events);
    try {
      while (await iterator.moveNext().timeout(
        const Duration(minutes: 5),
        onTimeout: () => throw const ModelFailure(
          'stream_idle_timeout', 'GPT stream was idle for 5 minutes',
        ),
      ).asCancellable(
        cancellation,
        onCancel: () => unawaited(iterator.cancel()),
      )) {
        cancellation.throwIfCancelled();
        final event = iterator.current;
        switch (event['type']) {
          case 'response.output_text.delta':
            onEvent?.call({'type': 'text.delta', 'delta': event['delta']});
          case 'response.reasoning_summary_text.delta':
            onEvent?.call({'type': 'reasoning.delta', 'delta': event['delta']});
          case 'response.output_item.done':
            items[(event['output_index'] as num).toInt()] = jsonObject(
              event['item'],
            );
          case 'response.failed':
          case 'error':
            throw _failure(event);
          case 'response.incomplete':
            throw const ModelFailure(
              'incomplete_response',
              'GPT response was incomplete',
            );
          case 'response.completed':
          case 'response.done':
            final response = jsonObject(event['response']);
            if (response['status'] != null &&
                response['status'] != 'completed') {
              throw _failure(response);
            }
            final indexes = items.keys.toList()..sort();
            final output = response['output'] is List
                ? (response['output'] as List).map(jsonObject).toList()
                : indexes.map((index) => items[index]!).toList();
            return ResponsesReply(output, jsonObject(response['usage'] ?? {}));
        }
      }
      throw const ModelFailure(
        'stream_disconnected',
        'GPT stream ended before completion',
      );
    } finally {
      // Let the transport's finally block abort/close the underlying connection.
      // Waiting for an async* SSE iterator here can wait on its blocked read.
      unawaited(iterator.cancel().catchError((Object _) {}));
    }
  }

  static ModelFailure _failure(Json detail, {int? status}) {
    final error = detail['error'] ?? detail['response']?['error'] ?? detail;
    final code = error is Map ? error['code'] ?? error['type'] : null;
    if ([
      'context_length_exceeded',
      'context_window_exceeded',
      'context_overflow',
    ].contains(code)) {
      return const ModelFailure(
        'context_overflow',
        'GPT context limit exceeded',
      );
    }
    if (status != null && (status == 408 || status >= 500 && status <= 599) ||
        {'server_error', 'internal_server_error'}.contains(code)) {
      return ModelFailure(
        'retryable_provider_error',
        'GPT request failed${status == null ? '' : ' (HTTP $status)'}',
      );
    }
    // Do not echo arbitrary response bodies into persisted task errors.
    return ModelFailure(
      'provider_error',
      'GPT request failed${status == null ? '' : ' (HTTP $status)'}',
    );
  }

  static Future<Json> _errorBody(
    HttpClientResponse response,
    CancellationToken cancellation,
  ) async {
    final iterator = StreamIterator(
      response.timeout(const Duration(seconds: 30)),
    );
    final bytes = <int>[];
    try {
      while (await iterator.moveNext().asCancellable(
        cancellation,
        onCancel: () => unawaited(iterator.cancel()),
      )) {
        bytes.addAll(iterator.current.take(16384 - bytes.length));
        if (bytes.length == 16384) return {};
      }
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      return decoded is Map ? jsonObject(decoded) : {};
    } on FormatException {
      return {};
    } finally {
      await iterator.cancel();
    }
  }

  void close() {
    if (_ownsHttp) _http.close(force: true);
  }
}
