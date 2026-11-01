import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

final _listChildren = DynamicLibrary.open('/usr/lib/libproc.dylib').lookupFunction<
  Int32 Function(Int32, Pointer<Void>, Int32),
  int Function(int, Pointer<Void>, int)>('proc_listchildpids');

List<int> _children(int pid) {
  if (Platform.isMacOS) {
    for (var capacity = 64; ; capacity *= 2) {
      final buffer = calloc<Int32>(capacity);
      try {
        final count = _listChildren(pid, buffer.cast(), capacity * sizeOf<Int32>());
        if (count < 0) throw StateError('Could not list terminal child processes');
        if (count < capacity) return [for (var i = 0; i < count; i++) if (buffer[i] > 0) buffer[i]];
      } finally { calloc.free(buffer); }
    }
  }
  if (Platform.isLinux) {
    final result = <int>{};
    try {
      for (final thread in Directory('/proc/$pid/task').listSync()) {
        try {
          final text = File('${thread.path}/children').readAsStringSync().trim();
          if (text.isNotEmpty) result.addAll(text.split(RegExp(r'\s+')).map(int.parse));
        } on PathNotFoundException { /* A thread exited during enumeration. */ }
      }
    } on PathNotFoundException { /* The process already exited. */ }
    return result.toList();
  }
  return const [];
}

/// PTY job control gives background jobs their own process groups. Killing
/// only the foreground group and shell would leave those jobs running.
void killTerminalProcessTree(int pid) {
  if (!Platform.isMacOS && !Platform.isLinux) return;
  final stopped = <int>{};
  void stop(int child) {
    if (stopped.contains(child) || !Process.killPid(child, ProcessSignal.sigstop)) return;
    stopped.add(child);
    // Freeze each parent before discovering its children: it cannot fork or
    // reap them while ownership is being captured.
    for (final descendant in _children(child)) { stop(descendant); }
  }
  try { stop(pid); }
  finally {
    // Release children before their parents, even if enumeration fails. Never
    // leave an intentionally stopped job behind after a terminal is closed.
    for (final child in stopped.toList().reversed) { Process.killPid(child, ProcessSignal.sigkill); }
  }
}
