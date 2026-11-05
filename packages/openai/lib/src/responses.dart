import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai/ai.dart' show ModelFailure, decodeSse, HttpReply, httpRequest;
import 'package:protocol/protocol.dart';
import 'package:telemetry/telemetry.dart';

import 'web_pages.dart';
import 'retry.dart';
import 'trace.dart';
import 'request.dart';
import 'catalog.dart';

typedef Credentials = Future<Json> Function({bool refresh});

class ResponsesReply {
  const ResponsesReply(this.output, this.usage, {this.endTurn = true, this.reasoningTimes = const {}, this.observedUsage});
  final List<Json> output;
  final Json usage;
  final bool endTurn;
  final Map<String, Json> reasoningTimes;
  final Json? observedUsage;
  String get text => output
      .where((item) => item['type'] == 'message')
      .expand((item) => (item['content'] as List? ?? []).whereType<Map<Object?, Object?>>())
      .where((part) => part['type'] == 'output_text')
      .map((part) => part['text'] as String? ?? '')
      .join('\n');
}

/// Transport only. The network owner supplies a shared Dart HTTP client.
class ResponsesClient {
  ResponsesClient({required this.credentials, Uri? endpoint, HttpClient? http})
    : endpoint =
          endpoint ??
          // Match Codex's endpoint for ChatGPT subscription OAuth.
          Uri.parse('https://chatgpt.com/backend-api/codex/responses'),
      _http = http ?? HttpClient(),
      _ownsHttp = http == null;
  final Credentials credentials;
  final Uri endpoint;
  final HttpClient _http;
  final bool _ownsHttp;
  Future<Directory?>? _requestDump;
  bool _httpFallback = false;

  Future<void> _dump(String Function() encoded, CancellationToken cancellation) async {
    if (Platform.environment['HAPPEN_ROLLOUT_TRACE_ROOT']?.isNotEmpty != true) return;
    final directory = await (_requestDump ??= startRequestDump(cancellation));
    if (directory != null) await dumpRequest(directory, encoded(), cancellation);
  }

