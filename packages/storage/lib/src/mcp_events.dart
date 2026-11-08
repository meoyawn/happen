part of '../storage.dart';

Object? _mcpOrdered(Object? value) => switch (value) {
  Map() => {for (final key in value.keys.cast<String>().toList()..sort()) key: _mcpOrdered(value[key])},
  List() => value.map(_mcpOrdered).toList(),
  _ => value,
};
bool _sameMcpState(Object? a, Object? b) => jsonEncode(_mcpOrdered(a)) == jsonEncode(_mcpOrdered(b));

extension McpEventStore on TaskStore {
  Json _mcpSubscriptions() => jsonObject(metadata('mcp_event_subscriptions') ?? {});
  void _checkMcpOwner() {
    if (metadata('archived_at') != null || jsonObject(metadata('config'))['ephemeral'] == true) {
      throw StateError('MCP subscriptions require an active saved thread');
    }
  }
  Json _mcpCheckpoint(Json subscriptions, Json snapshot) {
    final id = requiredString(snapshot, 'subscription_id'), previous = subscriptions[id];
    if (previous == null) throw StateError('MCP subscription was removed');
    if (snapshot['threadId'] != taskId || previous['server'] != snapshot['server'] || previous['name'] != snapshot['name']) {
      throw StateError('MCP subscription authority changed');
    }
    return {...subscriptions, id: snapshot};
  }
  void _writeMcpSubscriptions(Json before, Json after) {
    if (_sameMcpState(before, after)) return;
    db.execute('BEGIN');
    try { _metadata({'mcp_event_subscriptions': after}); db.execute('COMMIT'); }
    catch (_) { db.execute('ROLLBACK'); rethrow; }
  }
  Json _mcpRecoveryState(Json subscriptions) {
    final receipts = (metadata('mcp_event_receipts') as List? ?? []).cast<String>().toSet();
    return {'subscriptions': subscriptions.keys.toList(),
      'pending': jsonObject(state['pendingInputs'] ?? {}).values.map(jsonObject).any((item) => receipts.contains(item['id']))};
  }
  Json mcpSubscription(String action, Json params) {
    final previous = _mcpSubscriptions();
    if (action == 'remove') {
      final next = {...previous}..remove(requiredString(params, 'subscription_id'));
      _writeMcpSubscriptions(previous, next); return _mcpRecoveryState(next);
    }
    _checkMcpOwner();
    final snapshot = jsonObject(params['snapshot']), id = requiredString(snapshot, 'subscription_id');
    if (snapshot['threadId'] != taskId) throw StateError('MCP subscription belongs to another thread');
    final next = params['create'] == true ? {...previous, id: snapshot} : _mcpCheckpoint(previous, snapshot);
    if (next.length > 64) throw StateError('MCP event subscription limit reached');
    _writeMcpSubscriptions(previous, next); return _mcpRecoveryState(next);
  }

  /// Inbox, receipt and resume checkpoint are one durability boundary. No
  /// separate cursor write follows admission, and identical duplicates write
  /// nothing. The existing canonical/runtime transaction still owns the commit.
  Json admitMcpEvent(Json params) {
    _checkMcpOwner();
    final snapshot = jsonObject(params['snapshot']), before = _mcpSubscriptions();
    final after = _mcpCheckpoint(before, snapshot), receipt = requiredString(params, 'receipt');
    final receipts = (metadata('mcp_event_receipts') as List? ?? []).cast<String>();
    if (receipts.contains(receipt)) {
      _writeMcpSubscriptions(before, after);
      return {'duplicate': true, 'pending': jsonObject(state['pendingInputs'] ?? {}).values.toList()};
    }
    final message = jsonObject(params['message']), pending = jsonObject(state['pendingInputs'] ?? {}).values.map(jsonObject).toList();
    if (message['id'] != receipt || pending.length >= 32 || pending.fold<int>(utf8.encode(message['prompt'] as String).length,
        (size, input) => size + utf8.encode(input['prompt'] as String).length) > 512 * 1024) throw StateError('Pending message limit reached');
    final event = append('input.pending', message, metadata: {
      'mcp_event_receipts': [...receipts.skip((receipts.length - 2047).clamp(0, receipts.length)), receipt],
      'mcp_event_subscriptions': after,
    });
    return {'event': event, 'pending': jsonObject(state['pendingInputs'] ?? {}).values.toList()};
  }
}
