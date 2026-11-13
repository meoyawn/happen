import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart' show ArchiveException, InputFileStream, ZstdDecoder;
import 'package:ai/ai.dart';
import 'package:openai/openai.dart' show gptInput, gptItemFromRollout;
import 'package:protocol/protocol.dart';
import 'package:telemetry/telemetry.dart';

import 'src/codex_native.dart';
import 'src/session_reader.dart';

export 'src/owner.dart' show startStore, importHistory;
export 'src/session_reader.dart' show readSession, readMcpEventOwners;
export 'src/thread_list.dart' show listThreads;
export 'src/server_store.dart' show startServerStore;

part 'src/kv.dart';
part 'src/native_adapter.dart';
part 'src/lifecycle.dart';
part 'src/goals.dart';
part 'src/mcp_events.dart';

/// One WAL database, exclusively owned by one writer isolate, per session.
/// Codex RolloutLines are canonical; thread history is a rebuildable projection.
class TaskStore {
  TaskStore(this.directory, this.taskId, {bool create = true, bool inMemory = false}) {
    validateTaskId(taskId);
    final folder = Directory('$directory/tasks/$taskId');
    if (!inMemory && !create && !File('${folder.path}/history.sqlite').existsSync()) {
      throw StateError('Task does not exist: $taskId');
    }
    if (!inMemory) {
      folder.createSync(recursive: true);
    }
    TracedDatabase? opened;
    try {
      db = opened = openTracedDatabase(inMemory ? ':memory:' : '${folder.path}/history.sqlite');
      db.execute('PRAGMA journal_mode=WAL');
      db.execute('PRAGMA synchronous=NORMAL');
      db.execute('PRAGMA foreign_keys=ON');
      db.execute('PRAGMA cache_size=-512');
      db.execute('PRAGMA busy_timeout=0');
      db.execute('BEGIN');
      db.execute('''CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL) STRICT;
        CREATE TABLE IF NOT EXISTS happen_runtime(singleton INTEGER PRIMARY KEY CHECK(singleton IS 1),data TEXT NOT NULL) STRICT;
        CREATE TABLE IF NOT EXISTS kv(key TEXT PRIMARY KEY,value TEXT NOT NULL,time_created INTEGER NOT NULL,time_updated INTEGER NOT NULL) STRICT;''');
      // Delete retired provider switches before restoring saved settings. Tool
      // mode belongs to the model catalog.
      db.execute(r'''UPDATE metadata SET value = json_remove(value,
          '$.provider_settings.standalone_web_search', '$.provider_settings.code_mode_only')
        WHERE key IS 'config' AND json_extract(value, '$.provider') IN ('openai', 'gpt')
          AND (json_type(value, '$.provider_settings.standalone_web_search') IS NOT NULL
            OR json_type(value, '$.provider_settings.code_mode_only') IS NOT NULL)''');
      final row = db.select('SELECT data FROM happen_runtime').firstOrNull;
      state = row == null ? {'sourceSeq': 0, 'window': '$taskId:0', 'pendingInputs': <String, dynamic>{}} :
        jsonObject(jsonDecode(row['data'] as String));
      native = CodexSqlite(db, taskId);
      db.execute('''
        CREATE TABLE IF NOT EXISTS thread_goals (
          thread_id TEXT PRIMARY KEY NOT NULL,goal_id TEXT NOT NULL,objective TEXT NOT NULL,
          status TEXT NOT NULL CHECK(status IN ('active','paused','blocked','usage_limited','budget_limited','complete')),
          token_budget INTEGER,tokens_used INTEGER NOT NULL DEFAULT 0,time_used_seconds INTEGER NOT NULL DEFAULT 0,
          created_at_ms INTEGER NOT NULL,updated_at_ms INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS thread_goal_continuation_deferrals (
          thread_id TEXT PRIMARY KEY NOT NULL REFERENCES thread_goals(thread_id) ON DELETE CASCADE
        );
      ''');
      db.execute('COMMIT');
      _restoreObservedUsage();
    } catch (_) {
      // A failed initializer must not leave a writable connection/transaction
      // behind after its writer isolate fails to start.
      opened?.close();
      rethrow;
    }
  }

  final String directory, taskId;
  final _pendingNativeItems = <Json>[];
  Object? queueNativeCompletion(Json item) { _pendingNativeItems.add(item); return null; }
  late final TracedDatabase db;
  late final CodexSqlite native;
  late Json state;
  bool _closed = false;
  void close() {
    if (_closed) return;
    db.close();
    _closed = true;
  }

