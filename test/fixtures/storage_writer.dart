import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:storage/storage.dart';

Future<void> main(List<String> arguments) async {
  final root = arguments[0], mode = arguments[1];
  if (mode == 'failed-init') {
    await Directory('$root/tasks/broken').create(recursive: true);
    final path = '$root/tasks/broken/history.sqlite', broken = sqlite3.open('$root/tasks/broken/history.sqlite');
    broken.execute('PRAGMA journal_mode=WAL'); broken.execute('CREATE TABLE happen_runtime(wrong_column TEXT)'); broken.close();
    var rejected = false;
    try { TaskStore(root, 'broken', create: false).close(); } on SqliteException { rejected = true; }
    final independent = sqlite3.open(path);
    try { independent.execute('CREATE TABLE after_failed_initialization(value TEXT)'); }
    finally { independent.close(); }
    stdout.writeln(jsonEncode({'initializationRejected': rejected, 'connectionReleased': true})); return;
  }
  TaskStore? store;
  try { store = TaskStore(root, 'thread', create: false); }
  on FileSystemException catch (error) { if (![11, 13, 35].contains(error.osError?.errorCode)) rethrow; }
  on StateError catch (error) { if (!error.message.contains('active writer')) rethrow; }
  stdout.writeln(jsonEncode({'admitted': store != null, 'pid': pid}));
  if (store != null && mode == 'hold') {
    final lifetime = TimeoutCancellationToken(const Duration(seconds: 30));
    final input = stdin.listen((_) => lifetime.cancel());
    try { await Completer<void>().future.asCancellable(lifetime); }
    on CancelledException { /* Explicit owner release or independent bound. */ }
    finally { await input.cancel(); lifetime.cancel(); store.close(); }
  } else { store?.close(); }
}
