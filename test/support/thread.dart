import 'dart:async';
import 'dart:convert';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:sqlite3/sqlite3.dart';

Future<String> createThread(AgentClient client, Json configuration) async =>
  jsonObject(await client.request('thread/start', configuration))['thread']['id'] as String;

/// Callers configure a short idle delay; unsubscribing never interrupts a turn.
Future<void> unloadThread(AgentClient client, String id, {CancellationToken? cancellation}) async {
  final deadline = TimeoutCancellationToken(const Duration(seconds: 20));
  final token = cancellation == null ? deadline : cancellation.merge(deadline);
  final input = StreamIterator(client.events.stream);
  try {
    final reply = jsonObject(await client.request('thread/unsubscribe', {'threadId': id}).asCancellable(token));
    if (reply['status'] == 'notLoaded') return;
    while (await input.moveNext().asCancellable(token, onCancel: () => unawaited(input.cancel()))) {
      if (input.current['method'] == 'thread/closed' && input.current['params']['threadId'] == id) return;
    }
    throw StateError('Connection closed before thread unloading');
  } finally { deadline.cancel(); await input.cancel(); }
}

/// Own the subscription before admission; return the native completed Turn.
Future<Json> runTurn(AgentClient client, String id, {String prompt = '', bool compact = false, Json settings = const {}}) async {
  final deadline = TimeoutCancellationToken(const Duration(seconds: 20));
  final input = StreamIterator(client.events.stream);
  try {
    await client.request(compact ? 'thread/compact/start' : 'turn/start', {'threadId': id,
      if (!compact) 'input': [{'type': 'text', 'text': prompt}], ...settings}).asCancellable(deadline);
    while (await input.moveNext().asCancellable(deadline, onCancel: () => unawaited(input.cancel()))) {
      final event = input.current;
      if (event['method'] == 'turn/completed' && event['params']['threadId'] == id) return jsonObject(event['params']['turn']);
    }
    throw StateError('Connection closed before turn completion');
  } finally { deadline.cancel(); await input.cancel(); }
}

Future<List<Json>> contextItems(AgentClient client, String id) async {
  final deadline = TimeoutCancellationToken(const Duration(seconds: 20));
  final items = <Json>[];
  String? cursor;
  try {
    do {
      final page = await client.sessionRead('session.context', {'sessionID': id, if (cursor != null) 'cursor': cursor}, cancellation: deadline);
      items.addAll((page['input'] as List).map(jsonObject));
      cursor = page['cursor']?['next'] as String?;
    } while (cursor != null);
    return items;
  } finally { deadline.cancel(); }
}

Future<List<Json>> rolloutLines(AgentClient client, String id) async {
  final result = <Json>[];
  var after = 0;
  while (true) {
    final page = (await client.request('history.page', {'task_id': id, 'after': after, 'limit': 500}) as List).map(jsonObject).toList();
    result.addAll(page);
    if (page.length < 500) return result;
    after = (page.last['ordinal'] as int) + 1;
  }
}

/// Persistence assertions use a concurrent reader, never another writer owner.
Object? threadMetadata(String directory, String id, String key) {
  final db = sqlite3.open('$directory/tasks/$id/history.sqlite', mode: OpenMode.readOnly);
  try {
    final row = db.select('SELECT value FROM metadata WHERE key IS ?', [key]).firstOrNull;
    return row == null ? null : jsonDecode(row['value'] as String);
  } finally { db.close(); }
}