  Future<Json> image(Json body, {required bool edit, required String turnId, required CancellationToken cancellation}) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      cancellation.throwIfCancelled();
      final auth = await credentials(refresh: attempt != 0).asCancellable(cancellation);
      cancellation.throwIfCancelled();
      final headers = <String, String>{
        if (auth['access_token'] case final String token when token.isNotEmpty) HttpHeaders.authorizationHeader: 'Bearer $token',
        if (auth['account_id'] case final String account when account.isNotEmpty) 'chatgpt-account-id': account,
        'originator': 'agent', 'x-codex-image-turn-id': turnId,
        HttpHeaders.acceptHeader: 'application/json',
      };
      final uri = endpoint.resolve(edit ? 'images/edits' : 'images/generations');
      HttpReply response;
      try { response = await retryRequest(() => _post(uri, body, headers, cancellation), cancellation); }
      on ResponseFailure catch (error) {
        if (error.status == 401 && attempt == 0) continue;
        throw ModelFailure('image_generation_http', 'OpenAI image ${edit ? 'edit' : 'generation'} failed (HTTP ${error.status})');
      }
      final incoming = ownStream(response, cancellation);
      final bytes = BytesBuilder(copy: false);
      try {
        await for (final chunk in incoming.stream) {
          cancellation.throwIfCancelled();
          if (bytes.length + chunk.length > 64 * 1024 * 1024) throw const ModelFailure('image_generation_size', 'Image response exceeds 64 MiB');
          bytes.add(chunk);
        }
        cancellation.throwIfCancelled();
        final value = jsonObject(jsonDecode(utf8.decode(bytes.takeBytes())));
        return {...value, if (response.headers['x-codex-imagegen-request-id'] case final String id) 'imagegen_request_id': id};
      } on FormatException {
        throw const ModelFailure('image_generation_response', 'OpenAI returned an invalid image response');
      } finally { await incoming.close(); }
    }
    throw const ModelFailure('image_generation_auth', 'OpenAI image authentication failed');
  }

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
      final deadline = TimeoutCancellationToken(const Duration(seconds: 30));
      try {
        final token = cancellation.merge(deadline);
        response = await retryRequest(() => _search(body, headers, token), token);
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
      } finally {
        deadline.cancel();
      }
      final output = response['output'];
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
    String reasoningSummary = 'auto',
    int? maxOutputTokens,
    void Function(Json event)? onEvent,
    Future<void> Function(Json item)? onRecovery,
  }) async {
    var activeTransport = transport == 'websocket' && _httpFallback ? 'http' : transport;
    var body = responsesRequest(model: model, instructions: instructions, input: input,
      tools: tools, sessionId: sessionId, reasoning: reasoning, toolChoice: toolChoice,
      transport: activeTransport, verbosity: verbosity, reasoningSummary: reasoningSummary,
      maxOutputTokens: maxOutputTokens);
    final sampling = !input.any((item) => item['type'] == 'compaction_trigger');
    final delivered = <Json>[];
    final retained = <Object>{for (final item in body['input'] as List) if (item['id'] != null) item['id'] as Object};
    void receive(Json event) {
      if (sampling && event['type'] == 'model.output' && event['item']['type'] == 'message') {
        delivered.add(jsonObject(event['item']));
      }
      onEvent?.call(event);
    }
    return traceAsync('openai.responses', () => retryResponseStream(
      () { delivered.clear(); return _respond(body, sessionId, activeTransport, cancellation, receive); }, cancellation,
      unboundedConnections: sampling,
      onContentFilter: !sampling ? null : () async {
        final item = <String, dynamic>{'id': 'msg_${newUuidV7()}', 'type': 'message', 'role': 'developer',
          'content': [{'type': 'input_text', 'text': '<content_filter_guidance>\n${GptModel(model).contentFilterGuidance}\n</content_filter_guidance>'}]};
        // Only delivered messages are retained. Failed streams cannot admit or
        // execute deferred tool calls. The host durably admits this context on
        // the same ordered event channel before another request can be sent.
        if (onRecovery != null) await onRecovery(item);
        else onEvent?.call({'type': 'model.recovery', 'item': item});
        cancellation.throwIfCancelled();
        body = {...body, 'input': [...body['input'] as List,
          for (final output in delivered) if (retained.add(output['id'] as Object? ?? output)) output,
          item]};
      },
      fallbackTransport: () {
        if (activeTransport != 'websocket') return false;
        activeTransport = 'http';
        _httpFallback = true;
        body = {...body, 'stream': true}..remove('type');
        return true;
      }, onEvent: onEvent), category: 'model',
      attributes: {'gen_ai.request.model': model, 'network.transport': activeTransport});
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
      Future<void> Function()? closeBody;
      try {
        if (transport == 'websocket') {
          return await _websocket(body, headers, cancellation, onEvent);
        }
        final response = await retryRequest(() => _post(endpoint, body,
          {...headers, HttpHeaders.acceptHeader: 'text/event-stream'}, cancellation,
          headersTimeout: const Duration(seconds: 60)), cancellation, onEvent: onEvent);
        final incoming = ownStream(response, cancellation);
        closeBody = incoming.close;
        return await _consume(
          decodeSse(incoming.stream.timeout(const Duration(seconds: 60))),
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
    CancellationToken cancellation, {Duration? headersTimeout}) async {
    final encoded = JsonUtf8Encoder().convert(body);
    if (uri == endpoint) await _dump(() => utf8.decode(encoded), cancellation);
    cancellation.throwIfCancelled();
    final response = await httpRequest(_http, 'POST', uri,
      cancellation: cancellation,
      headers: {...headers, HttpHeaders.contentTypeHeader: 'application/json'},
      body: encoded, headersTimeout: headersTimeout);
    if (response.statusCode == 200) return response;
    // Capture advice when headers arrive; reading the body must not reset it.
    final advice = retryAdvice(response.headers[HttpHeaders.retryAfterHeader]);
    final detail = await _errorBody(response, cancellation);
    throw _failure(detail, status: response.statusCode, advice: advice);
  }

  Future<Json> _search(Json body, Map<String, String> headers, CancellationToken cancellation) async {
    Future<void> Function()? closeBody;
    try {
      final response = await _post(endpoint.resolve('alpha/search'), body,
        {...headers, HttpHeaders.acceptHeader: 'application/json'}, cancellation,
        headersTimeout: const Duration(seconds: 10));
      final incoming = ownStream(response, cancellation);
      closeBody = incoming.close;
      final bytes = <int>[];
      final chunks = StreamIterator(incoming.stream);
      try {
        while (await chunks.moveNext().asCancellable(cancellation)) {
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
      if (error is FormatException) {
        throw const ModelFailure('web_search_response', 'OpenAI search returned an invalid response');
      }
      rethrow;
    } finally {
      await closeBody?.call();
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
          await traceAsync('openai.websocket.connect', () => WebSocket.connect(
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
              .timeout(const Duration(seconds: 10))
              .asCancellable(cancellation), category: 'websocket',
              attributes: {'server.address': uri.host, 'url.path': uri.path});
      cancellation.throwIfCancelled();
      final encoded = jsonEncode(body);
      await _dump(() => encoded, cancellation);
      cancellation.throwIfCancelled();
      traceSync('openai.websocket.send', () => socket!.add(encoded), category: 'websocket',
        attributes: {'bytes': utf8.encode(encoded).length});
      final events = socket!.timeout(const Duration(seconds: 60)).map((raw) {
        final text = raw is String ? raw : utf8.decode(raw as List<int>);
        traceInstant('openai.websocket.receive', category: 'websocket',
          attributes: {'bytes': utf8.encode(text).length});
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
    final reasoningStarts = <String, int>{};
    final reasoningParts = <String, String>{};
    final reasoningTimes = <String, Json>{};
    void reasoningPart(Json event, String channel, {bool completed = false}) {
      final id = event['item_id'];
      if (id is! String) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      final start = reasoningStarts.putIfAbsent(id, () => now);
      final prefix = '$id:$channel';
      final key = '$prefix:${event[channel == 'summary' ? 'summary_index' : 'content_index'] ?? 0}';
      final time = reasoningTimes.putIfAbsent(key, () {
        final previous = reasoningTimes[reasoningParts[prefix]];
        if (previous != null) previous['completed'] ??= now;
        reasoningParts[prefix] = key;
        // Summaries arrive after the thinking they describe. Include the gap
        // since the preceding summary, rather than just its text transmission.
        return {'created': previous?['completed'] ?? start};
      });
      if (completed) time['completed'] ??= now;
    }
    void finishReasoning(Json item) {
      final id = item['id'];
      final start = reasoningStarts.remove(id);
      if (start == null) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final channel in ['summary', 'content']) {
        final parts = item[channel] as List? ?? [];
        for (var index = 0; index < parts.length; index++) {
          final key = '$id:$channel:$index';
          final time = reasoningTimes[key] ?? (parts.length == 1
            ? reasoningTimes[key] = {'created': start} : null);
          if (time == null) continue;
          if (index == parts.length - 1) {
            time['completed'] = now;
          } else {
            time['completed'] ??= now;
          }
        }
      }
    }
    ResponsesReply completed(Json response, {bool interrupted = false}) {
      final indexes = items.keys.toList()..sort();
      // Streamed completions are authoritative even when the terminal packet
      // contains only usage/end-turn metadata and an empty output summary.
      final output = items.isNotEmpty ? indexes.map((index) => items[index]!).toList()
        : (response['output'] as List? ?? []).map(jsonObject).toList();
      for (final item in output) {
        if (item['type'] == 'reasoning') finishReasoning(item);
      }
      final reported = _reportedUsage(response['usage']);
      return ResponsesReply(output, jsonObject(response['usage'] ?? {}),
        endTurn: !interrupted && response['end_turn'] != false, reasoningTimes: reasoningTimes,
        observedUsage: reported != null && response['id'] is String ? {'response_id': response['id'], 'usage': reported} : null);
    }
    // Transport activity resets the idle deadline, including SSE heartbeats
    // during long reasoning. A healthy response has no wall-clock limit.
    final iterator = StreamIterator(events);
    try {
      while (await iterator.moveNext().asCancellable(
        cancellation,
        onCancel: () => unawaited(iterator.cancel()),
      )) {
        cancellation.throwIfCancelled();
        final event = iterator.current;
        traceInstant('openai.event', category: 'model', attributes: {'event.type': event['type']});
        switch (event['type']) {
          case 'response.created':
            onEvent?.call({'type': 'model.connected'});
          case 'response.output_item.added':
            final item = jsonObject(event['item']);
            if (item['type'] == 'reasoning' && item['id'] is String) {
              reasoningStarts[item['id'] as String] = DateTime.now().millisecondsSinceEpoch;
            }
          case 'response.output_text.delta':
            onEvent?.call({'type': 'text.delta', 'delta': event['delta']});
          case 'response.reasoning_summary_text.delta':
            reasoningPart(event, 'summary');
            onEvent?.call({'type': 'reasoning.delta', 'delta': event['delta']});
          case 'response.reasoning_text.delta':
            reasoningPart(event, 'content');
            onEvent?.call({'type': 'reasoning.delta', 'delta': event['delta']});
          case 'response.reasoning_summary_part.added':
            reasoningPart(event, 'summary');
            if ((event['summary_index'] as int? ?? 0) > 0) {
              onEvent?.call({'type': 'reasoning.delta', 'delta': '\n\n'});
            }
          case 'response.reasoning_summary_part.done':
          case 'response.reasoning_summary_text.done':
            reasoningPart(event, 'summary', completed: true);
          case 'response.content_part.added':
            if (event['part']?['type'] == 'reasoning_text') reasoningPart(event, 'content');
          case 'response.content_part.done':
            if (event['part']?['type'] == 'reasoning_text') reasoningPart(event, 'content', completed: true);
          case 'response.reasoning_text.done':
            reasoningPart(event, 'content', completed: true);
          case 'response.output_item.done':
            final item = jsonObject(event['item']);
            if (item['type'] == 'reasoning') finishReasoning(item);
            items[(event['output_index'] as num?)?.toInt() ?? items.length] = item;
            onEvent?.call({'type': 'model.output', 'item': item, 'reasoning_times': reasoningTimes});
          case 'response.failed':
          case 'error':
            throw _failure(event, status: (event['status'] ?? event['status_code']) as int?);
          case 'response.incomplete':
            // Codex codex-api/src/sse/responses.rs: an output-limit failure is
            // terminal but can still report real spending. It is not a completed
            // response and must not replace the loop's context-usage baseline.
            final response = jsonObject(event['response'] ?? {});
            final details = response['incomplete_details'];
            final value = details is Map ? details['reason'] : null;
            final reason = value is String ? value : 'unknown';
            if (reason == 'interrupted') return completed(response, interrupted: true);
            if (reason == 'content_filter') {
              throw const ResponseFailure('content_filter', 'Response blocked by content filter', retryable: true);
            }
            final usage = _reportedUsage(response['usage']);
            if (usage != null) {
              onEvent?.call({'type': 'model.incomplete', 'response_id': response['id'], 'usage': usage});
            }
            throw ModelFailure('incomplete_response', 'Incomplete response returned, reason: $reason');
          case 'response.completed':
          case 'response.done':
            final response = jsonObject(event['response']);
            if (response['status'] != null &&
                response['status'] != 'completed') {
              throw _failure(response);
            }
            return completed(response);
        }
      }
      throw const ModelFailure(
        'stream_disconnected',
        'GPT stream ended before completion',
      );
    } catch (error) {
      cancellation.throwIfCancelled();
      if (error is TimeoutException) {
        throw const ModelFailure('stream_idle_timeout', 'GPT stream was idle for 60 seconds');
      }
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
    final providerMessage = error is Map ? error['message'] : null;
    final message = providerMessage is String && providerMessage.trim().isNotEmpty
      ? clippedText(providerMessage.trim(), 4096) : null;
    if ([
      'context_length_exceeded',
      'context_window_exceeded',
      'context_overflow',
    ].contains(code)) {
      return ResponseFailure(
        'context_overflow',
        message ?? 'GPT context limit exceeded',
      );
    }
    for (final headers in [if (error is Map) error['headers'], detail['headers']]) {
      if (advice != null || headers is! Map) continue;
      for (final entry in headers.entries) {
        if (entry.key.toString().toLowerCase() == HttpHeaders.retryAfterHeader) {
          final value = entry.value;
          advice = retryAdvice(value is num || value is bool ? value.toString() : value);
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
    if (status == null && advice == null && {'rate_limit_exceeded', 'slow_down'}.contains(code) && error is Map) {
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
      {'websocket_connection_limit_reached', 'previous_response_not_found'}.contains(code) ||
        status == null || status == 408 || status >= 500 && status <= 599);
    // Retain structured diagnostics without falling back to raw response bodies.
    return ResponseFailure(
      code is String && code.isNotEmpty ? clippedText(code, 256)
        : retryable ? 'retryable_provider_error' : 'provider_error',
      message ?? 'GPT request failed${status == null ? '' : ' (HTTP $status)'}',
      status: status, retryAfter: advice, retryable: retryable,
    );
  }

  // ResponseCompletedUsage's required i64 counters and optional typed details.
  // Missing/malformed usage is absent, never an estimate or a zero receipt.
  static Json? _reportedUsage(Object? value) {
    if (value is! Map || ['input_tokens', 'output_tokens', 'total_tokens'].any((key) => value[key] is! int)) return null;
    final input = value['input_tokens_details'], output = value['output_tokens_details'];
    if (input != null && (input is! Map || input['cached_tokens'] is! int ||
        input['cache_write_tokens'] != null && input['cache_write_tokens'] is! int)) return null;
    if (output != null && (output is! Map || output['reasoning_tokens'] is! int)) return null;
    return {'input_tokens': value['input_tokens'], 'output_tokens': value['output_tokens'], 'total_tokens': value['total_tokens'],
      'cached_input_tokens': input == null ? 0 : input['cached_tokens'],
      'cache_write_input_tokens': input == null ? 0 : input['cache_write_tokens'] ?? 0,
      'reasoning_output_tokens': output == null ? 0 : output['reasoning_tokens']};
  }

  static Future<Json> _errorBody(
    Stream<List<int>> response,
    CancellationToken cancellation,
  ) async {
    final deadline = TimeoutCancellationToken(const Duration(seconds: 2));
    final token = cancellation.merge(deadline);
    final incoming = ownStream(response, token);
    final iterator = StreamIterator(incoming.stream);
    final bytes = <int>[];
    try {
      while (await iterator.moveNext().asCancellable(
        token,
        onCancel: () => unawaited(iterator.cancel()),
      )) {
        bytes.addAll(iterator.current.take(16384 - bytes.length));
        if (bytes.length == 16384) return {};
      }
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      return decoded is Map ? jsonObject(decoded) : {};
    } catch (error) {
      cancellation.throwIfCancelled();
      if (error is FormatException || transportFailure(error)) return {};
      rethrow;
    } finally {
      unawaited(iterator.cancel().catchError((Object _) {}));
      await incoming.close();
      deadline.cancel();
    }
  }

  void close() {
    if (_ownsHttp) _http.close(force: true);
  }
}
