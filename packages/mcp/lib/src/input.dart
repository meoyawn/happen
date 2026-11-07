part of 'transport.dart';

class _InputClock {
  _InputClock(this.method, this.duration) : remaining = duration { _resume(); }
  final String method;
  final Duration? duration;
  Duration? remaining;
  final cancellation = CancellationToken(), active = Stopwatch();
  Timer? timer;
  var paused = 0, closed = false;
  void pause() {
    if (paused++ != 0 || closed) return;
    timer?.cancel(); active.stop();
    if (remaining != null) remaining = remaining! - active.elapsed;
    active.reset();
  }
  void resume() { if (--paused == 0 && !closed) _resume(); }
  void _resume() {
    active.start();
    if (remaining case final remaining?) {
      timer = Timer(remaining.isNegative ? Duration.zero : remaining,
        () => cancellation.cancel(mcpOperationTimeout(method, duration!)));
    }
  }
  void close() { closed = true; timer?.cancel(); active.stop(); }
}

McpFailure _invalidInput(String message, [int code = -32600]) => McpFailure(message, code: code);
bool _inputObject(Object? value) => value is Map;
bool _nativeInput(Json request) => request['method'] == 'openai/elicitation/create' && request['params']['mode'] == 'openai/userVerification';

Json _parseMcpInput(Object? value, Json capabilities, {bool olderWire = false}) {
  if (value is! Map || value['method'] is! String || value['params'] is! Map) throw _invalidInput('Invalid MCP input request');
  final request = jsonObject(value), params = {...jsonObject(request['params'])}, method = request['method'];
  final standard = method == 'elicitation/create';
  final native = method == 'openai/elicitation/create' && params['mode'] == 'openai/userVerification';
  if (standard || native) {
    final meta = params['_meta'];
    if (meta != null && meta is! Map) throw _invalidInput('Invalid MCP input metadata', -32602);
    if (meta == null) params.remove('_meta');
    else params['_meta'] = {...jsonObject(meta)}..remove('progressToken');
  } else if (params['_meta'] is Map) { params['_meta'] = {...jsonObject(params['_meta'])}..remove('progressToken'); }
  final elicitation = jsonObject(capabilities['elicitation'] ?? {}), extensions = jsonObject(capabilities['extensions'] ?? {});
  final openai = jsonObject(extensions['openai/elicitation'] ?? {});
  if (standard) {
    final mode = params.containsKey('mode') ? params['mode'] : 'form';
    if (!['form', 'url'].contains(mode) || !_inputObject(elicitation[mode])) throw _invalidInput('MCP input capability was not advertised');
    if (params['message'] is! String || mode == 'form' && (params['requestedSchema'] is! Map || params['requestedSchema']['type'] != 'object') ||
        mode == 'url' && (params['url'] is! String || params['elicitationId'] is! String)) throw _invalidInput('Invalid MCP elicitation request', -32602);
  } else if (method == 'openai/form' || method == 'openai/elicitation/create' && params['mode'] == 'form') {
    if (method == 'openai/form' ? !extensions.containsKey(method) : !_inputObject(openai['form'])) throw _invalidInput('MCP input capability was not advertised');
    if (params['message'] is! String || !params.containsKey('requestedSchema')) throw _invalidInput('Invalid MCP form request', -32602);
  } else if (native) {
    if (!_inputObject(openai['userVerification'])) throw _invalidInput('MCP input capability was not advertised');
    if (params.keys.any((key) => !{'mode', 'title', 'description', 'challenge', '_meta'}.contains(key)) ||
        params['title'] is! String || (params['title'] as String).isEmpty || utf8.encode(params['title'] as String).length > 256 ||
        params['description'] is! String || utf8.encode(params['description'] as String).length > 4096 || !_inputBytes(params['challenge'], 4096)) {
      throw _invalidInput('Invalid user-verification request', -32602);
    }
  } else if (method == 'openai/elicitation/create') {
    throw _invalidInput(olderWire ? 'Invalid elicitation mode' : 'unsupported OpenAI elicitation mode', olderWire ? -32602 : -32600);
  } else { throw _invalidInput('Unsupported MCP input request'); }
  return {'method': method, 'params': params};
}

bool _inputBytes(Object? value, int maximum) {
  if (value is! String || value.isEmpty || value.length > ((maximum + 2) ~/ 3) * 4 || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) return false;
  try {
    final bytes = base64Url.decode(base64Url.normalize(value));
    return bytes.isNotEmpty && bytes.length <= maximum && base64Url.encode(bytes).replaceAll('=', '') == value;
  } on FormatException { return false; }
}
const _verificationReasons = {'userCancelled', 'userDeclined', 'credentialMissing', 'biometricsUnavailable', 'providerUnavailable',
  'authenticationFailed', 'timeout', 'providerError', 'serviceError', 'invalidParams', 'invalidProof', 'invalidResponse', 'responseError',
  'responseChannelClosed', 'interrupted', 'approvalUnavailable'};
Json _cancelInput(Json request, String reason) => {'action': 'cancel', if (_nativeInput(request)) '_meta': {'openai/userVerificationReason': reason}};
Json _inputResponse(Json request, Json response, {required bool olderWire}) {
  final action = response['action'];
  if (_nativeInput(request)) {
    if (!['accept', 'cancel', 'decline'].contains(action)) return _cancelInput(request, 'invalidResponse');
    if (action == 'accept') {
      final content = response['content'];
      if (content is! Map || content.length != 2 || content['credentialId'] is! String || (content['credentialId'] as String).isEmpty ||
          utf8.encode(content['credentialId'] as String).length > 1024 || !_inputBytes(content['signature'], 128)) return _cancelInput(request, 'invalidProof');
      return {'action': 'accept', 'content': content};
    }
    final meta = response['_meta'], reason = meta is Map ? meta['openai/userVerificationReason'] : null;
    return {'action': action, if (_verificationReasons.contains(reason)) '_meta': {'openai/userVerificationReason': reason}};
  }
  if (!['accept', 'cancel', 'decline'].contains(action)) throw _invalidInput('Invalid MCP input response', -32602);
  if (!olderWire && request['method'] == 'elicitation/create' && response['_meta'] != null && response['_meta'] is! Map) {
    throw _invalidInput('MCP elicitation response metadata must be an object', -32602);
  }
  return {'action': action, 'content': ?response['content'], '_meta': ?response['_meta']};
}