  int get lastSequence => state['sourceSeq'] as int? ?? 0;
  Object? metadata(String key) {
    final row = db.select('SELECT value FROM metadata WHERE key IS ?', [key]).firstOrNull;
    return row == null ? null : jsonDecode(row['value'] as String);
  }
  Object? metadataValue(String key) => metadata(key);
  void _metadata(Json changes) {
    for (final entry in changes.entries) {
      db.execute('INSERT INTO metadata VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
        [entry.key, jsonEncode(entry.value)]);
    }
  }
  void _runtime(Json next) => db.execute(
    'INSERT INTO happen_runtime VALUES (1,?) ON CONFLICT(singleton) DO UPDATE SET data=excluded.data', [jsonEncode(next)]);

  Json append(String type, Json data, {Json metadata = const {}}) =>
    appendBatch([{'type': type, 'data': data}], metadata: metadata).single;

  List<Json> appendBatch(List<Json> values, {Json metadata = const {}}) => traceSync('storage.commit', () {
    if (values.isEmpty) throw const FormatException('Empty history transaction');
    for (final value in values) {
      final type = requiredString(value, 'type');
      jsonEncode(jsonObject(value['data']));
      if (type == 'model.started' || type == 'model.completed') requiredString(jsonObject(value['data']), 'assistantMessageID');
    }
    final next = jsonObject(jsonDecode(jsonEncode(state))), records = <Json>[];
    final now = DateTime.now().toUtc();
    next['created'] ??= now.millisecondsSinceEpoch;
    for (final value in values) {
      final data = jsonObject(value['data']), type = value['type'];
      if (type == 'turn.started') next['turnTokenUsage'] = <String, Object?>{};
      final observation = data['observed_usage'] ?? data['incompleteUsage'];
      final spending = observation?['usage'] as Json?;
      final usage = spending ?? (const {'model.completed', 'context.compacted'}.contains(type) ? <String, dynamic>{
        'input_tokens': data['usage']?['input_tokens'] ?? 0, 'output_tokens': data['usage']?['output_tokens'] ?? 0,
        'cached_input_tokens': data['usage']?['cached_input_tokens'] ?? 0,
        'cache_write_input_tokens': data['usage']?['cache_write_tokens'] ?? 0,
        'reasoning_output_tokens': data['usage']?['reasoning_tokens'] ?? 0,
        'total_tokens': data['usage']?['total_tokens'] ??
          (data['usage']?['input_tokens'] as int? ?? 0) + (data['usage']?['output_tokens'] as int? ?? 0),
      } : null);
      if (usage != null) {
        Json total(Object? previous) => {for (final entry in usage.entries)
          entry.key: (jsonObject(previous ?? {})[entry.key] as int? ?? 0) + (entry.value as int)};
        next['turnTokenUsage'] = total(next['turnTokenUsage']);
        next['totalTokenUsage'] = total(next['totalTokenUsage']);
        if (spending != null && observation['response_id'] is String) {
          data['tokenUsageRecord'] = {'thread_id': taskId, 'turn_id': next['turnID'], 'session_id': taskId,
            'root_turn_id': next['turnID'], 'response_id': observation['response_id'], 'usage': spending,
            'turn_token_usage': next['turnTokenUsage'], 'thread_token_usage': next['totalTokenUsage']};
          next['latestTokenUsageRecord'] = data['tokenUsageRecord'];
        }
      }
      next['sourceSeq'] = (next['sourceSeq'] as int? ?? 0) + 1;
      if (!{'task.archived', 'task.unarchived', 'thread.name.updated'}.contains(type)) next['updated'] = now.millisecondsSinceEpoch;
      if (type == 'context.compacted') { next['window'] = newId(); next.remove('tokens'); }
      final record = <String, dynamic>{'seq': next['sourceSeq'], 'id': newId(),
        'window_id': next['window'], 'type': type, 'created_at': now.toIso8601String(), 'data': data};
      final pending = jsonObject(next['pendingInputs'] ?? {});
      if (type == 'input.pending') pending[requiredString(data, 'id')] = data;
      if (type == 'input.committed') pending.remove(data['message_id']);
      if (type == 'input.discarded') for (final id in data['ids'] as List) { pending.remove(id); }
      if (type == 'input.delivery' && pending[data['id']] is Map) pending[data['id']]['delivery'] = data['delivery'];
      next['pendingInputs'] = pending;
      if (type == 'model.completed') next['tokens'] = sessionTokens(jsonObject(data['usage'] ?? {}));
      if (type == 'tool_runtime.started') {
        next['runtimeID'] = data['id']; next['runtimeHasHandles'] = false;
      }
      if (const {'turn.completed', 'turn.failed', 'turn.cancelled'}.contains(type)) {
        // Completion stats travel to clients; the rollout keeps its existing receipts.
        data['tokenUsage'] = next['turnTokenUsage'];
      }
      if ({'tool.started', 'host_tool.started'}.contains(type) &&
          {'exec_command', 'write_stdin', 'shell'}.contains(data['name'])) {
        next['runtimeHasHandles'] = true;
      }
      record['notifications'] = threadNotifications(taskId, record, next);
      records.add(record);
    }
    final nativeCount = _persistNative(records, metadata, next);
    state = next;
    _pendingNativeItems.removeRange(0, nativeCount);
    return records;
  }, category: 'storage', attributes: {'storage.architecture': 'codex', 'storage.events': values.length});

