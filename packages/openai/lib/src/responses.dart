import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai/ai.dart' show ModelFailure, decodeSse, HttpConnections, HttpReply, httpRequest;
import 'package:protocol/protocol.dart';

import 'web_pages.dart';
import 'retry.dart';
import 'trace.dart';
import 'records.dart' show withGptInstructions;

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
  ResponsesClient({required this.credentials, Uri? endpoint, HttpClient? http, this.connections})
    : endpoint =
          endpoint ??
          // Match Codex's endpoint for ChatGPT subscription OAuth.
          Uri.parse('https://chatgpt.com/backend-api/codex/responses'),
      _http = http ?? HttpClient(),
      _ownsHttp = http == null;
  final Credentials credentials;
  final Uri endpoint;
  final HttpClient _http;
  final HttpConnections? connections;
  final bool _ownsHttp;
  final _traces = <String, Future<Directory?>>{};

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
      final body = <String, dynamic>{
        'id': sessionId,
        'model': model,
        if (input.isNotEmpty) 'input': input,
        'commands': commands,
        'settings': {'external_web_access': true, 'allowed_callers': ['direct']},
        'max_output_tokens': 10000,
      };
      final headers = <String, String>{
        if (auth['access_token'] case final String token when token.isNotEmpty)
          HttpHeaders.authorizationHeader: 'Bearer $token',
        if (auth['account_id'] case final String account when account.isNotEmpty) 'chatgpt-account-id': account,
        'originator': 'agent',
        'session-id': sessionId,
        'x-client-request-id': newId(),
      };
      Json response;
      try {
        response = await retryRequest(() => _search(body, headers, cancellation), cancellation);
      } on ResponseFailure catch (error) {
        if (error.status == 401 && attempt == 0) continue;
        throw ModelFailure('web_search_http', 'OpenAI search failed (HTTP ${error.status})');
      } catch (error) {
        cancellation.throwIfCancelled();
        if (error is TimeoutException) {
          throw const ModelFailure('web_search_timeout', 'OpenAI search timed out');
        }
        if (transportFailure(error)) {
          throw const ModelFailure('web_search_transport', 'OpenAI search request failed');
        }
        rethrow;
      }
      final output = response['output'];
      if (output is! String) {
        throw const ModelFailure('web_search_response', 'OpenAI search returned an invalid response');
      }
      return clippedText(await recoverWebPages(_http, commands, output, cancellation: cancellation, connections: connections));
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
      'input': withGptInstructions(instructions, input),
      if (tools.isNotEmpty) 'tools': tools,
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
    var retries = 0, connectionRetries = 0;
    final tracing = Platform.environment['HAPPEN_ROLLOUT_TRACE_ROOT']?.isNotEmpty == true;
    final trace = tracing ? await (_traces[sessionId] ??= startModelTrace(sessionId, cancellation)) : null;
    final traceID = newId();
    await recordModelTrace(trace, traceID, 'request', body, cancellation);
    var connectionDelay = const Duration(seconds: 5);
    final sampling = input.isEmpty || input.last['type'] != 'compaction_trigger';
    while (true) {
      try {
        final response = await _respond(body, sessionId, transport, cancellation, onEvent);
        await recordModelTrace(trace, traceID, 'response', {'output': response.output, 'usage': response.usage}, cancellation);
        return response;
      } on CancelledException {
        rethrow;
      } catch (error) {
        cancellation.throwIfCancelled();
        // Failed connection establishment does not consume the stream budget.
        // Compaction remains bounded, matching Codex's sampling-only policy.
        if (sampling && (error is SocketException || error is HandshakeException)) {
          onEvent?.call({'type': 'model.retrying', 'attempt': ++connectionRetries,
            'reason': 'connection_failed', 'delay_ms': connectionDelay.inMilliseconds,
            'message': 'Reconnecting… waiting for network'});
          await cancellableDelay(connectionDelay, cancellation);
          connectionDelay = Duration(seconds: (connectionDelay.inSeconds * 2).clamp(5, 60));
          continue;
        }
        final retryable = transportFailure(error) || switch (error) {
          ResponseFailure(:final retryStream) => retryStream,
          ModelFailure(:final code) => {'stream_disconnected', 'stream_idle_timeout'}.contains(code),
          _ => false,
        };
        if (!retryable || retries >= streamMaxRetries) rethrow;
        final advice = error is ResponseFailure ? error.retryAfter : null;
        final delay = retryBackoff(retries++);
        onEvent?.call({'type': 'model.retrying', 'attempt': retries, 'max_retries': streamMaxRetries,
          'delay_ms': (advice == null ? delay : remainingDelay(advice)).inMilliseconds,
          'message': 'Reconnecting… $retries/$streamMaxRetries'});
        await cancellableDelay(advice == null ? delay : remainingDelay(advice), cancellation);
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
        if (auth['access_token'] case final String token when token.isNotEmpty)
          HttpHeaders.authorizationHeader: 'Bearer $token',
        if (auth['account_id'] case final String account when account.isNotEmpty) 'chatgpt-account-id': account,
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
      Future<void> Function()? closeBody;
      try {
        final response = await retryRequest(() => _post(endpoint, body,
          {...headers, HttpHeaders.acceptHeader: 'text/event-stream'}, cancellation), cancellation);
        final incoming = ownStream(response, cancellation);
        closeBody = incoming.close;
        return await _consume(
          decodeSse(incoming.stream),
          cancellation,
          onEvent,
        );
      } on ResponseFailure catch (error) {
        if (error.status == 401 && attempt == 0) continue;
        rethrow;
      } catch (_) {
        cancellation.throwIfCancelled();
        rethrow;
      } finally {
        await closeBody?.call();
      }
    }
    throw const ModelFailure(
      'authentication_failed',
      'GPT authentication failed after refresh',
    );
  }

  Future<HttpReply> _post(Uri uri, Json body, Map<String, String> headers,
    CancellationToken cancellation) async {
    final response = await httpRequest(_http, 'POST', uri,
      connections: connections, cancellation: cancellation,
      headers: {...headers, HttpHeaders.contentTypeHeader: 'application/json'},
      body: utf8.encode(jsonEncode(body)));
    if (response.statusCode == 200) return response;
    // Capture advice when headers arrive; reading the body must not reset it.
    final advice = retryAdvice(response.headers[HttpHeaders.retryAfterHeader]);
    final detail = await _errorBody(response, cancellation);
    throw _failure(detail, status: response.statusCode, advice: advice);
  }

  Future<Json> _search(Json body, Map<String, String> headers, CancellationToken cancellation) async {
    final deadline = TimeoutCancellationToken(const Duration(seconds: 60));
    final token = cancellation.merge(deadline);
    Future<void> Function()? closeBody;
    try {
      final response = await _post(endpoint.resolve('alpha/search'), body,
        {...headers, HttpHeaders.acceptHeader: 'application/json'}, token);
      final incoming = ownStream(response, token);
      closeBody = incoming.close;
      final bytes = <int>[];
      final chunks = StreamIterator(incoming.stream);
      try {
        while (await chunks.moveNext().asCancellable(token)) {
          if (bytes.length + chunks.current.length > 2 * 1024 * 1024) {
            throw const ModelFailure('web_search_size', 'Web response exceeded 2 MiB');
          }
          bytes.addAll(chunks.current);
        }
      } finally {
        unawaited(chunks.cancel().catchError((Object _) {}));
      }
      return jsonObject(jsonDecode(utf8.decode(bytes, allowMalformed: true)));
    } catch (error) {
      cancellation.throwIfCancelled();
      if (deadline.isCancelled) throw TimeoutException('OpenAI search timed out');
      if (error is FormatException) {
        throw const ModelFailure('web_search_response', 'OpenAI search returned an invalid response');
      }
      rethrow;
    } finally {
      await closeBody?.call();
      deadline.cancel();
    }
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
          case 'response.created':
            onEvent?.call({'type': 'model.connected'});
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
            throw _failure(event, status: (event['status'] ?? event['status_code']) as int?);
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
    } catch (error) {
      cancellation.throwIfCancelled();
      // A socket failure after headers is an interrupted stream, not an offline
      // connection. It consumes the normal bounded stream retry budget.
      if (transportFailure(error)) {
        throw const ModelFailure('stream_disconnected', 'GPT stream disconnected before completion');
      }
      rethrow;
    } finally {
      // Let the transport's finally block abort/close the underlying connection.
      // Waiting for an async* SSE iterator here can wait on its blocked read.
      unawaited(iterator.cancel().catchError((Object _) {}));
    }
  }

  static ResponseFailure _failure(Json detail, {int? status, RetryAdvice? advice}) {
    final error = detail['error'] ?? detail['response']?['error'] ?? detail;
    final code = error is Map ? error['code'] ?? error['type'] : null;
    if ([
      'context_length_exceeded',
      'context_window_exceeded',
      'context_overflow',
    ].contains(code)) {
      return const ResponseFailure(
        'context_overflow',
        'GPT context limit exceeded',
      );
    }
    for (final headers in [if (error is Map) error['headers'], detail['headers']]) {
      if (advice != null || headers is! Map) continue;
      for (final entry in headers.entries) {
        if (entry.key.toString().toLowerCase() == HttpHeaders.retryAfterHeader) {
          advice = retryAdvice(entry.value);
        }
      }
    }
    final terminal = {
      'insufficient_quota', 'credit_balance_exhausted', 'organization_spend_limit_exceeded',
      'project_spend_limit_exceeded', 'organization_usage_limit_exceeded', 'usage_not_included',
      'usage_limit_reached', 'invalid_prompt', 'model_not_found', 'flex_unavailable',
      'cyber_policy', 'bio_policy', 'misalignment_policy_violation',
      'audio_too_large', 'audio_too_short', 'invalid_audio', 'invalid_audio_data',
      'invalid_audio_format', 'missing_audio_sample_rate',
    }.contains(code);
    if (advice == null && {'rate_limit_exceeded', 'slow_down'}.contains(code) && error is Map) {
      final match = RegExp(r'try again in\s*(\d+(?:\.\d+)?)\s*(s|ms|seconds?)', caseSensitive: false)
          .firstMatch(error['message'] is String ? error['message'] as String : '');
      if (match != null) {
        final value = double.tryParse(match[1]!);
        if (value != null && value.isFinite && value <= 9223372036) {
          advice = (delay: Duration(microseconds: (value * (match[2]!.toLowerCase() == 'ms' ? 1000 : 1000000)).floor()),
            elapsed: Stopwatch()..start());
        }
      }
    }
    final needsAdvice = status == 429 || {'server_is_overloaded', 'policy_capacity_unavailable'}.contains(code);
    final retryable = !terminal && (needsAdvice ? advice != null :
      status == null || status == 408 || status >= 500 && status <= 599);
    if (retryable) {
      return ResponseFailure(
        'retryable_provider_error',
        'GPT request failed${status == null ? '' : ' (HTTP $status)'}',
        status: status, retryAfter: advice, retryStream: true,
      );
    }
    // Do not echo arbitrary response bodies into persisted task errors.
    return ResponseFailure(
      'provider_error',
      'GPT request failed${status == null ? '' : ' (HTTP $status)'}',
      status: status, retryAfter: advice,
    );
  }

  static Future<Json> _errorBody(
    Stream<List<int>> response,
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
