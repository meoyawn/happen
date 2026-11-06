// Modified Dart port of OpenAI Codex, Copyright 2025 OpenAI (Apache-2.0).
// codex-rs/exec-server/src/shell_snapshot{,_process,_file}.rs and
// shell-command/src/shell_snapshot_{capture,render}.rs, revision
// ddd1812a51f4aded35c3ec5446672474d5cb546b. See ../../UPSTREAM.md.
part of 'process.dart';

class _ShellSnapshot {
  _ShellSnapshot(this.state, this.environment);
  final String state;
  final Map<String, String> environment;
}

class _ShellCapture {
  Future<_ShellSnapshot?>? pending;
  _ShellSnapshot? value;
  DateTime? retryAfter;
  int attempts = 0;
  bool prewarming = false;
}

String? _snapshotShell(String executable) {
  if (Platform.isWindows) return null;
  final name = executable.split('/').last;
  return {'bash', 'zsh', 'sh'}.contains(name) ? name : null;
}

Future<_ShellSnapshot?> _snapshotFor(CommandRunner runner, String executable,
  String directory, {bool prewarm = false}) async {
  final shell = _snapshotShell(executable);
  if (shell == null) return null;
  final key = jsonEncode([executable, Directory(directory).absolute.uri.toString()]);
  final entry = runner._snapshots.remove(key) ?? _ShellCapture();
  runner._snapshots[key] = entry;
  while (runner._snapshots.length > 16) {
    runner._snapshots.remove(runner._snapshots.keys.first);
  }
  while (true) {
    runner._snapshotCancellation.throwIfCancelled();
    if (entry.value != null) return entry.value;
    if (entry.pending case final pending?) {
      final wasPrewarm = entry.prewarming;
      final value = await pending;
      if (value != null || prewarm || !wasPrewarm) return value;
      // A failed speculative capture must release a waiting real command
      // immediately, without consuming its retry budget or backoff.
      continue;
    }
    if (entry.attempts >= 3 ||
        entry.retryAfter != null && DateTime.now().isBefore(entry.retryAfter!)) {
      return null;
    }
    entry.prewarming = prewarm;
    if (!prewarm) entry.attempts++;
    final operation = _captureShell(executable, shell, directory,
        cancellation: runner._snapshotCancellation.merge(runner.cancellation));
    runner._captures.add(operation);
    entry.pending = operation;
    try {
      entry.value = await operation;
      if (entry.value == null && !prewarm) {
        entry.retryAfter = DateTime.now().add(const Duration(seconds: 1));
      }
      return entry.value;
    } finally {
      runner._captures.remove(operation);
      entry.pending = null;
      entry.prewarming = false;
    }
  }
}

String _captureScript(String shell) {
  final (startup, body) = switch (shell) {
    'zsh' => (snapshotZshStartup, snapshotZshBody),
    'bash' => (snapshotBashStartup, snapshotBashBody),
    _ => ('$snapshotPosixExpansion\n$snapshotShStartup', snapshotShBody),
  };
  return '$startup\n$body'
      .replaceAll('SNAPSHOT_OPTIONS_BEGIN', shell == 'sh' ? '' : r"printf '{\n'")
      .replaceAll('SNAPSHOT_ALIASES_END', shell == 'sh' ? '' : r'''printf "case '' in '') ;; esac\n}\n"''')
      .replaceAll('SNAPSHOT_ZSH_ALIASES', r'(\setopt NO_RC_QUOTES; \alias -L)')
      .replaceAll('SNAPSHOT_COMMAND_HELPER', snapshotCommandHelper)
      .replaceAll('SNAPSHOT_STARTUP_ENVIRONMENT', '')
      .replaceAll('SNAPSHOT_EXPORTS', '')
      .replaceAll('SNAPSHOT_DECLARATION_ENVIRONMENT', '')
      .replaceAll('SNAPSHOT_ENVIRONMENT', snapshotEnvironment) +
      r'''
__happen_snapshot_status=$?
printf '\0HAPPEN_SNAPSHOT_END\0'
exit "$__happen_snapshot_status"
''';
}

// Keep the capture's process group owned until both the shell's exit status
// and its complete output have been validated. Successful startup helpers are
// released; failures, timeouts and owner cancellation kill the whole group.
// The status marker is independent of inherited stdout reaching EOF.
const _captureSupervisor = r'''
set -m
"$@" </dev/null 2>/dev/null &
child=$!
trap 'trap - TERM INT HUP EXIT; kill -KILL -- -"$child" 2>/dev/null; wait "$child" 2>/dev/null' TERM INT HUP EXIT
wait "$child" 2>/dev/null
result=$?
printf '\0HAPPEN_SNAPSHOT_STATUS:%s\0' "$result" >&2
IFS= read -r action
if [ "$action" = preserve ] && [ "$result" = 0 ]; then
  trap - TERM INT HUP EXIT
fi
exit "$result"
''';

