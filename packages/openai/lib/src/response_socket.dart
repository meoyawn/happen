part of 'responses.dart';

sealed class _SocketState { const _SocketState(); }
class _SocketIdle extends _SocketState { const _SocketIdle(); }
class _SocketConnecting extends _SocketState {
  const _SocketConnecting(this.cancellation);
  final CancellationToken cancellation;
}
class _SocketStreaming extends _SocketState {
  const _SocketStreaming(this.connection, this.cancellation);
  final _SocketConnection connection;
  final CancellationToken cancellation;
}
class _SocketReady extends _SocketState {
  const _SocketReady(this.connection, this.continuation);
  final _SocketConnection connection;
  final Json? continuation;
}
class _SocketClosed extends _SocketState { const _SocketClosed(); }

bool _validSocketTransition(_SocketState current, _SocketState next) => switch ((current, next)) {
  (_SocketIdle(), _SocketConnecting() || _SocketClosed()) => true,
  (_SocketConnecting(), _SocketStreaming() || _SocketIdle() || _SocketClosed()) => true,
  (_SocketStreaming(), _SocketReady() || _SocketIdle() || _SocketClosed()) => true,
  (_SocketReady(), _SocketStreaming() || _SocketIdle() || _SocketClosed()) => true,
  _ => false,
};

class _SocketConnection {
  _SocketConnection(this.socket, this.credentials)
    : events = StreamIterator(socket.map((raw) {
        final text = raw is String ? raw : utf8.decode(raw as List<int>);
        final bytes = utf8.encode(text).length;
        traceInstant('openai.websocket.receive', category: 'websocket', attributes: {'bytes': bytes});
        if (bytes > 8 * 1024 * 1024) throw const FormatException('GPT event too large');
        return jsonObject(jsonDecode(text));
      }));
  final WebSocket socket;
  final StreamIterator<Json> events;
  final (String?, String?) credentials;
  final age = Stopwatch()..start();

  void close() {
    unawaited(socket.close().catchError((Object _) {})
      .whenComplete(() => events.cancel().catchError((Object _) {})));
  }
}

Json _replayedOutput(Json item) {
  // The provider preserves native output while adding its durable message
  // metadata. Direct transport callers may instead replay the original item.
  try { return gptInput([gptItemFromNative(item)]).single; }
  catch (_) { return item; }
}

Object? _orderedJson(Object? value) {
  if (value is Map<String, dynamic>) {
    final keys = value.keys.toList()..sort();
    return {for (final key in keys) key: _orderedJson(value[key])};
  }
  if (value is List) return [for (final item in value) _orderedJson(item)];
  return value;
}

String _inputHash(List<Object?> input) => sha256.convert(utf8.encode(jsonEncode(_orderedJson(input)))).toString();

// Connection-local identity and digests only. The full history stays with the
// agent. Edits, forks and compaction cannot silently drop context.
Json? _responseCursor(Json body, ResponsesReply reply) => reply.responseId == null ? null : {
    'response_id': reply.responseId, 'model': body['model'],
    'input_count': (body['input'] as List).length + reply.output.length,
    'input_hash': _inputHash([...body['input'] as List, ...reply.output.map(_replayedOutput)]),
    'wire_input_hash': _inputHash([...body['input'] as List, ...reply.output]),
  };

Json _continuedRequest(Json body, Json? cursor) {
  if (cursor == null || cursor['model'] != body['model'] || cursor['response_id'] is! String) return body;
  final input = body['input'] as List;
  final count = cursor['input_count'];
  if (count is! int || count < 0 || count > input.length) return body;
  final hash = _inputHash(input.sublist(0, count));
  if (hash != cursor['input_hash'] && hash != cursor['wire_input_hash']) return body;
  return {...body, 'previous_response_id': cursor['response_id'], 'input': input.sublist(count)};
}

class _ResponsesSocket {
  _SocketState _state = const _SocketIdle();

  void _transition(_SocketState next) {
    if (!_validSocketTransition(_state, next)) throw StateError('Invalid Responses socket transition');
    _state = next;
  }

  void _cancel(CancellationToken operation) {
    final current = _state;
    switch (current) {
      case _SocketConnecting(:final cancellation) when identical(cancellation, operation):
        _transition(const _SocketIdle());
      case _SocketStreaming(:final connection, :final cancellation) when identical(cancellation, operation):
        _transition(const _SocketIdle());
        connection.close();
      default: break;
    }
  }

  Future<ResponsesReply> respond(ResponsesClient client, Json body, Map<String, String> headers,
    CancellationToken cancellation, void Function(Json)? onEvent) async {
    cancellation.throwIfCancelled();
    var current = _state;
    if (current is _SocketClosed) throw CancelledException();
    if (current is _SocketConnecting || current is _SocketStreaming) {
      throw StateError('A Responses session already has an active request');
    }
    final credentials = (headers[HttpHeaders.authorizationHeader], headers['chatgpt-account-id']);
    if (current is _SocketReady && (current.connection.credentials != credentials ||
        current.connection.socket.readyState != WebSocket.open || current.connection.age.elapsed >= const Duration(hours: 1))) {
      _transition(const _SocketIdle());
      current.connection.close();
      current = _state;
    }
    final operation = CancellationToken();
    final token = cancellation.merge(operation);
    _SocketConnection? connection;
    final continuation = current is _SocketReady ? current.continuation : null;
    if (current is _SocketReady) {
      connection = current.connection;
      _transition(_SocketStreaming(connection, operation));
    } else {
      _transition(_SocketConnecting(operation));
    }
    final hook = CancellationHook(token, () => _cancel(operation));
    try {
      if (connection == null) {
        final connecting = _state;
        final uri = client.endpoint.replace(scheme: client.endpoint.scheme == 'https' ? 'wss' : 'ws');
        final socket = await traceAsync('openai.websocket.connect', () => WebSocket.connect(uri.toString(),
          headers: headers, customClient: client._http).then((socket) {
            if (token.isCancelled || !identical(_state, connecting)) unawaited(socket.close().catchError((Object _) {}));
            return socket;
          }).timeout(const Duration(seconds: 15)).asCancellable(token), category: 'websocket',
          attributes: {'server.address': uri.host, 'url.path': uri.path});
        token.throwIfCancelled();
        connection = _SocketConnection(socket, credentials);
        _transition(_SocketStreaming(connection, operation));
      }
      final encoded = jsonEncode(_continuedRequest(body, continuation));
      await client._dump(() => encoded, token);
      token.throwIfCancelled();
      traceSync('openai.websocket.send', () => connection!.socket.add(encoded), category: 'websocket',
        attributes: {'bytes': utf8.encode(encoded).length});
      final reply = await client._consume(connection.events, token, onEvent,
        cancelIterator: false, idleTimeout: _streamIdleTimeout);
      token.throwIfCancelled();
      _transition(_SocketReady(connection, _responseCursor(body, reply)));
      return reply;
    } catch (_) {
      _cancel(operation);
      token.throwIfCancelled();
      rethrow;
    } finally {
      hook.dispose();
      operation.cancel();
    }
  }

  void close() {
    final current = _state;
    if (current is _SocketClosed) return;
    _transition(const _SocketClosed());
    switch (current) {
      case _SocketConnecting(:final cancellation): cancellation.cancel();
      case _SocketStreaming(:final connection, :final cancellation):
        cancellation.cancel(); connection.close();
      case _SocketReady(:final connection): connection.close();
      default: break;
    }
  }
}
