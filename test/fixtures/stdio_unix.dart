// Independent native fixture/oracle. In particular this launcher intentionally
// inherits unrelated descriptors, unlike the MCP launcher being tested.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:protocol/protocol.dart';

final libc = DynamicLibrary.process();
final getpgid = libc.lookupFunction<Int32 Function(Int32), int Function(int)>('getpgid');
final setsid = libc.lookupFunction<Int32 Function(), int Function()>('setsid');
final kill = libc.lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>('kill');
final closeFd = libc.lookupFunction<Int32 Function(Int32), int Function(int)>('close');
final _fcntl = libc.lookupFunction<Int32 Function(Int32, Int32, VarArgs<(Int32,)>), int Function(int, int, int)>('fcntl');
final _open = libc.lookupFunction<Int32 Function(Pointer<Utf8>, Int32, VarArgs<(Uint32,)>), int Function(Pointer<Utf8>, int, int)>('open');
final _write = libc.lookupFunction<IntPtr Function(Int32, Pointer<Uint8>, IntPtr), int Function(int, Pointer<Uint8>, int)>('write');
final _spawn = libc.lookupFunction<Int32 Function(Pointer<Int32>, Pointer<Utf8>, Pointer<Void>, Pointer<Void>, Pointer<Pointer<Utf8>>, Pointer<Pointer<Utf8>>),
  int Function(Pointer<Int32>, Pointer<Utf8>, Pointer<Void>, Pointer<Void>, Pointer<Pointer<Utf8>>, Pointer<Pointer<Utf8>>)>('posix_spawn');
final _actionsInit = libc.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('posix_spawn_file_actions_init');
final _actionsDestroy = libc.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('posix_spawn_file_actions_destroy');
final _dup = libc.lookupFunction<Int32 Function(Pointer<Void>, Int32, Int32), int Function(Pointer<Void>, int, int)>('posix_spawn_file_actions_adddup2');
final _waitpid = libc.lookupFunction<Int32 Function(Int32, Pointer<Int32>, Int32), int Function(int, Pointer<Int32>, int)>('waitpid');
final _opendir = libc.lookupFunction<Pointer<Void> Function(Pointer<Utf8>), Pointer<Void> Function(Pointer<Utf8>)>('opendir');
final _readdir = libc.lookupFunction<Pointer<Void> Function(Pointer<Void>), Pointer<Void> Function(Pointer<Void>)>('readdir');
final _closedir = libc.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('closedir');

int fdFlags(int descriptor) => _fcntl(descriptor, 1, 0); // F_GETFD
bool exists(int process) => process > 1 && kill(process, 0) == 0;
int fdCount() => using((arena) {
  // Dart Directory.list stats each devfs entry, including an FD the I/O worker
  // has already closed. Enumerate names like upstream read_dir, without stat.
  final directory = _opendir((Platform.isLinux ? '/proc/self/fd' : '/dev/fd').toNativeUtf8(allocator: arena));
  if (directory == nullptr) throw StateError('Cannot enumerate fixture FDs');
  try { var count = 0; while (_readdir(directory) != nullptr) { count++; } return count - 2; }
  finally { _closedir(directory); }
});
int inheritableSentinel() => using((arena) {
  final original = _open('/dev/null'.toNativeUtf8(allocator: arena), 0, 0);
  if (original < 0) throw StateError('Cannot open fixture sentinel');
  try {
    final result = _fcntl(original, 0, 200); // F_DUPFD: never overwrite VM FDs.
    if (result < 200 || fdFlags(result) != 0) throw StateError('Sentinel is not inheritable');
    return result;
  } finally { closeFd(original); }
});

void writeDiagnostic(String line) => using((arena) {
  final bytes = line.toNativeUtf8(allocator: arena);
  if (_write(2, bytes.cast(), bytes.length) != bytes.length) throw StateError('Incomplete fixture stderr write');
});

Future<({int exitCode, String stdout, String stderr})> inheritedProbe(List<String> arguments, Directory root, CancellationToken cancellation) async {
  final out = File('${root.path}/probe-${newId()}.out'), err = File('${root.path}/probe-${newId()}.err');
  final child = using((arena) {
    final actions = arena<Uint64>(128).cast<Void>(); // Opaque, aligned libc-owned action storage.
    if (_actionsInit(actions) != 0) throw StateError('Cannot initialize oracle actions');
    final files = <int>[];
    try {
      for (final (target, file) in [(1, out), (2, err)]) {
        final fd = _open(file.path.toNativeUtf8(allocator: arena), Platform.isMacOS ? 0x601 : 0x241, 0x180);
        if (fd < 0) throw StateError('Cannot open oracle output');
        files.add(fd); if (_dup(actions, fd, target) != 0) throw StateError('Cannot wire oracle stdio');
      }
      Pointer<Pointer<Utf8>> strings(List<String> values) {
        final result = arena<Pointer<Utf8>>(values.length + 1);
        for (final (index, value) in values.indexed) { result[index] = value.toNativeUtf8(allocator: arena); }
        return result;
      }
      final pid = arena<Int32>(), executable = Platform.resolvedExecutable;
      final result = _spawn(pid, executable.toNativeUtf8(allocator: arena), actions, nullptr,
        strings([executable, ...arguments]), strings(Platform.environment.entries.map((e) => '${e.key}=${e.value}').toList()));
      if (result != 0) throw StateError('Independent oracle spawn failed: errno $result');
      return pid.value;
    } finally { _actionsDestroy(actions); for (final fd in files) { closeFd(fd); } }
  });
  final status = calloc<Int32>();
  var reaped = false;
  try {
    while (true) {
      cancellation.throwIfCancelled();
      final result = _waitpid(child, status, 1);
      if (result == child) { reaped = true; break; }
      if (result < 0) throw StateError('Cannot reap oracle child');
      await cancellableDelay(const Duration(milliseconds: 10), cancellation);
    }
    return (exitCode: status.value, stdout: await out.readAsString(), stderr: await err.readAsString());
  } finally {
    if (!reaped) { kill(child, 9); _waitpid(child, status, 0); }
    calloc.free(status); if (out.existsSync()) out.deleteSync(); if (err.existsSync()) err.deleteSync();
  }
}
