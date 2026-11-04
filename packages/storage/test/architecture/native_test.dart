// Adapted from Codex f05aa41d rollout/recorder_tests.rs and
// thread-store/src/local/{thread_history_materialization_tests.rs,thread_history/read_tests.rs}.
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:storage/src/codex_native.dart';
import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late TracedDatabase db;
  late CodexSqlite store;
  Json event(String type,Json data) => {'type':'event_msg','payload':{'type':type,'turn_id':'turn-1',...data}};
  Json started({String root = 'root-1'}) => event('task_started',{'root_turn_id':root,'started_at':10});
  Json completed() => event('task_complete',{'completed_at':20,'duration_ms':10});
  Json item(String id,{String type = 'UserMessage',int? start,int? end,Json extra = const {}}) => event('item_completed',{
    'thread_id':'thread-1','item':{'type':type,'id':id,'content':<Object?>[],...extra},
    'started_at_ms':start,'completed_at_ms':end ?? 0,
  });
  Json checkpoint() => {...db.select('SELECT * FROM thread_history_projection_state').single};
  setUp(() {
    temp=Directory.systemTemp.createTempSync('happen-codex-contract-');
    db=openTracedDatabase('${temp.path}/history.sqlite');
    db.execute('PRAGMA journal_mode=WAL'); db.execute('PRAGMA synchronous=NORMAL');
    store=CodexSqlite(db,'thread-1');
    store.append([{'type':'session_meta','payload':{'id':'thread-1','history_mode':'paginated'}}]);
  });
  tearDown(() {db.close();temp.deleteSync(recursive:true);});

  test('recorder: materializes pending records on flush, one RolloutLine per record',() {
    store.append([started(),item('user-1'),completed()],timestamp:'2025-01-01T00:00:00.000Z');
    final rows=db.select('SELECT * FROM rollout_lines ORDER BY ordinal');
    expect(rows.map((r)=>r['ordinal']),[0,1,2,3]);
    var bytes=0;
    for(final row in rows) {
      expect(row['byte_offset'],bytes);
      final line=row['line'] as String;
      expect(jsonDecode(line)['ordinal'],row['ordinal']);
      bytes+=utf8.encode(line).length+1;
    }
    expect(checkpoint()['next_rollout_byte_offset'],bytes);
    expect(checkpoint()['next_rollout_ordinal'],4);
  });
  test('paginated policy filters transient and legacy events before the durability barrier',() {
    final reader=sqlite3.open('${temp.path}/history.sqlite',mode:OpenMode.readOnly);
    try {
      final before=reader.select('PRAGMA data_version').single.values.single;
      store.append([
        event('item_started',{'item':{'type':'UserMessage','id':'transient','content':<Object?>[]}}),
        event('mcp_tool_call_begin',{'call_id':'transient'}),
        event('agent_message_content_delta',{'delta':'streaming'}),
        event('user_message',{'message':'legacy duplicate'}),
        {'type':'response_item','payload':{'type':'compaction_trigger'}},
        {'type':'response_item','payload':{'type':'future_unknown_item'}},
      ]);
      expect(reader.select('PRAGMA data_version').single.values.single,before);
      expect(checkpoint()['next_rollout_ordinal'],1);
      store.append([started(),item('kept'),event('token_count',{'info':null})]);
      expect(reader.select('SELECT ordinal FROM rollout_lines ORDER BY ordinal').map((row)=>row['ordinal']),[0,1,2,3]);
      expect(store.items().single['item_id'],'kept');
    } finally {reader.close();}
  });
  test('paginated live append materializes turn items and state',() {
    store.append([started(),item('user-1'),item('agent-1',type:'AgentMessage',extra:{'phase':'final_answer'}),completed()]);
    final turn=db.select('SELECT * FROM thread_turns').single;
    expect(turn['status'],'completed'); expect(turn['first_user_item_id'],'user-1'); expect(turn['final_agent_item_id'],'agent-1');
    expect(store.items().map((v)=>v['item_id']),['user-1','agent-1']);
  });
  test('projection preserves exact lifecycle timestamps',() {
    const times=[(1789855978123,1789855979456),(1789855978123,1789855978123),(null,1789855979456),(null,null)];
    store.append([started(),for(final (i,time) in times.indexed)item('user-$i',start:time.$1,end:time.$2)]);
    expect(db.select('SELECT started_at_ms,completed_at_ms FROM thread_items ORDER BY rollout_ordinal')
      .map((r)=>(r['started_at_ms'],r['completed_at_ms'])),times);
  });
  test('unexpected duplicate item completion does not poison projection',() {
    store.append([started(),item('user-1',extra:{'client_id':null})]);
    final first=db.select('SELECT * FROM thread_items').single;
    store.append([item('user-1',extra:{'client_id':'updated'})]);
    final after=db.select('SELECT * FROM thread_items').single;
    expect(after['rollout_ordinal'],2); expect(after['updated_at_ordinal'],3);
    expect(after['created_at_ms'],first['created_at_ms']);
    expect(jsonDecode(after['item_json'] as String)['clientId'],'updated');
  });
  test('terminal turn does not change after later records',() {
    store.append([started(),completed()]);
    final before={...db.select('SELECT * FROM thread_turns').single};
    store.append([started(root:'wrong-root'),item('late-user')]);
    expect({...db.select('SELECT * FROM thread_turns').single},before);
  });
  test('active turn stores only its start position',() {
    store.append([started(),item('user-1')]);
    final turn=db.select('SELECT * FROM thread_turns').single;
    expect(turn['rollout_ordinal'],1); expect(turn['rollout_byte_offset'],isNotNull);
    expect(turn['rollout_end_ordinal'],isNull); expect(turn['rollout_end_byte_offset'],isNull);
  });
  test('next write catches up an unprojected durable suffix',() {
    final before=checkpoint();
    store.append([started()]);
    db.execute('DELETE FROM thread_turns');
    db.execute('UPDATE thread_history_projection_state SET next_rollout_byte_offset=?,next_rollout_ordinal=?',
      [before['next_rollout_byte_offset'],before['next_rollout_ordinal']]);
    store.append([item('user-1')]);
    expect(db.select('SELECT status FROM thread_turns').single['status'],'inProgress');
    expect(store.items().single['item_id'],'user-1'); expect(checkpoint()['next_rollout_ordinal'],3);
  });
  test('synchronized catch up does not replay old rows',() {
    store.append([started()]);
    final before=checkpoint(); db.execute("UPDATE thread_turns SET status='sentinel'");
    store.catchUp();
    expect(checkpoint(),before); expect(db.select('SELECT status FROM thread_turns').single['status'],'sentinel');
  });
  test('projection failure does not fail the durable canonical write',() {
    db.execute("CREATE TRIGGER broken BEFORE INSERT ON thread_turns BEGIN SELECT RAISE(ABORT,'projection fault'); END");
    final before=checkpoint();
    expect(()=>store.append([started()]),returnsNormally);
    final reader=sqlite3.open('${temp.path}/history.sqlite',mode:OpenMode.readOnly);
    try {expect(reader.select('SELECT ordinal FROM rollout_lines ORDER BY ordinal').map((r)=>r['ordinal']),[0,1]);}
    finally {reader.close();}
    expect(checkpoint(),before); expect(db.select('SELECT * FROM thread_turns'),isEmpty);
    db.execute('DROP TRIGGER broken'); store.catchUp();
    expect(db.select('SELECT * FROM thread_turns'),hasLength(1));
  });
  test('canonical write failure leaves neither appended records nor projected state',() {
    db.execute("CREATE TRIGGER broken BEFORE INSERT ON rollout_lines WHEN NEW.ordinal IS 2 BEGIN SELECT RAISE(ABORT,'canonical fault'); END");
    final before=checkpoint();
    expect(()=>store.append([started(),item('user-1')]),throwsA(anything));
    expect(db.select('SELECT * FROM rollout_lines'),hasLength(1));
    expect(checkpoint(),before); expect(db.select('SELECT * FROM thread_turns'),isEmpty);
  });
  test('catch up preserves committed batches when a later writer batch fails',() {
    db.execute('BEGIN');
    store.record([started(),for(var i=0;i<300;i++)item('user-$i')]);
    db.execute('COMMIT');
    db.execute("CREATE TRIGGER broken BEFORE INSERT ON thread_items WHEN NEW.item_id IS 'user-270' BEGIN SELECT RAISE(ABORT,'late fault'); END");
    expect(store.catchUp,throwsA(anything));
    expect(checkpoint()['next_rollout_ordinal'],257);
    expect(store.items(limit:1000),hasLength(255));
    db.execute('DROP TRIGGER broken'); store.catchUp();
    expect(store.items(limit:1000),hasLength(300));
    expect(checkpoint()['next_rollout_ordinal'],302);
  });
  test('realtime items materialize separately in rollout order',() {
    store.append([{'type':'realtime_item','payload':{'id':'rt-1','type':'realtime_session_started'}},
      {'type':'realtime_item','payload':{'id':'rt-2','type':'realtime_session_closed'}}]);
    expect(store.items(),isEmpty);
    expect(db.select('SELECT item_id FROM thread_realtime_items ORDER BY rollout_ordinal').map((r)=>r['item_id']),['rt-1','rt-2']);
  });
  test('subagent prefixes advance the checkpoint without materializing inherited turns or realtime items', () {
    // Codex thread_history_materialization_tests.rs::subagent_prefix_advances_projection_without_materializing_history.
    db.close(); db = openTracedDatabase('${temp.path}/subagent.sqlite'); store = CodexSqlite(db, 'thread-1');
    store.append([
      {'type': 'session_meta', 'payload': {'id': 'thread-1', 'history_mode': 'paginated', 'subagent_history_start_ordinal': 5}},
      {'type': 'realtime_item', 'payload': {'id': 'parent:started', 'type': 'realtime_session_started'}},
      event('task_started', {'turn_id': 'parent-turn'}),
      event('item_completed', {'turn_id': 'parent-turn', 'item': {'type': 'UserMessage', 'id': 'parent-user', 'content': <Json>[]}}),
      event('task_complete', {'turn_id': 'parent-turn'}),
      event('task_started', {'turn_id': 'child-turn'}),
      {'type': 'realtime_item', 'payload': {'id': 'child:started', 'type': 'realtime_session_started'}},
      event('item_completed', {'turn_id': 'child-turn', 'item': {'type': 'UserMessage', 'id': 'child-user', 'content': <Json>[]}}),
      event('task_complete', {'turn_id': 'child-turn'}),
    ]);
    expect(db.select('SELECT turn_id,rollout_ordinal FROM thread_turns').map((row) => (row['turn_id'], row['rollout_ordinal'])), [('child-turn', 5)]);
    expect(store.items().map((row) => (row['item_id'], row['rollout_ordinal'])), [('child-user', 7)]);
    expect(db.select('SELECT item_id,rollout_ordinal FROM thread_realtime_items').map((row) => (row['item_id'], row['rollout_ordinal'])), [('child:started', 6)]);
    expect(checkpoint()['next_rollout_ordinal'], 9);
  });
  test('summary items use final answers and ignore nonterminal messages',() {
    store.append([started(),item('comment',type:'AgentMessage',extra:{'phase':'commentary'}),
      item('answer',type:'AgentMessage',extra:{'phase':'final_answer'}),completed()]);
    expect(db.select('SELECT final_agent_item_id FROM thread_turns').single['final_agent_item_id'],'answer');
  });
  test('list items pages whole thread and per-turn rows with exclusive anchors',() {
    store.append([started(),item('one'),item('two'),completed(),
      event('task_started',{'turn_id':'turn-2'}),event('item_completed',{'turn_id':'turn-2','item':{'type':'UserMessage','id':'three','content':<Object?>[]}})]);
    final first=store.items(limit:1).single;
    expect(first['item_id'],'one');
    expect(store.items(after:first['rollout_ordinal'] as int,limit:1).single['item_id'],'two');
    expect(store.items(turn:'turn-2').single['item_id'],'three');
  });
  test('incremental reads filter exclusive update ordinals across pages and turns',() {
    store.append([started(),item('one'),item('two')]);
    store.append([item('one',extra:{'client_id':'updated'})]);
    expect(store.items(updatedAfter:3).map((v)=>v['item_id']),['one']);
    expect(store.items(updatedAfter:4),isEmpty);
  });
  test('resumed recorder continues ordinals and preserves projected rows on reopen',() {
    store.append([started(),item('one')]);
    final before=checkpoint(); db.close();
    db=openTracedDatabase('${temp.path}/history.sqlite');store=CodexSqlite(db,'thread-1');
    store.append([item('two')]);
    expect(store.items().map((v)=>v['item_id']),['one','two']);
    expect(checkpoint()['next_rollout_ordinal'],(before['next_rollout_ordinal'] as int)+1);
  });
  test('paginated MCP history caps large results before persistence and projects the public payload shape',() {
    store.append([started(),event('item_completed',{'thread_id':'thread-1','item':{
      'type':'McpToolCall','id':'mcp-1','server':'test','tool':'large_result','arguments':{'query':'large result'},
      'status':'failed','result':{'content':[{'type':'text','text':'head\n${'x'*200000}\ntail'}],'isError':true},
      'duration':{'secs':0,'nanos':25000000},
    }})]);
    final projected=store.items().single['item'] as Json;
    expect(projected['type'],'mcpToolCall');expect(projected['durationMs'],25);
    expect(projected['result'].containsKey('isError'),false);
    final preview=projected['result']['content'][0]['text'] as String;
    expect(utf8.encode(preview).length,lessThan(65*1024));
    expect(preview,allOf(contains('head'),contains('chars truncated'),contains('tail')));
    final line=db.select("SELECT line FROM rollout_lines WHERE json_extract(line,'\$.payload.item.id') IS 'mcp-1'").single['line'] as String;
    expect(utf8.encode(line).length,lessThan(66*1024));
  });

  // Codex thread_history_materialization_tests.rs::paginated_command_history_caps_aggregated_output.
  test('paginated command history caps persisted output while preserving its public presentation', () {
    store.append([started(), item('exec-1', type: 'CommandExecution', extra: {
      'command': ['echo', 'hello'], 'cwd': '/workspace', 'parsed_cmd': [{'type': 'unknown', 'cmd': 'echo hello'}],
      'source': 'agent', 'status': 'completed', 'aggregated_output': 'head\n${'x' * (128 * 1024)}\ntail',
      'exit_code': 0, 'duration': {'secs': 0, 'nanos': 12000000},
    }), completed()]);
    final projected = store.items().single['item'] as Json;
    expect(projected['command'], 'echo hello'); expect(projected['durationMs'], 12);
    final output = projected['aggregatedOutput'] as String;
    expect(utf8.encode(output), hasLength(64 * 1024));
    expect(output, allOf(startsWith('head\n'), endsWith('\ntail'), contains('command output truncated for persistence')));
    final canonical = jsonDecode(db.select('SELECT line FROM rollout_lines WHERE ordinal IS 2').single['line'] as String);
    expect(canonical['payload']['item']['aggregated_output'], output);
  });

  // Canonical core -> app-server conversions in protocol/v2/item.rs. These
  // imported records must project successfully even if Happen cannot emit them.
  test('canonical native item variants retain the Codex public payloads on replay', () {
    final cases = <(Json, Json)>[
      ({'type': 'FunctionCallOutput', 'id': 'output', 'name': 'probe', 'namespace': 'tools', 'output': 'ok'},
        {'type': 'functionCallOutput', 'name': 'probe', 'namespace': 'tools', 'output': 'ok'}),
      ({'type': 'HookPrompt', 'id': 'hook', 'fragments': [{'text': 'policy', 'hookRunId': 'run'}]},
        {'type': 'hookPrompt', 'fragments': [{'text': 'policy', 'hookRunId': 'run'}]}),
      ({'type': 'Plan', 'id': 'plan', 'text': 'First inspect.'}, {'type': 'plan', 'text': 'First inspect.'}),
      ({'type': 'DynamicToolCall', 'id': 'dynamic', 'namespace': 'tools', 'tool': 'probe', 'arguments': {'x': 1},
        'status': 'completed', 'content_items': [{'type': 'inputText', 'text': 'ok'}, {'type': 'inputImage', 'imageUrl': 'data:image/png;base64,eA=='}],
        'success': true, 'duration': {'secs': 1, 'nanos': 25000000}},
        {'type': 'dynamicToolCall', 'durationMs': 1025, 'success': true,
          'contentItems': [{'type': 'inputText', 'text': 'ok'}, {'type': 'inputImage', 'imageUrl': 'data:image/png;base64,eA=='}]}),
      ({'type': 'CollabAgentToolCall', 'id': 'collab', 'tool': 'spawn_agent', 'status': 'completed',
        'sender_thread_id': 'root', 'receiver_thread_ids': ['child'], 'agents_states': {'child': 'running'}, 'reasoning_effort': 'high'},
        {'type': 'collabAgentToolCall', 'tool': 'spawnAgent', 'senderThreadId': 'root', 'receiverThreadIds': ['child'], 'reasoningEffort': 'high'}),
      ({'type': 'SubAgentActivity', 'id': 'subagent', 'kind': 'started', 'agent_thread_id': 'child', 'agent_path': '/root/child',
        'model': 'gpt-6.1-sol', 'reasoning_effort': 'high'},
        {'type': 'subAgentActivity', 'agentThreadId': 'child', 'agentPath': '/root/child', 'model': 'gpt-6.1-sol', 'reasoningEffort': 'high'}),
      ({'type': 'WebSearch', 'id': 'search', 'query': 'sqlite', 'action': {'type': 'search', 'query': 'sqlite'}, 'results': [{'url': 'https://sqlite.org'}]},
        {'type': 'webSearch', 'query': 'sqlite', 'action': {'type': 'search', 'query': 'sqlite'}, 'results': [{'url': 'https://sqlite.org'}]}),
      ({'type': 'ImageView', 'id': 'view', 'path': '/workspace/image.png'}, {'type': 'imageView', 'path': '/workspace/image.png'}),
      ({'type': 'ImageGeneration', 'id': 'hosted-image', 'status': 'completed', 'result': 'cG5n', 'saved_path': '/workspace/out.png'},
        {'type': 'imageGeneration', 'status': 'completed', 'result': 'cG5n', 'savedPath': '/workspace/out.png'}),
      ({'type': 'Extension', 'kind': 'clock.sleep', 'id': 'sleep', 'durationMs': 50}, {'type': 'sleep', 'durationMs': 50}),
      ({'type': 'Extension', 'kind': 'image_gen.generation', 'id': 'image', 'status': 'completed', 'fileId': 'image-file', 'revisedPrompt': 'blue'},
        {'type': 'imageGeneration', 'fileId': 'image-file', 'revisedPrompt': 'blue'}),
      ({'type': 'Extension', 'kind': 'web.search', 'id': 'extension-search', 'query': 'dart', 'results': [{'url': 'https://dart.dev'}]},
        {'type': 'webSearch', 'query': 'dart', 'results': [{'url': 'https://dart.dev'}]}),
      ({'type': 'EnteredReviewMode', 'id': 'review-start', 'target': {'type': 'uncommittedChanges'}, 'user_facing_hint': 'Review local changes'},
        {'type': 'enteredReviewMode', 'review': 'Review local changes'}),
      ({'type': 'ExitedReviewMode', 'id': 'review-end', 'review_output': {'findings': <Json>[], 'overall_explanation': 'Looks good.'}},
        {'type': 'exitedReviewMode', 'review': 'Looks good.'}),
      ({'type': 'FileChange', 'id': 'patch', 'status': 'completed', 'changes': {
        '/workspace/z': {'type': 'delete', 'content': 'old'}, '/workspace/a': {'type': 'add', 'content': 'new'},
      }}, {'type': 'fileChange', 'status': 'completed', 'changes': [
        {'path': '/workspace/a', 'kind': {'type': 'add'}, 'diff': 'new'},
        {'path': '/workspace/z', 'kind': {'type': 'delete'}, 'diff': 'old'},
      ]}),
    ];
    store.append([started(), for (final (canonical, _) in cases) event('item_completed', {'item': canonical}), completed()]);
    final projected = store.items();
    expect(projected, hasLength(cases.length));
    for (final (index, (canonical, expected)) in cases.indexed) {
      final actual = jsonObject(projected[index]['item']);
      expect(actual['id'], canonical['id']);
      for (final field in expected.entries) { expect(actual[field.key], field.value, reason: '${canonical['type']}.${field.key}'); }
    }
  });

  test('command presentation applies Codex secret redaction without bearer false positives', () {
    // secrets/src/sanitizer.rs and CommandExecutionPresentation::from_raw.
    final cases = <(String, String)>[
      ('Bearer abcde+fghijklmnopqrstuvwxyz012345', 'Bearer [REDACTED_SECRET]'),
      ('Bearer abcdefghijklmnop+secret_suffix', 'Bearer [REDACTED_SECRET]'),
      ('Bearer sk-abcdefghijklmnopqrst+secret_suffix', 'Bearer [REDACTED_SECRET]'),
      ('Bearer AKIAABCDEFGHIJKLMNOP/~secret_suffix', 'Bearer [REDACTED_SECRET]'),
      ('Bearer AbcdefghijklMN09._~+/-==; echo done', 'Bearer [REDACTED_SECRET]; echo done'),
      ('authorization: bEaReR\tabcdefghijklmnop', 'authorization: Bearer [REDACTED_SECRET]'),
      ('Bearer   abcdefghijklmnop', 'Bearer [REDACTED_SECRET]'),
      for (final text in ['Bearer of good news', 'Bearer abcdefghijklmno', 'NotABearer abcdefghijklmnop',
        'Bearerabcdefghijklmnop', 'Bearer\nabcdefghijklmnop', 'Bearer\u00a0abcdefghijklmnop', 'Bearer abcdefghijklmno\u212a']) (text, text),
      ('token=abcdefgh; echo sk-abcdefghijklmnopqrst AKIAABCDEFGHIJKLMNOP',
        'token=[REDACTED_SECRET] echo [REDACTED_SECRET] [REDACTED_SECRET]'),
    ];
    store.append([started(), for (final (index, (input, _)) in cases.indexed) item('command-$index', type: 'CommandExecution', extra: {
      'command': ['echo', input], 'cwd': '/workspace', 'parsed_cmd': [{'type': 'unknown', 'cmd': input}], 'source': 'agent', 'status': 'completed',
    })]);
    final projected = store.items();
    for (final (index, (_, expected)) in cases.indexed) {
      expect(projected[index]['item']['commandActions'][0]['command'], expected);
    }
  });
}