Future<_ShellSnapshot?> _captureShell(String executable, String shell, String directory, {
  required CancellationToken cancellation,
}) async {
  final fileReplay = shell != 'sh' && Directory('/dev/fd').existsSync();
  final captureLimit = (fileReplay ? 8 : 4) * 1024 * 1024;
  final deadline = TimeoutCancellationToken(const Duration(seconds: 10));
  final token = cancellation.merge(deadline);
  Process? process;
  StreamSubscription<List<int>>? output;
  StreamSubscription<List<int>>? errors;
  CancellationHook? hook;
  var preserve = false;
  try {
    token.throwIfCancelled();
    process = await Process.start('/bin/bash', [
      '--noprofile', '--norc', '-c', _captureSupervisor, 'happen-shell-capture',
      executable, '-l', '-c', _captureScript(shell),
    ], workingDirectory: directory, environment: {
      ...Platform.environment,
    }..remove('CODEX_TOOL_CALL_ID'), includeParentEnvironment: false);
    final child = process;
    hook = CancellationHook(token, () => child.kill(ProcessSignal.sigterm));
    final bytes = BytesBuilder(copy: false);
    final complete = Completer<void>();
    var tail = '';
    var statusTail = '';
    var ended = false;
    int? status;
    void fail(Object error, [StackTrace? stack]) {
      if (!complete.isCompleted) complete.completeError(error, stack);
    }
    void finish() {
      if (!complete.isCompleted && status != null && (ended || status != 0)) complete.complete();
    }
    output = child.stdout.listen((chunk) {
      if (complete.isCompleted) return;
      if (bytes.length + chunk.length > captureLimit) {
        fail(FormatException('Shell snapshot capture exceeds $captureLimit bytes'));
        return;
      }
      bytes.add(chunk);
      final scan = tail + latin1.decode(chunk);
      ended |= scan.contains('\u0000HAPPEN_SNAPSHOT_END\u0000');
      tail = scan.substring((scan.length - 128).clamp(0, scan.length));
      finish();
    }, onError: fail, onDone: () {
      if (!ended) fail(const FormatException('Incomplete shell snapshot capture'));
    });
    errors = child.stderr.listen((chunk) {
      if (complete.isCompleted) return;
      final scan = statusTail + latin1.decode(chunk);
      final match = RegExp('\u0000HAPPEN_SNAPSHOT_STATUS:([0-9]+)\u0000').firstMatch(scan);
      if (match != null) status = int.parse(match[1]!);
      statusTail = scan.substring((scan.length - 128).clamp(0, scan.length));
      finish();
    }, onError: fail, onDone: () {
      if (status == null) fail(const FormatException('Missing shell snapshot exit status'));
    });
    await complete.future.asCancellable(token);
    token.throwIfCancelled();
    if (status != 0) return null;
    final snapshot = _parseShellSnapshot(bytes.takeBytes(),
        posix: shell == 'sh', fileReplay: fileReplay);
    if (snapshot == null) return null;
    preserve = true;
    return snapshot;
  } on CancelledException {
    cancellation.throwIfCancelled();
    return null;
  } on TimeoutException {
    cancellation.throwIfCancelled();
    return null;
  } on ProcessException {
    return null;
  } on FileSystemException {
    return null;
  } on FormatException {
    return null;
  } finally {
    hook?.dispose();
    deadline.cancel();
    if (process != null) {
      try {
        process.stdin.writeln(preserve ? 'preserve' : 'discard');
        await process.stdin.flush();
      } on Object {
        process.kill(ProcessSignal.sigterm);
      }
      try { await process.exitCode.timeout(const Duration(seconds: 2)); }
      on TimeoutException {
        process.kill(ProcessSignal.sigterm);
        try { await process.exitCode.timeout(const Duration(seconds: 2)); }
        on TimeoutException { process.kill(ProcessSignal.sigkill); await process.exitCode; }
      }
      await process.stdin.close().catchError((Object _) {});
    }
    await output?.cancel();
    await errors?.cancel();
  }
}

