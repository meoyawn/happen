import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'server.dart';

// Like Codex's PID backend: one daemon per data directory, independent of SSH
// sessions. Linux boot ID + /proc start ticks distinguish PID reuse and reboot.
Future<String?> _identity(int processId) async {
  try {
    final stat = await File('/proc/$processId/stat').readAsString();
    final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
    if (fields[0] == 'Z') return null;
    return '${(await File('/proc/sys/kernel/random/boot_id').readAsString()).trim()}:${fields[19]}';
  } on FileSystemException catch (error) {
    if (error.osError?.errorCode == 2 || error.osError?.errorCode == 3) return null;
    rethrow;
  }
}

Future<Json?> _running(String directory) async {
  final file = File('$directory/daemon.json');
  if (!await file.exists()) return null;
  final record = jsonObject(jsonDecode(await file.readAsString()));
  final processId = record['pid'];
  if (processId is! int || processId < 2 || record['identity'] is! String) {
    throw StateError('Invalid daemon identity record; refusing to signal it');
  }
  return await _identity(processId) == record['identity'] ? record : null;
}

Future<bool> _ready(String socket, CancellationToken cancellation) async {
  final http = HttpClient()..findProxy = (_) => 'DIRECT';
  http.connectionFactory = (_, _, _) => Socket.startConnect(InternetAddress(socket, type: InternetAddressType.unix), 0);
  final deadline = TimeoutCancellationToken(const Duration(seconds: 2));
  final token = cancellation.merge(deadline);
  final hook = CancellationHook(token, () => http.close(force: true));
  try {
    final response = await (await http.getUrl(Uri.parse('http://localhost/readyz')).asCancellable(token)).close().asCancellable(token);
    await response.drain<void>().asCancellable(token);
    return response.statusCode == 200;
  } on CancelledException { cancellation.throwIfCancelled(); return false; }
  on SocketException { return false; }
  on HttpException { return false; }
  finally { hook.dispose(); deadline.cancel(); http.close(force: true); }
}

String _quote(String value) => "'${value.replaceAll("'", "'\\''")}'";

Future<void> _chmod(String path, String mode) async {
  final result = await Process.run('chmod', [mode, path]);
  if (result.exitCode != 0) throw FileSystemException('Cannot protect daemon files', path);
}

Future<void> _stop(String directory, Json? record, CancellationToken cancellation) async {
  if (record == null) return;
  // Recheck immediately before every signal, including a forced shutdown.
  if (await _identity(record['pid'] as int) != record['identity']) return;
  Process.killPid(record['pid'] as int, ProcessSignal.sigterm);
  for (var attempt = 0; attempt < 300; attempt++) {
    cancellation.throwIfCancelled();
    if (await _identity(record['pid'] as int) != record['identity']) return;
    await cancellableDelay(const Duration(milliseconds: 100), cancellation);
  }
  // Do not force-kill the daemon during a persistence commit.
  throw StateError('Daemon did not stop within 30 seconds; deployment has not started another daemon');
}