  Object? keyValue(String method, Json arguments) => _keyValue(this, method, arguments);

  List<Json> modelContext({int maxBytes = maxContextBytes}) {
    var result = <Json>[];
    final calls = <String, ToolCall>{};
    withHistoryLineage(directory, taskId, db, (segments) {
      final suffix = <({String id, List<Map<String, Object?>> rows})>[];
      for (final segment in segments.reversed) {
        final checkpoint = segment.db.select("SELECT ordinal FROM rollout_lines WHERE ordinal < ? AND json_extract(line,'\$.type') IS 'compacted' "
          "AND (happen_context IS NOT NULL OR (json_type(line,'\$.payload.replacement_history') IS 'array' AND json_type(line,'\$.payload.window_number') IS 'integer')) ORDER BY ordinal DESC LIMIT 1",
          [segment.end]).firstOrNull;
        suffix.insert(0, (id: segment.id, rows: segment.db.select('SELECT ordinal,line,happen_context FROM rollout_lines WHERE ordinal >= ? AND ordinal < ? ORDER BY ordinal',
          [checkpoint?['ordinal'] ?? 0, segment.end]).toList()));
        if (checkpoint != null) break;
      }
      for (final segment in suffix) {
        for (final row in segment.rows) {
          final line = jsonObject(jsonDecode(row['line'] as String));
          if (line['type'] == 'compacted') { result.clear(); calls.clear(); }
          if (row['happen_context'] case final String context) {
            final values = (jsonDecode(context) as List).map(jsonObject).toList();
            result.addAll(values);
            for (final item in values.map(ConversationItem.fromJson)) {
              for (final call in item.calls) { calls[call.id] = call; }
            }
          } else {
            if (!{'response_item', 'compacted'}.contains(line['type'])) continue;
            final payload = jsonObject(line['payload']);
            final responses = line['type'] == 'response_item' ? [payload] : line['type'] == 'compacted'
              ? (payload['replacement_history'] as List? ?? <Json>[
                {'type': 'message', 'role': 'user', 'content': [{'type': 'input_text', 'text': payload['message'] ?? ''}]},
              ]).map(jsonObject).toList() : <Json>[];
            for (final (index, response) in responses.indexed) {
              result.add(gptItemFromRollout(response, id: response['id'] as String? ?? '${segment.id}:${row['ordinal']}:$index', calls: calls).toJson());
            }
          }
        }
      }
    });
    if (utf8.encode(jsonEncode(result)).length > maxBytes) throw const FormatException('Model context exceeds byte limit');
    return result;
  }

