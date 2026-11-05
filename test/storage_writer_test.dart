// Kernel writer ownership, independent of the initiating isolate's registry.
// All probes use real SQLite files; none replaces the writer/lock implementation.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:protocol/protocol.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

bool competingWriter(String directory) {
  TaskStore? admitted;
  try { admitted = TaskStore(directory, 'thread', create: false); return true; }
  on FileSystemException catch (error) { if (![11, 13, 35].contains(error.osError?.errorCode)) rethrow; return false; }
  on StateError catch (error) { if (!error.message.contains('active writer')) rethrow; return false; }
  finally { admitted?.close(); }
}
Future<bool> isolatedWriterProbe(String directory) => Isolate.run(() => competingWriter(directory));

void main() {
  late Directory root;
  TaskStore? owner;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('single-writer-');
    owner = TaskStore(root.path, 'thread');
    owner!.append('task.created', {'cwd': root.path}, metadata: {'config': {'cwd': root.path, 'provider': 'openai', 'model': 'owner-proof'}});
  });
  tearDown(() async { owner?.close(); owner = null; await root.delete(recursive: true); });
  Future<Json> remote(String mode) async {
    final process = await Process.start(Platform.resolvedExecutable, ['run', 'test/fixtures/storage_writer.dart', root.path, mode]);
    final token = TimeoutCancellationToken(const Duration(seconds: 30));
    final cancellation = CancellationHook(token, () => process.kill(ProcessSignal.sigkill));
    try {
      final out = utf8.decoder.bind(process.stdout).join(), err = utf8.decoder.bind(process.stderr).join();
      expect(await process.exitCode.asCancellable(token), 0, reason: await err);
      final lines = const LineSplitter().convert(await out).where((line) => line.startsWith('{'));
      return jsonObject(jsonDecode(lines.single));
    } finally { cancellation.dispose(); token.cancel(); process.kill(ProcessSignal.sigkill); await process.exitCode; }
  }

  for (final mode in ['same isolate', 'another isolate', 'symlink alias']) {
    test('one saved session rejects a second writer from $mode', () async {
      var directory = root.path;
      if (mode == 'symlink alias') {
        final alias = '${root.path}/alias'; await Link(alias).create(root.path); directory = alias;
      }
      final admitted = mode == 'another isolate' ? await isolatedWriterProbe(directory) : competingWriter(directory);
      expect(admitted, false);
      expect(jsonObject(owner!.metadata('config'))['model'], 'owner-proof');
    });
  }

  test('a rejected local acquisition never releases the live writer against another process', () async {
    final before = await remote('probe'), local = competingWriter(root.path), after = await remote('probe');
    expect({'before': before['admitted'], 'local': local, 'after': after['admitted']}, {'before': false, 'local': false, 'after': false});
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('one writer permits concurrent read-only snapshots while its ordinary WAL transaction is active', () async {
    owner!.db.execute('BEGIN IMMEDIATE');
    owner!.db.execute("INSERT INTO kv VALUES ('uncommitted','1',1,1)");
    final token = TimeoutCancellationToken(const Duration(seconds: 5));
    try {
      final page = await readSession(root.path, 'thread', 'thread/read', {}, cancellation: token);
      final list = await listThreads(root.path, {}, cancellation: token);
      expect(page['thread']['id'], 'thread'); expect(list['data'].single['id'], 'thread');
      expect(competingWriter(root.path), false);
    } finally { token.cancel(); owner!.db.execute('ROLLBACK'); }
  });

  test('failed writer initialization closes its SQLite connection before releasing ownership', () async {
    final result = await remote('failed-init');
    expect(result, {'initializationRejected': true, 'connectionReleased': true});
  }, timeout: const Timeout(Duration(seconds: 45)));

  test('process death releases the writer lease and the next owner opens the same durable file', () async {
    owner!.close(); owner = null;
    final process = await Process.start(Platform.resolvedExecutable, ['run', 'test/fixtures/storage_writer.dart', root.path, 'hold']);
    final ready = Completer<Json>();
    final output = utf8.decoder.bind(process.stdout).transform(const LineSplitter()).listen((line) {
      if (line.startsWith('{') && !ready.isCompleted) ready.complete(jsonObject(jsonDecode(line)));
    });
    final errors = process.stderr.drain<void>();
    int? child;
    try {
      final report = await ready.future.timeout(const Duration(seconds: 25)); child = report['pid'] as int;
      expect(child, greaterThan(1)); expect(child, isNot(pid)); expect(report['admitted'], true);
      expect(competingWriter(root.path), false);
      Process.killPid(child, ProcessSignal.sigkill); await process.exitCode;
      owner = TaskStore(root.path, 'thread', create: false); expect(jsonObject(owner!.metadata('config'))['model'], 'owner-proof');
    } finally {
      if (child != null && child > 1 && child != pid) Process.killPid(child, ProcessSignal.sigkill);
      process.kill(ProcessSignal.sigkill); await process.exitCode; await output.cancel(); await errors;
    }
  }, timeout: const Timeout(Duration(seconds: 45)));
}