Future<Json> daemonCommand(String action, String directory, {
  String? configPath, required CancellationToken cancellation,
}) async {
  if (!Platform.isLinux) throw UnsupportedError('The managed server daemon targets Linux');
  if (!{'start', 'status', 'stop', 'restart'}.contains(action)) throw ArgumentError('Unknown daemon command');
  await Directory(directory).create(recursive: true);
  await _chmod(directory, '700');
  final socket = '$directory/server.sock';
  if (utf8.encode(socket).length > 100) throw ArgumentError('Data directory is too long for a Unix socket');
  final lock = await File('$directory/daemon.lock').open(mode: FileMode.append);
  var locked = false;
  try {
    // Nonblocking attempts allow caller cancellation while another CLI owns it.
    while (!locked) {
      cancellation.throwIfCancelled();
      try { await lock.lock(FileLock.exclusive); locked = true; }
      on FileSystemException { await cancellableDelay(const Duration(milliseconds: 100), cancellation); }
    }
    var record = await _running(directory);
    if (action == 'status') {
      return {'backend': 'pid', 'status': record == null ? 'stopped'
        : await _ready(socket, cancellation) ? 'running' : 'unhealthy', ...?record};
    }
    if (action == 'stop' || action == 'restart') {
      await _stop(directory, record, cancellation);
      record = null;
      if (action == 'stop') return {'backend': 'pid', 'status': 'stopped'};
    }
    if (record != null) {
      if (!await _ready(socket, cancellation)) throw StateError('Daemon exists but is not ready; use daemon restart');
      return {'backend': 'pid', 'status': 'alreadyRunning', ...record};
    }
    // Only remove a stale socket after proving the recorded owner is gone.
    if (await FileSystemEntity.type(socket, followLinks: false) != FileSystemEntityType.notFound) await File(socket).delete();
    final executable = Platform.resolvedExecutable;
    final command = [executable,
      if (executable.split('/').last == 'dart') Platform.script.toFilePath(),
      '_serve', '--data-dir', directory, if (configPath != null) ...['--config', File(configPath).absolute.path]];
    final log = File('$directory/daemon.log');
    if (await log.exists() && await log.length() > 8 * 1024 * 1024) await log.rename('${log.path}.previous');
    await log.open(mode: FileMode.append).then((file) => file.close());
    await _chmod(log.path, '600');
    final child = await Process.start('/bin/sh', ['-c', 'exec ${command.map(_quote).join(' ')} >> ${_quote(log.path)} 2>&1'],
      workingDirectory: Platform.environment['HOME'] ?? '/', mode: ProcessStartMode.detached);
    // The child publishes its identity only after the listener is accepting.
    for (var attempt = 0; attempt < 300; attempt++) {
      cancellation.throwIfCancelled();
      record = await _running(directory);
      if (record != null && record['pid'] == child.pid && await _ready(socket, cancellation)) {
        return {'backend': 'pid', 'status': action == 'restart' ? 'restarted' : 'started', ...record};
      }
      if (attempt > 5 && await _identity(child.pid) == null) break;
      await cancellableDelay(const Duration(milliseconds: 100), cancellation);
    }
    throw StateError('Daemon startup failed; see ${log.path}');
  } finally {
    if (locked) await lock.unlock();
    await lock.close();
  }
}

Future<void> serveDaemon(String directory, {String? configPath, required CancellationToken cancellation}) async {
  final identity = await _identity(pid);
  if (identity == null) throw StateError('Cannot identify the daemon process');
  final recordFile = File('$directory/daemon.json');
  // A second foreground launch must not replace an active daemon's record.
  final serving = await File('$directory/serving.lock').open(mode: FileMode.append);
  await serving.lock(FileLock.exclusive);
  AgentServer? server;
  try {
    server = await AgentServer.start(directory: directory, socketPath: '$directory/server.sock', configPath: configPath);
    final record = {'pid': pid, 'identity': identity, 'socketPath': '$directory/server.sock',
      'version': '0.1.0', 'executable': Platform.resolvedExecutable, 'cwd': Platform.environment['HOME'] ?? '/',
      'startedAt': DateTime.now().toUtc().toIso8601String()};
    final pending = File('${recordFile.path}.pending');
    await pending.writeAsString(jsonEncode(record), flush: true);
    await _chmod(pending.path, '600');
    await pending.rename(recordFile.path);
    final stopped = Completer<void>();
    final hook = CancellationHook(cancellation, () { if (!stopped.isCompleted) stopped.complete(); });
    try { await stopped.future; } finally { hook.dispose(); }
  } finally {
    await server?.close();
    if (await recordFile.exists()) {
      final current = jsonObject(jsonDecode(await recordFile.readAsString()));
      if (current['pid'] == pid && current['identity'] == identity) await recordFile.delete();
    }
    await serving.unlock();
    await serving.close();
  }
}