  Json modelSnapshot() => {
    'input': modelContext(), 'requestTools': metadata('request_tools'), 'through': native.nextOrdinal,
    'sourceThrough': lastSequence, 'windowID': state['window'], 'effectiveReasoning': metadata('effective_reasoning'),
    'tokens': state['tokens'], 'created': state['created'], 'updated': state['updated'], 'archived': metadata('archived_at') != null,
  };
  void _restoreObservedUsage() {
    final checkpoint = withHistoryLineage(directory, taskId, db, (segments) {
      for (final segment in segments.reversed) {
        final row = segment.db.select("SELECT line FROM rollout_lines WHERE ordinal < ? AND json_extract(line,'\$.type') IN ('token_usage_record','compacted') ORDER BY ordinal DESC LIMIT 1", [segment.end]).firstOrNull;
        if (row == null) continue;
        final line = jsonObject(jsonDecode(row['line'] as String));
        return (found: true, record: line['type'] == 'token_usage_record' ? line['payload'] : line['payload']['latest_token_usage_record']);
      }
      return (found: false, record: null);
    });
    if (!checkpoint.found) return;
    final latest = checkpoint.record == null ? null : jsonObject(checkpoint.record);
    state['latestTokenUsageRecord'] = latest;
    state['totalTokenUsage'] = latest?['thread_token_usage'] ?? <String, Object?>{};
    state['turnTokenUsage'] = latest != null && latest['turn_id'] == state['turnID']
      ? latest['turn_token_usage'] ?? <String, Object?>{} : <String, Object?>{};
  }
  Future<void> prepareSession({required CancellationToken cancellation}) async {
    cancellation.throwIfCancelled();
    await native.catchUpCancellable(cancellation);
  }
  List<Json> startToolRuntime(String id) {
    final input = modelContext().map(ConversationItem.fromJson).toList();
    final completed = input.expand((item) => item.content).where((part) => part['type'] == 'tool_result').map((p) => p['call_id']).toSet();
    final interrupted = input.expand((item) => item.calls).where((call) => !completed.contains(call.id)).toList();
    final settlement = [for (final call in interrupted)
      {'type': 'tool.completed', 'data': {'item': ConversationItem.toolResult(call,
        'Interrupted before a durable result. Side effects may have occurred; inspect state before retrying.', isError: true).toJson()}}];
    if (state['runtimeID'] == id) return settlement.isEmpty ? [] : appendBatch(settlement);
    final restarted = interrupted.isNotEmpty || state['runtimeHasHandles'] == true;
    return appendBatch([
      ...settlement,
      {'type': 'tool_runtime.started', 'data': {'id': id}},
      if (restarted) {'type': 'context.injected', 'data': {'item': ConversationItem(role: 'user', content: [{
        'type': 'text',
        'text': 'The tool runtime was restarted. Command sessions, background commands, and running code cells '
          'from the previous runtime are no longer available. Do not reuse earlier session or cell IDs. '
          'Completed tool results and stored values remain available. Continue from the recorded results, '
          'inspect the effects of interrupted commands, and start a new command only when needed.',
      }], native: {'harness': {'context': 'tool_notification', 'reason': 'tool_runtime_restarted'}}).toJson()}},
    ]);
  }
  Json inbox() => {'data': jsonObject(state['pendingInputs'] ?? {}).values.toList()};
  Json? discardSessionInbox(String reason) {
    final ids = jsonObject(state['pendingInputs'] ?? {}).keys.toList();
    return ids.isEmpty ? null : append('input.discarded', {'ids': ids, 'reason': reason});
  }
  Json? changeSessionInbox(String id, {String? delivery}) {
    if (delivery != null && !{'steer', 'queue'}.contains(delivery)) throw ArgumentError('Delivery must be steer or queue');
    final source = id.replaceFirst(RegExp(r'^msg_'), '');
    final input = jsonObject(state['pendingInputs'] ?? {})[source];
    if (input == null) throw StateError('Message is no longer pending');
    if (input['delivery'] == delivery) return null;
    return delivery == null ? append('input.discarded', {'ids': [source], 'reason': 'deleted'}) :
      append('input.delivery', {'id': source, 'delivery': delivery});
  }
  List<Json> commitSessionInputs(List<String> ids, {required String effort, required bool reasoningUpdates}) {
    final events = <Json>[];
    final receipts = (metadata('mcp_event_receipts') as List? ?? []).cast<String>().toSet();
    var selected = effort;
    for (final entry in jsonObject(state['pendingInputs'] ?? {}).entries) {
      final input = jsonObject(entry.value);
      if (!ids.contains(entry.key) || input['delivery'] != 'steer' && !receipts.contains(entry.key)) continue;
      if (input['reasoning'] case final String value when value != selected) {
        if (!reasoningUpdates) throw ArgumentError('Reasoning effort is fixed for this task');
        selected = value;
        events.add({'type': 'configuration.updated', 'data': {'effort': value,
          'item': ConversationItem(kind: 'configuration', settings: {'reasoning': value}).toJson()}});
      }
      events.add({'type': 'input.committed', 'data': {'message_id': entry.key, 'delivery': input['delivery'], 'sent_at': input['created_at'],
        'item': ConversationItem.user(input['prompt'] as String, attachments: input['attachments']).toJson()}});
    }
    return events.isEmpty ? [] : appendBatch(events, metadata: {'effective_reasoning': selected});
  }

  static Future<String> importFrom(String directory, String source, {String? operationId,
    required Future<String> Function(Json config) newTaskId, CancellationToken? cancellation}) =>
      _importRollout(directory, source, operationId: operationId, newTaskId: newTaskId, cancellation: cancellation);
}