_ShellSnapshot? _parseShellSnapshot(List<int> bytes, {
  required bool posix, required bool fileReplay,
}) {
  // latin1 preserves byte offsets while native shell state and each environment
  // entry are decoded independently as UTF-8, as in CapturedSnapshot::parse.
  final raw = latin1.decode(bytes);
  final start = raw.indexOf('# Snapshot file\n');
  final end = raw.indexOf('\u0000HAPPEN_SNAPSHOT_END\u0000');
  if (start < 0 || end < start) return null;
  final stateEnd = raw.indexOf('\u0000', start);
  if (stateEnd < 0 || stateEnd >= end) return null;
  final aliasesEnd = raw.indexOf('\u0000', stateEnd + 1);
  if (aliasesEnd < 0 || aliasesEnd + 1 >= end || bytes[aliasesEnd + 1] != 0) return null;
  var environmentStart = aliasesEnd + 2;
  if (posix) {
    // sh has an additional declaration-environment section even when disabled.
    if (environmentStart >= end || bytes[environmentStart] != 0) return null;
    environmentStart++;
  }
  if (end - environmentStart > 512 * 1024) return null;
  final stateBytes = [...bytes.sublist(start, stateEnd), ...bytes.sublist(stateEnd + 1, aliasesEnd)];
  if (stateBytes.length > (fileReplay ? 4 * 1024 * 1024 : 512 * 1024 - (end - environmentStart))) return null;
  final state = utf8.decode(stateBytes);
  final environment = <String, String>{};
  var position = environmentStart;
  while (position < end) {
    final next = raw.indexOf('\u0000', position);
    if (next < 0 || next > end) return null;
    try {
      final record = utf8.decode(bytes.sublist(position, next));
      final equals = record.indexOf('=');
      if (equals > 0) {
        final key = record.substring(0, equals);
        if (!{'PWD', 'OLDPWD', 'CODEX_THREAD_ID', 'CODEX_TOOL_CALL_ID'}.contains(key)) {
          environment[key] = record.substring(equals + 1);
        }
      }
    } on FormatException { /* The upstream executor skips non-UTF-8 OS entries. */ }
    position = next + 1;
  }
  return _ShellSnapshot(state, environment);
}

Future<({List<String> arguments, Map<String, String> environment, Directory? transport})>
    _replayShell(_ShellSnapshot snapshot, String shell, List<String> arguments, {
      required CancellationToken cancellation,
    }) async {
  cancellation.throwIfCancelled();
  final environment = {...Platform.environment, ...snapshot.environment};
  final command = arguments.last;
  if (shell == 'sh' || !Directory('/dev/fd').existsSync()) {
    // POSIX sh cannot portably close arbitrary inherited descriptors.
    final bytes = utf8.encode(snapshot.state).length +
        snapshot.environment.entries.fold<int>(0, (size, entry) => size + utf8.encode('${entry.key}=${entry.value}').length + 1);
    if (bytes > 512 * 1024) throw const FormatException('Shell snapshot environment replay exceeds 512 KiB');
    final names = <String>[];
    var offset = 0;
    while (offset < snapshot.state.length) {
      var end = (offset + 15 * 1024).clamp(0, snapshot.state.length);
      if (end < snapshot.state.length && _highSurrogate(snapshot.state.codeUnitAt(end - 1))) end--;
      final name = '__HAPPEN_SHELL_SNAPSHOT_${names.length}';
      environment[name] = snapshot.state.substring(offset, end);
      names.add(name);
      offset = end;
    }
    final source = 'eval "unset ${names.join(' ')}\n${names.map((name) => '\${$name}').join()}"';
    return (arguments: ['-c', 'if ! $source >/dev/null; then printf "failed to restore shell snapshot\\n" >&2; fi\n$command'],
      environment: environment, transport: null);
  }
  final directory = await Directory.systemTemp.createTemp('happen-shell-snapshot-');
  try {
    final path = '${directory.path}/state';
    final prefix = shell == 'zsh'
        ? '__happen_snapshot_fd=4\nexec {__happen_snapshot_fd}<&-\nunset __happen_snapshot_fd\n'
        : '\\exec 4<&-\n';
    await File(path).writeAsString('$prefix${snapshot.state}');
    cancellation.throwIfCancelled();
    final restore = '${shell == 'zsh' ? 'setopt RCS' : 'set +o privileged'}\n'
        'if ! . /dev/fd/4 >/dev/null; then printf "failed to restore shell snapshot\\n" >&2; fi\n$command';
    return (
      arguments: [shell == 'zsh' ? '-fc' : '-pc', restore],
      environment: environment,
      transport: directory,
    );
  } catch (_) {
    await directory.delete(recursive: true);
    rethrow;
  }
}

bool _highSurrogate(int unit) => unit >= 0xd800 && unit <= 0xdbff;

Future<void> _removeShellTransport(Directory directory) async {
  try {
    if (await directory.exists()) await directory.delete(recursive: true);
  } on FileSystemException { /* The supervisor normally unlinks it during launch. */ }
}

// A fresh reader per launch prevents concurrent commands sharing a file offset.
// The supervisor opens and unlinks the private transport before the user shell
// starts; the source closes its carrier before restoring shadowing functions.
const _openSnapshot = r'''
if [ -n "$1" ]; then
  exec 4<"$1/state" || exit 125
  /bin/rm -f -- "$1/state" || exit 125
  /bin/rmdir -- "$1" || exit 125
fi
shift
''';
