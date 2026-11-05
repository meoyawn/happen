// Contract ports: Codex thread-store/local/paginated_fork.rs,
// rollout_lineage_tests.rs, archive_thread.rs, unarchive_thread.rs;
// app-server/tests/suite/v2/thread_fork.rs (paginated cases only).
import 'dart:convert';
import 'dart:io';

import 'package:ai/ai.dart';
import 'package:openai/openai.dart' show gptInput;
import 'package:protocol/protocol.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late TaskStore parent;
  final cancellation = CancellationToken();
  setUp(() {
    root = Directory.systemTemp.createTempSync('codex-lineage-');
    parent = TaskStore(root.path, 'parent');
    final config = {'cwd': root.path, 'provider': 'openai', 'model': 'fixture', 'provider_settings': {'reasoning': 'high'}};
    parent.append('task.created', config, metadata: {'config': config, 'title': 'Private name'});
  });
  tearDown(() { parent.close(); root.deleteSync(recursive: true); });
  void turn(TaskStore store, String id, String prompt) {
    store.append('turn.started', {'turnId': id});
    store.append('input.committed', {'message_id': 'input-$id', 'item': ConversationItem.user(prompt).toJson()});
    store.append('turn.completed', {});
  }
  Future<Json> read(String id, [String method = 'thread/read', Json params = const {}]) =>
    readSession(root.path, id, method, {'includeTurns': true, ...params}, cancellation: cancellation);
  List<String> turnIds(Json page) => (jsonObject(page['thread'])['turns'] as List).map(jsonObject).map((turn) => turn['id'] as String).toList();

  test('reference-backed paginated fork shares the immutable prefix without copying history', () async {
    turn(parent, 'one', 'Saved user message');
    final original = parent.db.select('SELECT line FROM rollout_lines').map((r) => r['line']).toList();
    await parent.fork('child', cancellation: cancellation);
    final child = TaskStore(root.path, 'child', create: false);
    try {
      final meta = jsonDecode(child.db.select('SELECT line FROM rollout_lines ORDER BY ordinal LIMIT 1').single['line'] as String)['payload'];
      expect(meta['history_base']['thread_id'], 'parent');
      expect(meta['history_base']['end_ordinal_exclusive'], parent.native.nextOrdinal);
      expect(child.db.select('SELECT line FROM rollout_lines').map((r) => r['line']).join(), isNot(contains('Saved user message')));
      expect(child.modelContext().map((item) => item['content'][0]['text']), ['Saved user message']);
      final info = (await read('child'))['thread'];
      expect(info['id'], 'child'); expect(info['sessionId'], 'child');
      expect(info['name'], isNull); expect(info['forkedFromId'], 'parent');
      expect(info['historyMode'], 'paginated'); expect(info['preview'], 'Saved user message');
      expect(turnIds(await read('child')), ['one']);
      turn(parent, 'two', 'Must not leak into child');
      turn(child, 'private', 'Continue from the fork');
      expect(child.modelContext().map((item) => item['content'][0]['text']), ['Saved user message', 'Continue from the fork']);
      expect(turnIds(await read('child')), ['one', 'private']);
      expect(parent.db.select('SELECT line FROM rollout_lines').take(original.length).map((r) => r['line']), original);
      await child.fork('nested', cancellation: cancellation);
    } finally { child.close(); }
    expect(turnIds(await read('nested')), ['one', 'private']);
    final sqliteFiles = root.listSync(recursive: true).whereType<File>().where((file) => file.path.endsWith('.sqlite'));
    expect(sqliteFiles.map((file) => file.path.split('/').last), everyElement('history.sqlite'));
    expect(sqliteFiles, hasLength(3));
  });

  test('named boundaries select only the terminal prefix, including inherited turns', () async {
    for (final id in ['one', 'two', 'three']) { turn(parent, id, id); }
    await parent.fork('through', lastTurnId: 'two', cancellation: cancellation);
    await parent.fork('before', beforeTurnId: 'three', cancellation: cancellation);
    expect(turnIds(await read('through')), ['one', 'two']);
    expect(turnIds(await read('before')), ['one', 'two']);
    final through = TaskStore(root.path, 'through', create: false);
    try { await through.fork('inherited', beforeTurnId: 'two', cancellation: cancellation); }
    finally { through.close(); }
    expect(turnIds(await read('inherited')), ['one']);
    parent.append('turn.started', {'turnId': 'active'});
    await expectLater(parent.fork('invalid', lastTurnId: 'active', cancellation: cancellation), throwsStateError);
    await expectLater(parent.fork('missing', lastTurnId: 'absent', cancellation: cancellation), throwsStateError);
    expect(Directory('${root.path}/tasks/invalid').existsSync(), false);
  });

  test('ephemeral side SQLite shares the canonical fork prefix and stores only its private suffix', () async {
    for (var index = 0; index < 100; index++) { turn(parent, 'turn-$index', 'Reference history $index'); }
    await parent.fork('fork-parent', cancellation: cancellation);
    final source = TaskStore(root.path, 'fork-parent', create: false);
    final side = TaskStore(root.path, 'side', inMemory: true);
    var parentCommits = 0;
    source.db.raw.commitFilter = () { parentCommits++; return true; };
    try {
      final snapshot = source.forkSnapshot();
      expect(snapshot.containsKey('input'), false, reason: 'A fork captures an immutable bookmark, never a serialized prefix.');
      side.initializeFork({...snapshot, 'config': {...jsonObject(snapshot['config']), 'ephemeral': true, 'side_parent_id': 'fork-parent'}});
      expect(side.db.select('PRAGMA database_list').single['file'], '');
      expect(side.db.select('SELECT * FROM rollout_lines'), hasLength(1));
      expect(side.metadata('fork_input'), isNull);
      final header = jsonDecode(side.db.select('SELECT line FROM rollout_lines').single['line'] as String)['payload'];
      expect(header['history_base']['thread_id'], 'fork-parent');
      expect(header['history_base']['end_ordinal_exclusive'], source.native.nextOrdinal);
      expect(side.modelContext(), hasLength(100));
      turn(source, 'later', 'New parent work stays out of the side');
      parentCommits = 0;
      turn(side, 'private', 'Side question');
      final context = side.modelContext();
      expect(context, hasLength(101)); expect(jsonEncode(context), isNot(contains('New parent work')));
      expect(jsonEncode(source.modelContext()), isNot(contains('Side question')));
      expect(parentCommits, 0, reason: 'Opening and using a side never writes to its parent.');
      expect(Directory('${root.path}/tasks/side').existsSync(), false);
    } finally { side.close(); source.close(); }
  });

  test('latest fork of an active turn records a child interruption without changing the parent', () async {
    parent.append('turn.started', {'turnId': 'active'});
    parent.append('input.committed', {'item': ConversationItem.user('In progress').toJson()});
    await parent.fork('active-child', cancellation: cancellation);
    parent.append('turn.completed', {});
    final child = (await read('active-child'))['thread'];
    expect(child['turns'].single['id'], 'active');
    expect(child['turns'].single['status'], 'interrupted');
    expect((await read('parent'))['thread']['turns'].single['status'], 'completed');
  });

  test('archive and unarchive preserve shared ancestors, recency, and the canonical rollout', () async {
    turn(parent, 'one', 'Archived user message');
    await parent.fork('child', cancellation: cancellation);
    final original = parent.db.select('SELECT line FROM rollout_lines').map((r) => r['line']).toList();
    final recency = parent.modelSnapshot()['updated'];
    parent.archive(true);
    expect(parent.metadata('archived_at'), isA<String>());
    expect((await read('parent'))['archived'], true);
    expect(turnIds(await read('child')), ['one']);
    expect(parent.db.select('SELECT line FROM rollout_lines').map((r) => r['line']), original);
    parent.archive(false);
    expect(parent.metadata('archived_at'), isNull);
    expect(parent.modelSnapshot()['updated'], recency);
    expect((await read('parent'))['thread']['preview'], 'Archived user message');
    expect(Directory('${root.path}/tasks/parent').listSync().whereType<File>().where((f) => f.path.endsWith('.sqlite')), hasLength(1));
  });

  test('archive without turns does not invent a turn or depend on history materialization', () async {
    parent.db.execute("CREATE TRIGGER broken BEFORE INSERT ON thread_turns BEGIN SELECT RAISE(ABORT,'broken view'); END");
    parent.archive(true);
    expect((await read('parent'))['thread']['turns'], isEmpty);
    parent.archive(false);
    expect(parent.metadata('archived_at'), isNull);
  });

  test('portable rollout import restores canonical items and publishes only a complete validated session', () async {
    turn(parent, 'one', 'Imported message');
    parent.keyValue('set', {'key': 'sum', 'value': 42});
    await parent.fork('child', cancellation: cancellation);
    final child = TaskStore(root.path, 'child', create: false);
    final path = '${root.path}/rollout.jsonl';
    try {
      expect(child.keyValue('get', {'key': 'sum'}), 42);
      child.keyValue('set', {'key': 'sum', 'value': 43});
      await child.exportTo(path, cancellation: cancellation);
    }
    finally { child.close(); }
    final imported = await TaskStore.importFrom(root.path, path, newTaskId: (_) async => 'imported', cancellation: cancellation);
    expect(imported, 'imported');
    expect(turnIds(await read(imported)), ['one']);
    final restored = TaskStore(root.path, imported, create: false);
    try {
      expect(restored.modelContext().map((item) => item['content'][0]['text']), ['Imported message']);
      expect(restored.keyValue('get', {'key': 'sum'}), 43);
      expect(parent.keyValue('get', {'key': 'sum'}), 42);
      final rows = restored.db.select('SELECT * FROM rollout_lines ORDER BY ordinal');
      var offset = 0;
      for (final row in rows) {
        expect(row['byte_offset'], offset);
        final length = utf8.encode(row['line'] as String).length + 1;
        expect(row['byte_length'], length);
        offset += length;
      }
      await restored.fork('import-fork', cancellation: cancellation);
      expect(turnIds(await read('import-fork')), ['one']);
    }
    finally { restored.close(); }
    await File(path).writeAsString('{invalid\n', mode: FileMode.append);
    await expectLater(TaskStore.importFrom(root.path, path, newTaskId: (_) async => 'bad', cancellation: cancellation), throwsA(isA<FormatException>()));
    expect(Directory('${root.path}/tasks/bad').existsSync(), false);
  });

  test('native Codex imports reconstruct compacted response history without Happen extensions', () async {
    // Model-context contracts from Codex thread-store/local/model_context_tests.rs:
    // replacement history is authoritative; the later suffix stays in order.
    const summary = {'type': 'message', 'id': 'summary', 'role': 'user',
      'content': [{'type': 'input_text', 'text': 'Checkpoint of earlier work'}]};
    const responses = <Json>[
      {'type': 'function_call', 'id': 'fc_read', 'call_id': 'read', 'name': 'exec_command', 'arguments': '{"cmd":"pwd"}'},
      {'type': 'function_call_output', 'id': 'fco_read', 'call_id': 'read', 'output': '/workspace'},
      {'type': 'reasoning', 'id': 'rs_saved', 'summary': <Object?>[], 'encrypted_content': 'opaque-state'},
      {'type': 'message', 'id': 'answer', 'role': 'assistant', 'phase': 'final_answer',
        'content': [{'type': 'output_text', 'text': 'Ready ✓'}]},
    ];
    final lines = <Json>[
      {'type': 'session_meta', 'payload': {'id': 'upstream', 'cwd': root.path, 'model_provider': 'openai', 'history_mode': 'paginated'}},
      {'type': 'response_item', 'payload': {'type': 'message', 'role': 'user', 'content': [{'type': 'input_text', 'text': 'Obsolete context'}]}},
      {'type': 'compacted', 'payload': {'message': 'Checkpoint', 'replacement_history': [summary], 'window_number': 1}},
      {'type': 'turn_context', 'payload': {'turn_id': 'resume', 'model': 'fixture', 'effort': 'high', 'cwd': root.path}},
      for (final response in responses) {'type': 'response_item', 'payload': response},
    ];
    final path = File('${root.path}/upstream.jsonl');
    await path.writeAsString([for (final (ordinal, line) in lines.indexed)
      jsonEncode({'timestamp': '2026-01-01T00:00:00Z', 'ordinal': ordinal, ...line})].join('\n'));
    final id = await TaskStore.importFrom(root.path, path.path, newTaskId: (_) async => 'native-copy', cancellation: cancellation);
    final restored = TaskStore(root.path, id, create: false);
    try {
      final input = gptInput(restored.modelContext().map(ConversationItem.fromJson));
      expect(input, [summary, ...responses]);
      expect(restored.metadata('effective_reasoning'), 'high');
      expect((restored.metadata('config') as Map)['model'], 'fixture');
      await restored.fork('native-fork', cancellation: cancellation);
    } finally { restored.close(); }
    final fork = TaskStore(root.path, 'native-fork', create: false);
    try { expect(gptInput(fork.modelContext().map(ConversationItem.fromJson)), [summary, ...responses]); }
    finally { fork.close(); }
  });

  for (final corruption in ['missing ancestor', 'cycle', 'byte cutoff', 'ordinal cutoff', 'escaped symlink', 'wrong ancestor identity']) {
    test('cold lineage read rejects $corruption rather than exposing an unrelated prefix', () async {
      turn(parent, 'one', 'Private ancestor message'); await parent.fork('child', cancellation: cancellation);
      final child = TaskStore(root.path, 'child', create: false);
      try {
        final row = child.db.select('SELECT line FROM rollout_lines ORDER BY ordinal LIMIT 1').single;
        final header = jsonObject(jsonDecode(row['line'] as String)), payload = jsonObject(header['payload']);
        final base = jsonObject(payload['history_base']);
        switch (corruption) {
          case 'cycle':
            final end = child.db.select('SELECT ordinal,byte_offset+byte_length AS end FROM rollout_lines ORDER BY ordinal DESC LIMIT 1').single;
            base.addAll({'thread_id': 'child', 'end_ordinal_exclusive': (end['ordinal'] as int) + 1, 'end_byte_offset': end['end']});
          case 'byte cutoff': base['end_byte_offset'] = (base['end_byte_offset'] as int) + 1;
          case 'ordinal cutoff': base['end_ordinal_exclusive'] = (base['end_ordinal_exclusive'] as int) + 1;
          case 'wrong ancestor identity':
            final source = jsonObject(jsonDecode(parent.db.select('SELECT line FROM rollout_lines ORDER BY ordinal LIMIT 1').single['line'] as String));
            source['payload'] = {...jsonObject(source['payload']), 'id': 'someone-else'};
            parent.db.execute('UPDATE rollout_lines SET line=? WHERE ordinal IS 0', [jsonEncode(source)]);
          default: break;
        }
        payload['history_base'] = base; header['payload'] = payload;
        child.db.execute('UPDATE rollout_lines SET line=?', [jsonEncode(header)]);
      } finally { child.close(); }
      parent.close();
      if (corruption == 'missing ancestor' || corruption == 'escaped symlink') {
        await Directory('${root.path}/tasks/parent').rename('${root.path}/external-parent');
        if (corruption == 'escaped symlink') await Link('${root.path}/tasks/parent').create('${root.path}/external-parent');
      }
      await expectLater(read('child'), throwsA(isA<FormatException>()));
    });
  }

  test('relocated data home preserves separate workspace cwd and read-only SQLite lineage replay', () async {
    turn(parent, 'one', 'Retained message'); await parent.fork('child', cancellation: cancellation);
    final child = TaskStore(root.path, 'child', create: false);
    try { turn(child, 'two', 'Child suffix'); await child.fork('nested', cancellation: cancellation); }
    finally { child.close(); }
    parent.archive(true); parent.close();
    final home = await Directory('${root.path}/separate-data-home').create();
    await Directory('${root.path}/tasks').rename('${home.path}/tasks');
    final page = await readSession(home.path, 'nested', 'thread/read', {'includeTurns': true}, cancellation: cancellation);
    expect(turnIds(page), ['one', 'two']); expect(page['thread']['cwd'], root.path);
    final moved = TaskStore(home.path, 'nested', create: false);
    try { expect(moved.modelContext().map((i) => i['content'][0]['text']), ['Retained message', 'Child suffix']); }
    finally { moved.close(); }
    expect(home.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.sqlite')), hasLength(3));
    expect(await Directory('${root.path}/tasks').exists(), false);
  });
}
