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
  _ShellCapture(this.files, this.fingerprint);
  final List<String> files;
  final String fingerprint;
  final cancellation = CancellationToken();
  _ShellCaptureState _state = const _CaptureEmpty();

  void transition(_ShellCaptureState next) {
    _state = switch ((_state, next)) {
      (_CaptureRetired(), _) => throw StateError('Shell capture is retired'),
      (_, _CaptureRetired()) => next,
      (_CaptureEmpty() || _CaptureFailed(), _Capturing()) => next,
      (_Capturing(), _Captured() || _CaptureFailed()) => next,
      _ => throw StateError('Invalid shell capture transition'),
    };
  }

  void retire() {
    if (_state is _CaptureRetired) return;
    transition(const _CaptureRetired());
    cancellation.cancel();
  }
}

sealed class _ShellCaptureState { const _ShellCaptureState(); }
class _CaptureEmpty extends _ShellCaptureState { const _CaptureEmpty(); }
class _Capturing extends _ShellCaptureState {
  const _Capturing(this.operation, {required this.prewarm});
  final Future<_ShellSnapshot?> operation;
  final bool prewarm;
}
class _Captured extends _ShellCaptureState {
  const _Captured(this.value, this.files, this.fingerprint);
  final _ShellSnapshot value;
  final List<String> files;
  final String fingerprint;
}
class _CaptureFailed extends _ShellCaptureState {
  const _CaptureFailed(this.attempts, this.retryAfter);
  final int attempts;
  final DateTime? retryAfter;
}
class _CaptureRetired extends _ShellCaptureState { const _CaptureRetired(); }

