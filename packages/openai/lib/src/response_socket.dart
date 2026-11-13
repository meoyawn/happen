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
  final _ResponseContinuation? continuation;
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
    unawaited(socket.close().catchError((Object _) {}));
    unawaited(events.cancel().catchError((Object _) {}));
  }
}

// Only a successful terminal event establishes a continuation. The next full
// request remains authoritative: edits, compaction and model changes replay it.
class _ResponseContinuation {
  _ResponseContinuation(Json body, ResponsesReply reply)
    : responseId = reply.responseId!, model = body['model'] as String,
      input = (body['input'] as List).map(jsonObject).toList(), output = reply.output,
      replay = [for (final item in reply.output) _replayedOutput(item)];
  final String responseId, model;
  final List<Json> input, output;
  final List<Json?> replay;

  Json request(Json body) {
    final next = body['input'] as List;
    final length = input.length + output.length;
    if (body['model'] != model || next.length < length) return body;
    for (var index = 0; index < input.length; index++) {
      if (!_sameJson(input[index], next[index])) return body;
    }
    for (var index = 0; index < output.length; index++) {
      if (!_sameJson(output[index], next[input.length + index]) &&
          !_sameJson(replay[index], next[input.length + index])) return body;
    }
    return {...body, 'previous_response_id': responseId, 'input': next.sublist(length)};
  }
}

Json? _replayedOutput(Json item) {
  // The provider preserves native output while adding its durable message
  // metadata. Direct transport callers may instead replay the original item.
  try { return gptInput([gptItemFromNative(item)]).single; }
  catch (_) { return null; }
}

bool _sameJson(Object? left, Object? right) {
  if (identical(left, right)) return true;
  if (left is Map && right is Map) {
    return left.length == right.length && left.keys.every((key) => right.containsKey(key) && _sameJson(left[key], right[key]));
  }
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!_sameJson(left[index], right[index])) return false;
    }
    return true;
  }
  return left == right;
}

class _ResponsesSocket {
  _SocketState _state = const _SocketIdle();
  Timer? _expiry;

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
    CancellationToken cancellation, void Function(Json)? onEvent, {required void Function() onIdle}) async {
    cancellation.throwIfCancelled();
    var current = _state;
    if (current is _SocketClosed) throw CancelledException();
    if (current is _SocketConnecting || current is _SocketStreaming) {
      throw StateError('A Responses session already has an active request');
    }
    _expiry?.cancel();
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
          }).timeout(const Duration(seconds: 10)).asCancellable(token), category: 'websocket',
          attributes: {'server.address': uri.host, 'url.path': uri.path});
        token.throwIfCancelled();
        connection = _SocketConnection(socket, credentials);
        _transition(_SocketStreaming(connection, operation));
      }
      final encoded = jsonEncode(continuation?.request(body) ?? body);
      await client._dump(() => encoded, token);
      token.throwIfCancelled();
      traceSync('openai.websocket.send', () => connection!.socket.add(encoded), category: 'websocket',
        attributes: {'bytes': utf8.encode(encoded).length});
      final reply = await client._consume(connection.events, token, onEvent,
        cancelIterator: false, idleTimeout: const Duration(seconds: 60));
      token.throwIfCancelled();
      _transition(_SocketReady(connection, reply.responseId == null ? null : _ResponseContinuation(body, reply)));
      return reply;
    } catch (_) {
      _cancel(operation);
      token.throwIfCancelled();
      rethrow;
    } finally {
      hook.dispose();
      operation.cancel();
      if (_state is _SocketReady || _state is _SocketIdle) _expiry = Timer(const Duration(minutes: 5), onIdle);
    }
  }

  void close() {
    final current = _state;
    if (current is _SocketClosed) return;
    _expiry?.cancel();
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
