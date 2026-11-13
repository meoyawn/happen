part of '../server.dart';

extension _McpInputs on AgentServer {
  bool _ownsMcpInput(_Client client, ({Json request, Completer<Json> answer, String? owner, String? threadId}) input) =>
    client.mcpInputs && (input.owner != null ? input.owner == client.id : input.threadId != null && client.subscriptions.contains(input.threadId));

  List<Json> _listMcpInputs(_Client client, String? threadId) => [
    for (final input in _mcpInputs.values)
      if (_ownsMcpInput(client, input) && (threadId == null || input.threadId == threadId)) input.request,
  ];

  void _replyMcpInput(_Client client, Json params) {
    final id = requiredString(params, 'request_id'), input = _mcpInputs[id];
    if (input == null || !_ownsMcpInput(client, input) || input.answer.isCompleted) throw StateError('MCP input is not pending for this caller');
    if (params['response'] is! Map) throw const FormatException('Provide an MCP input response object');
    _mcpInputs.remove(id); input.answer.complete(jsonObject(params['response']));
  }

  Future<void> _askMcpInput(Json message) async {
    final reply = message['reply'] as SendPort, params = jsonObject(message['params']);
    final operation = requiredString(message, 'operation_id'), id = requiredString(params, 'request_id');
    final token = CancellationToken(); _mcpOperations[operation] = token;
    final owner = params['owner'] as String?, threadId = params['threadId'] as String?;
    final cancellation = token.merge(_lifetime);
    final threadCancellation = threadId == null ? cancellation : cancellation.merge(_threadLifetime(threadId).cancellation);
    final clients = _clients.where((c) => c.mcpInputs && !c.cancellation.isCancelled &&
      (owner != null ? c.id == owner : threadId != null && c.subscriptions.contains(threadId))).toList();
    try {
      threadCancellation.throwIfCancelled();
      if (_closing || _mcpInputs.length >= 256 || clients.isEmpty || _mcpInputs.containsKey(id)) throw StateError('No capable MCP input client is available');
      final answer = Completer<Json>(), request = <String, dynamic>{'request_id': id, 'source': params['source'],
        'request': jsonObject(params['request']), if (threadId != null) 'threadId': threadId};
      _mcpInputs[id] = (request: request, answer: answer, owner: owner, threadId: threadId);
      for (final client in clients) { client.event({'method': 'mcp.input.requested', 'params': request}); }
      final result = await answer.future.asCancellable(owner == null ? threadCancellation : threadCancellation.merge(clients.single.cancellation));
      reply.send({'result': result});
    } catch (error) {
      reply.send({'error': 'MCP input ended without an available caller response', if (error is CancelledException) 'code': 'cancelled'});
    } finally {
      _mcpInputs.remove(id); _mcpOperations.remove(operation); token.cancel();
      for (final client in clients) { client.event({'method': 'mcp.input.closed', 'params': {'request_id': id, if (threadId != null) 'threadId': threadId}}); }
    }
  }
}
