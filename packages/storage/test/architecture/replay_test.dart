// Codex rollout/compression_tests.rs and thread-store/local/{rollout_lineage,
// thread_history_materialization}_tests.rs. Finite imports fail atomically on
// invalid data; live SQLite rows replace partial JSONL append semantics.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:protocol/protocol.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(() async { root = await Directory.systemTemp.createTemp('rollout-replay-matrix-'); });
  tearDown(() async { await root.delete(recursive: true); });
  List<Json> lines(int count) => [{'type': 'session_meta', 'payload': {'id': 'source', 'history_mode': 'paginated', 'model_provider': 'openai'}},
    for (var i = 0; i < count; i++) {'type': 'event_msg', 'payload': {'type': 'item_completed', 'turn_id': 'turn',
      'item': {'type': 'UserMessage', 'id': 'message-$i', 'content': [{'type': 'text', 'text': 'hello π $i'}]}}}];
  String encode(List<Json> rows, {bool ordinals = true}) => [for (final (i, row) in rows.indexed)
    jsonEncode({'timestamp': '2026-11-05T00:00:00Z', if (ordinals) 'ordinal': i, ...row})].join('\n');
  Future<String> load(File file, [String id = 'imported']) => TaskStore.importFrom(root.path, file.path, newTaskId: (_) async => id, cancellation: CancellationToken());
  void unpublished(String id) {
    expect(Directory('${root.path}/tasks/$id').existsSync(), false);
    expect(Directory('${root.path}/staging').listSync(), isEmpty);
  }

  for (final representation in ['plain', 'zstd', 'concatenated zstd']) {
    for (final ordinals in [true, false]) {
      test('standalone $representation import preserves complete Unicode records, explicit ordinals=$ordinals', () async {
        final text = utf8.encode(encode(lines(600), ordinals: ordinals));
        final bytes = representation == 'plain' ? text : representation == 'zstd' ? ZstdEncoder().encodeBytes(text, checksum: true)
          : [...ZstdEncoder().encodeBytes(text.sublist(0, text.length ~/ 2), checksum: true), ...ZstdEncoder().encodeBytes(text.sublist(text.length ~/ 2), checksum: true)];
        final file = await File('${root.path}/source.jsonl${representation == 'plain' ? '' : '.zst'}').writeAsBytes(bytes);
        final id = await load(file), store = TaskStore(root.path, id, create: false);
        try {
          expect(store.native.items(limit: 1000), hasLength(600));
          expect(store.db.select('SELECT next_rollout_ordinal FROM thread_history_projection_state').single.values.single, 601);
          expect(jsonDecode(store.db.select('SELECT line FROM rollout_lines ORDER BY ordinal LIMIT 1').single['line'] as String)['payload']['id'], id);
          await store.fork('child', cancellation: CancellationToken());
        } finally { store.close(); }
        expect(await file.readAsBytes(), bytes, reason: 'Import cannot materialize or rewrite its source.');
        expect((await readSession(root.path, 'child', 'thread/items/list', {'limit': 200}, cancellation: CancellationToken()))['data'], isNotEmpty);
      });
    }
  }
  for (final damage in ['truncated frame', 'checksum', 'trailing junk']) {
    test('compressed $damage is diagnosed before any imported session is published', () async {
      final bytes = ZstdEncoder().encodeBytes(utf8.encode(encode(lines(600))), checksum: true).toList();
      if (damage == 'truncated frame') bytes.removeRange(bytes.length - 3, bytes.length);
      if (damage == 'checksum') bytes[bytes.length - 1] ^= 1;
      if (damage == 'trailing junk') bytes.addAll([1, 2, 3]);
      final file = await File('${root.path}/bad.jsonl.zst').writeAsBytes(bytes);
      await expectLater(load(file), throwsA(isA<FormatException>().having((e) => e.message, 'specific compression error', contains('compressed rollout'))));
      unpublished('imported'); expect(await file.readAsBytes(), bytes);
    });
  }
  for (final suffix in ['{"timestamp":', '\nnot-json\n', '\n{"ordinal":601,"timestamp":"now","type":"unknown","payload":{}}']) {
    test('finite import rejects incomplete/invalid suffix after committed batches: $suffix', () async {
      final text = '${encode(lines(600))}\n$suffix'; final file = await File('${root.path}/partial.jsonl').writeAsString(text);
      await expectLater(load(file), throwsA(isA<FormatException>())); unpublished('imported'); expect(await file.readAsString(), text);
    });
  }

  for (final stop in ['cancel', 'close']) {
    test('projection $stop retains committed progress and resumes without replaying its prefix', () async {
      final store = TaskStore(root.path, 'thread');
      final rows = lines(4096); rows.first['payload']['id'] = 'thread';
      store.native.record(rows); store.close();
      var owner = await startStore(root.path, 'thread', create: false);
      final tracePort = ReceivePort(), cancellation = CancellationToken(), progress = Completer<void>();
      var stopped = false;
      Future<void>? closing;
      final subscription = tracePort.listen((raw) {
        if (stopped || jsonObject(raw)['event']?['name'] != 'sqlite.commit') return;
        final reader = sqlite3.open('${root.path}/tasks/thread/history.sqlite', mode: OpenMode.readOnly);
        try {
          if ((reader.select('SELECT count(*) AS n FROM thread_items').single['n'] as int) == 0) return;
        } finally { reader.close(); }
        stopped = true; if (stop == 'close') closing = owner.close(); else cancellation.cancel(); progress.complete();
      });
      try {
        final work = withTrace(TraceContext(sink: tracePort.sendPort, service: 'storage'), () => callIsolate(owner.port, 'session.prepare', {}, cancellation: cancellation));
        unawaited(work.then<void>((_) {}, onError: (Object _) {})); await progress.future.timeout(const Duration(seconds: 10));
        if (closing != null) await closing; else { try { await work; } on CancelledException { /* Expected stop. */ } await owner.close(); }
        final offline = TaskStore(root.path, 'thread', create: false);
        final committed = offline.db.select('SELECT next_rollout_ordinal FROM thread_history_projection_state').single.values.single as int;
        expect(committed, inExclusiveRange(0, 4097), reason: 'Cancellation must be observed between bounded projection batches.');
        offline.db.execute("CREATE TRIGGER no_replay BEFORE INSERT ON thread_items WHEN CAST(substr(NEW.item_id,9) AS INTEGER) < ${committed - 1} BEGIN SELECT RAISE(ABORT,'replayed prefix'); END");
        offline.close();
        owner = await startStore(root.path, 'thread', create: false);
        await callIsolate(owner.port, 'session.prepare', {}, cancellation: CancellationToken()); await owner.close();
        final reader = sqlite3.open('${root.path}/tasks/thread/history.sqlite', mode: OpenMode.readOnly);
        try { expect(reader.select('SELECT count(*) AS n FROM thread_items').single['n'], 4096); }
        finally { reader.close(); }
      } finally { cancellation.cancel(); await owner.close(); await subscription.cancel(); tracePort.close(); }
    });
  }
}