// Codex V2 caches initialized state. Happen additionally invalidates that cache
// when its standard startup inputs change, including newly created profiles.
// Arbitrary files sourced by those profiles remain the shell's responsibility.
List<String> _shellStartupFiles(String shell, String directory, {Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final home = env['HOME'];
  final files = <String>{};
  void add(String? path) {
    if (path == null || path.isEmpty) return;
    path = _shellStartupPath(path, env);
    if (path.isEmpty) return;
    files.add(Directory(directory).absolute.uri.resolveUri(Uri.file(path)).toFilePath());
  }
  if (shell == 'zsh') {
    for (final prefix in ['/etc', '/etc/zsh', ?home,
      if (env['ZDOTDIR'] case final String root) root]) {
      for (final name in ['zshenv', 'zprofile', 'zshrc', 'zlogin']) {
        add('$prefix/${prefix == '/etc' || prefix == '/etc/zsh' ? '' : '.'}$name');
      }
    }
  } else {
    add('/etc/profile');
    if (home != null) {
      for (final name in ['.profile', if (shell == 'bash') ...['.bash_profile', '.bash_login', '.bashrc']]) {
        add('$home/$name');
      }
    }
    add(shell == 'bash' ? env['BASH_ENV'] : env['ENV']);
    if (shell == 'bash') add('/etc/bash.bashrc');
  }
  return files.toList()..sort();
}

// Matches Codex's non-evaluating POSIX ENV resolver. A login profile can change
// PATH or XDG_CONFIG_HOME, so ready captures also track paths in their resulting
// environment rather than relying only on the server's inherited values.
String _shellStartupPath(String value, Map<String, String> env) {
  if (value.startsWith('~/')) return '${env['HOME'] ?? ''}/${value.substring(2)}';
  const prefix = r'${PATH%%:*}';
  if (value == prefix || value.startsWith('$prefix/')) {
    return '${(env['PATH'] ?? '').split(':').first}${value.substring(prefix.length)}';
  }
  String name, suffix;
  String? fallback;
  if (value.startsWith(r'${')) {
    final end = value.indexOf('}');
    if (end < 0) return value;
    name = value.substring(2, end);
    suffix = value.substring(end + 1);
    final separator = name.indexOf(':-');
    if (separator >= 0) {
      fallback = name.substring(separator + 2);
      name = name.substring(0, separator);
    }
  } else if (value.startsWith(r'$')) {
    final end = value.indexOf('/');
    name = value.substring(1, end < 0 ? value.length : end);
    suffix = end < 0 ? '' : value.substring(end);
  } else { return value; }
  if (!RegExp(r'^[A-Za-z_][A-Za-z_0-9]*$').hasMatch(name) ||
      suffix.isNotEmpty && !suffix.startsWith('/')) {
    return value;
  }
  final expanded = env[name];
  if (expanded != null && (expanded.isNotEmpty || fallback == null)) return '$expanded$suffix';
  return fallback == null ? value : '${_shellStartupPath(fallback, env)}$suffix';
}

Future<String> _shellStartupFingerprint(List<String> files, CancellationToken cancellation) async {
  cancellation.throwIfCancelled();
  final values = await Future.wait(files.map((path) async {
    final stat = await File(path).stat();
    return [path, stat.type.toString(), stat.size, stat.modified.microsecondsSinceEpoch,
      stat.changed.microsecondsSinceEpoch, stat.mode];
  }));
  cancellation.throwIfCancelled();
  return jsonEncode(values);
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
  final inheritedFiles = _shellStartupFiles(shell, directory);
  while (true) {
    runner._snapshotCancellation.throwIfCancelled();
    final previous = runner._snapshots[key];
    final previousState = previous?._state;
    final files = previousState is _Captured ? previousState.files : inheritedFiles;
    final fingerprint = await _shellStartupFingerprint(files, runner._snapshotCancellation);
    if (!identical(previous, runner._snapshots[key]) || !identical(previousState, previous?._state)) continue;
    final previousFingerprint = previousState is _Captured ? previousState.fingerprint : previous?.fingerprint;
    final entry = previous != null && previousFingerprint == fingerprint
        ? previous : _ShellCapture(files, fingerprint);
    if (!identical(previous, entry)) previous?.retire();
    runner._snapshots.remove(key);
    runner._snapshots[key] = entry;
    while (runner._snapshots.length > 16) {
      // Eviction releases cache ownership. Existing callers may still use a
      // valid result; changing startup inputs explicitly retires their capture.
      runner._snapshots.remove(runner._snapshots.keys.first);
    }
    final state = entry._state;
    if (state case _Captured(:final value)) return value;
    if (state case _Capturing(:final operation, prewarm: final wasPrewarm)) {
      final value = await operation;
      if (entry._state is _CaptureRetired) continue;
      if (value != null || prewarm || !wasPrewarm) return value;
      // A failed speculative capture must release a waiting real command
      // immediately, without consuming its retry budget or backoff.
      continue;
    }
    final attempts = state is _CaptureFailed ? state.attempts : 0;
    if (attempts >= 3 || state is _CaptureFailed && state.retryAfter != null &&
        DateTime.now().isBefore(state.retryAfter!)) {
      return null;
    }
    late final Future<_ShellSnapshot?> operation;
    operation = _captureCurrentShell(runner, key, entry, executable, shell, directory,
      attempts: attempts + (prewarm ? 0 : 1), prewarm: prewarm)
        .whenComplete(() { runner._captures.remove(operation); });
    entry.transition(_Capturing(operation, prewarm: prewarm));
    runner._captures.add(operation);
    final value = await operation;
    if (entry._state is _CaptureRetired) continue;
    return value;
  }
}

Future<_ShellSnapshot?> _captureCurrentShell(CommandRunner runner, String key,
    _ShellCapture entry, String executable, String shell, String directory, {
    required int attempts, required bool prewarm,
  }) async {
  final cancellation = entry.cancellation.merge(runner._snapshotCancellation).merge(runner.cancellation);
  try {
    final value = await _captureShell(executable, shell, directory, cancellation: cancellation);
    if (entry._state is _CaptureRetired) return null;
    final fingerprint = await _shellStartupFingerprint(entry.files, cancellation);
    if (fingerprint != entry.fingerprint) {
      entry.retire();
      if (identical(runner._snapshots[key], entry)) runner._snapshots.remove(key);
      return null;
    }
    if (value == null) {
      entry.transition(_CaptureFailed(attempts, prewarm ? null : DateTime.now().add(const Duration(seconds: 1))));
    } else {
      final files = {..._shellStartupFiles(shell, directory),
        ..._shellStartupFiles(shell, directory, environment: {...Platform.environment, ...value.environment})}.toList()..sort();
      final fingerprint = await _shellStartupFingerprint(files, cancellation);
      entry.transition(_Captured(value, files, fingerprint));
    }
    return value;
  } on CancelledException {
    if (entry._state is _CaptureRetired) return null;
    rethrow;
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