Future<Json> _askMcpInput(McpConnection connection, Json request, McpInputHandler? sender, _InputClock? clock,
    CancellationToken cancellation, {CancellationToken? peerCancellation, String? cancelled}) async {
  final parsed = _parseMcpInput(request, connection.clientCapabilities, olderWire: !connection.modern);
  if (cancelled != null) return _cancelInput(parsed, cancelled);
  if (sender == null) throw _invalidInput('No interactive MCP input handler is available', -32601);
  final token = peerCancellation == null ? cancellation : cancellation.merge(peerCancellation);
  clock?.pause();
  try {
    final response = await sender('mcp-input/${newId()}', parsed, token).asCancellable(token);
    return _inputResponse(parsed, response, olderWire: !connection.modern);
  } catch (_) {
    if (peerCancellation?.isCancelled == true && !cancellation.isCancelled) return _cancelInput(parsed, 'interrupted');
    rethrow;
  } finally { clock?.resume(); }
}

Future<Json> _driveMcpInputs(McpConnection connection, String method, Json params, CancellationToken cancellation, {
  required _InputClock clock, required _McpAuthorization access, void Function(Json)? onNotification, Json? inputSchema,
  bool retrySafe = false, McpInputHandler? onInput, bool readOnly = false,
}) async {
  final base = {...params}..remove('inputResponses')..remove('requestState');
  var next = params, answered = params['inputResponses'] is Map && (params['inputResponses'] as Map).isNotEmpty, stateOnly = 0;
  for (var round = 0; round < 10; round++) {
    Json result;
    try {
      result = await connection._request(method, next, cancellation: cancellation, access: access, onNotification: onNotification,
        inputSchema: inputSchema, retrySafe: retrySafe && !answered, onInput: onInput, clock: clock,
        allowReplay: !answered, readOnly: readOnly);
    } on McpFailure catch (failure) {
      if (answered && failure.status != null && failure.status != 401 && failure.status != 403) {
        throw McpFailure('MCP continuation failed; the operation was not restarted', code: failure.code, status: failure.status);
      }
      rethrow;
    }
    if (result['resultType'] != 'input_required') return result;
    if (round == 9) break;
    final state = result['requestState'], raw = result['inputRequests'];
    if (state != null && state is! String || raw != null && raw is! Map) throw _invalidInput('Invalid MCP input request');
    final requests = jsonObject(raw ?? {});
    if (requests.isEmpty && state == null) throw _invalidInput('MCP input request has neither inputs nor continuation state');
    final parsed = <String, Json>{};
    for (final key in requests.keys.toList()..sort()) { parsed[key] = _parseMcpInput(requests[key], connection.clientCapabilities); }
    final responses = <String, Json>{};
    if (parsed.isEmpty) {
      await cancellableDelay(Duration(milliseconds: (50 << stateOnly.clamp(0, 3)).clamp(0, 250)), cancellation); stateOnly++;
    } else {
      stateOnly = 0; final roundLifetime = CancellationToken(), inputToken = cancellation.merge(roundLifetime);
      try {
        await Future.wait(parsed.entries.map((entry) async {
          responses[entry.key] = await _askMcpInput(connection, entry.value, onInput, clock, inputToken);
        }), eagerError: true);
      } finally { roundLifetime.cancel(); }
      answered = true;
    }
    next = {...base, 'requestState': ?state, if (responses.isNotEmpty) 'inputResponses': responses};
  }
  throw _invalidInput('MCP MRTR exceeded its 10-round input budget');
}

Future<void> _serveMcpInput(McpConnection connection, Json message) async {
  final id = message['id'];
  if (message['method'] == 'ping') { connection._write({'jsonrpc': '2.0', 'id': id, 'result': <String, Object?>{}}); return; }
  final peer = CancellationToken();
  try {
    if (id is! String && id is! int || connection._inputCancellations.containsKey(id)) throw _invalidInput('Invalid MCP input request');
    connection._inputCancellations[id as Object] = peer;
    final candidates = connection._pending.values.where((p) => p.input != null && {'tools/call', 'resources/read', 'prompts/get'}.contains(p.method)).toList();
    if (candidates.length != 1) throw _invalidInput('MCP input request has no unambiguous caller', -32602);
    final parent = candidates.single;
    final early = connection._inputCancellationSaturated ? 'approvalUnavailable' : connection._earlyInputCancellations.remove(id) ? 'interrupted' : null;
    final result = await _askMcpInput(connection, message, parent.input, parent.clock, parent.cancellation,
      peerCancellation: peer, cancelled: early);
    connection._write({'jsonrpc': '2.0', 'id': id, 'result': result});
  } on McpFailure catch (error) {
    connection._write({'jsonrpc': '2.0', 'id': id, 'error': {'code': error.code ?? -32603, 'message': error.message}});
  } catch (_) {
    connection._write({'jsonrpc': '2.0', 'id': id, 'error': {'code': -32603, 'message': 'MCP input request ended without a response'}});
  } finally {
    if (identical(connection._inputCancellations[id], peer)) connection._inputCancellations.remove(id);
    peer.cancel();
  }
}
