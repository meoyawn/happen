import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Codex shell-command/shell_detect.rs: account shell type, PATH, then OS defaults.
/// SHELL and AGENT_SHELL are not account-database lookups and do not override it.
String codexShell([String? selected]) {
  final account = _accountShell();
  final requested = selected == null ? _type(account ?? '') : _type(selected);
  final types = selected != null ? [?requested]
    : Platform.isWindows ? ['powershell']
    : [?requested, if (Platform.isMacOS) ...['zsh', 'bash'] else ...['bash', 'zsh']];
  for (final type in types) {
    if (_type(account ?? '') == type && account != null && File(account).existsSync()) return account;
    final names = type == 'powershell' ? ['pwsh', 'powershell'] : [type];
    for (final name in names) {
      for (final directory in (Platform.environment['PATH'] ?? '').split(Platform.isWindows ? ';' : ':')) {
        if (directory.isEmpty) continue;
        final path = '$directory/$name${Platform.isWindows ? '.exe' : ''}';
        if (File(path).existsSync()) return path;
      }
      final paths = switch (name) {
        'zsh' => ['/bin/zsh'], 'bash' => ['/bin/bash', '/usr/bin/bash'], 'sh' => ['/bin/sh'],
        'pwsh' => [Platform.isWindows ? r'C:\Program Files\PowerShell\7\pwsh.exe' : '/usr/local/bin/pwsh'],
        'powershell' => [if (Platform.isWindows) r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'],
        _ => <String>[],
      };
      for (final path in paths) { if (File(path).existsSync()) return path; }
    }
  }
  return Platform.isWindows ? 'cmd.exe' : '/bin/sh';
}

String? _type(String path) {
  final name = path.split(RegExp(r'[/\\]')).last.replaceFirst(RegExp(r'\.exe$'), '');
  return switch (name) {
    'zsh' || 'bash' || 'sh' || 'cmd' => name,
    'powershell' || 'pwsh' => 'powershell',
    _ => null,
  };
}

String? _accountShell() {
  if (!Platform.isMacOS && !Platform.isLinux) return null;
  final libc = DynamicLibrary.process();
  final uid = libc.lookupFunction<Uint32 Function(), int Function()>('getuid')();
  final read = libc.lookupFunction<Int32 Function(Uint32, Pointer<Void>, Pointer<Uint8>, IntPtr, Pointer<Pointer<Void>>),
    int Function(int, Pointer<Void>, Pointer<Uint8>, int, Pointer<Pointer<Void>>)>('getpwuid_r');
  final record = calloc<Uint8>(Platform.isMacOS ? sizeOf<_MacPasswd>() : sizeOf<_PosixPasswd>());
  final result = calloc<Pointer<Void>>();
  try {
    for (var size = 1024; size <= 1024 * 1024; size *= 2) {
      final buffer = calloc<Uint8>(size);
      try {
        final status = read(uid, record.cast(), buffer, size, result);
        if (status == 0) {
          if (result.value == nullptr) return null;
          final shell = Platform.isMacOS ? record.cast<_MacPasswd>().ref.shell : record.cast<_PosixPasswd>().ref.shell;
          return shell == nullptr ? null : shell.toDartString();
        }
        if (status != 34) return null; // ERANGE on Darwin and Linux.
      } finally { calloc.free(buffer); }
    }
    return null;
  } finally { calloc.free(result); calloc.free(record); }
}

final class _PosixPasswd extends Struct {
  external Pointer<Utf8> name;
  external Pointer<Utf8> password;
  @Uint32() external int uid;
  @Uint32() external int gid;
  external Pointer<Utf8> gecos;
  external Pointer<Utf8> home;
  external Pointer<Utf8> shell;
}

final class _MacPasswd extends Struct {
  external Pointer<Utf8> name;
  external Pointer<Utf8> password;
  @Uint32() external int uid;
  @Uint32() external int gid;
  @Int64() external int change;
  external Pointer<Utf8> accountClass;
  external Pointer<Utf8> gecos;
  external Pointer<Utf8> home;
  external Pointer<Utf8> shell;
  @Int64() external int expire;
  @Int32() external int fields;
}
