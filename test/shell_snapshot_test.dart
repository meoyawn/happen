// Modified ports of OpenAI Codex shell snapshot tests, ddd1812a51f4aded35c3ec5446672474d5cb546b.
// See packages/tool_runtime/UPSTREAM.md for source cases and applicability.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

late String _hostKernel;

void main() {
  setUpAll(() async {
    final compiled = await Directory.systemTemp.createTemp('snapshot-host-kernel-');
    addTearDown(() => compiled.delete(recursive: true));
    _hostKernel = '${compiled.path}/host.dill';
    final sdk = File(Platform.resolvedExecutable).parent.parent.path;
    final compiler = await Process.start('$sdk/bin/dartaotruntime', [
      '$sdk/bin/snapshots/frontend_server_aot.dart.snapshot',
      '--sdk-root=$sdk', '--platform=$sdk/lib/_internal/vm_platform_strong.dill',
      '--target=vm', '--output-dill=$_hostKernel',
      '--packages=${File('.dart_tool/package_config.json').absolute.path}',
      '--native-assets=${File('.dart_tool/native_assets.yaml').absolute.path}',
    ]);
    final errors = compiler.stderr.transform(utf8.decoder).join();
    final deadline = TimeoutCancellationToken(const Duration(seconds: 45));
    final hook = CancellationHook(deadline, () => compiler.kill(ProcessSignal.sigkill));
    final lines = StreamIterator(compiler.stdout.transform(utf8.decoder).transform(const LineSplitter()));
    final diagnostics = StringBuffer();
    try {
      compiler.stdin.writeln('compile ${File('test/fixtures/shell_snapshot_host.dart').absolute.uri}');
      await compiler.stdin.flush();
      String? boundary;
      var complete = false;
      while (await lines.moveNext().asCancellable(deadline)) {
        final line = lines.current;
        diagnostics.writeln(line);
        if (line.startsWith('result ')) {
          boundary = line.substring(7);
        } else if (boundary != null && line.startsWith('$boundary ')) {
          expect(line.split(' ').last, '0', reason: '$diagnostics');
          complete = true;
          break;
        }
      }
      expect(complete, isTrue, reason: '$diagnostics');
      compiler.stdin.writeln('quit');
      await compiler.stdin.close();
      expect(await compiler.exitCode.asCancellable(deadline), 0, reason: await errors);
    } finally {
      hook.dispose(); deadline.cancel();
      compiler.kill(ProcessSignal.sigkill);
      await lines.cancel();
    }
  });
  for (final shell in ['bash', 'zsh', 'sh'].where((name) => File('/bin/$name').existsSync())) {
    test('$shell snapshot reuses unchanged startup and refreshes edited startup files', () async {
      final peer = await _host(shell, r'''
printf x >> "$HOME/captures-SHELL"
export APP_SETTING='first
second 😀'
profile_helper() { printf 'restored:%s|%s' "$1" "$APP_SETTING"; }
alias snapshot_alias="printf alias"
OPTIONS
''');
      // Upstream's sh capture clears aliases before serialization. Bash/Zsh
      // own alias restoration; the sh case covers functions and environment.
      final alias = shell == 'sh' ? '' : "; printf '|'; eval snapshot_alias";
      final first = await peer.run('profile_helper first$alias');
      expect(first['exit_code'], 0, reason: '$first');
      expect(first['output'], 'restored:first|first\nsecond 😀${shell == 'sh' ? '' : '|alias'}');
      final second = await peer.run('profile_helper second$alias');
      expect(second['exit_code'], 0);
      expect(second['output'], 'restored:second|first\nsecond 😀${shell == 'sh' ? '' : '|alias'}');
      expect(await File('${peer.root.path}/captures-$shell').readAsString(), 'x');
      await peer.profile.writeAsString('printf poison >> "\$HOME/captures-$shell"\nexport APP_SETTING=changed\n');
      final updated = await peer.run(r'''printf '%s' "$APP_SETTING"''');
      expect(updated['exit_code'], 0);
      expect(updated['output'], 'changed');
      expect(await File('${peer.root.path}/captures-$shell').readAsString(), 'xpoison');
      await peer.profile.delete();
      expect((await peer.run(r'''printf '%s' "${APP_SETTING-absent}"'''))['output'], 'absent');
    });

    test('$shell newly created login profile updates PATH in every directory', () async {
      final peer = await _host(shell, 'export CAPTURE_SETTING=initialized\n');
      expect((await peer.run(r'''printf '%s' "$CAPTURE_SETTING"'''))['output'], 'initialized');
      final bin = await Directory('${peer.root.path}/bin').create();
      final executable = File('${bin.path}/snapshot-command');
      await executable.writeAsString('#!/bin/sh\nprintf fresh-path\n');
      expect((await Process.run('/bin/chmod', ['700', executable.path])).exitCode, 0);
      final login = File('${peer.root.path}/${shell == 'bash' ? '.bash_profile' : shell == 'zsh' ? '.zprofile' : '.profile'}');
      await login.writeAsString(r'''export PATH="$HOME/bin:$PATH"
''');
      final other = await Directory('${peer.root.path}/other').create();
      for (final directory in [peer.root.path, other.path]) {
        final result = await peer.run('snapshot-command', workdir: directory);
        expect(result['exit_code'], 0, reason: '$result');
        expect(result['output'], 'fresh-path');
      }
    });

    test('$shell snapshot does not inherit command stdin', () async {
      final peer = await _host(shell, r'''
if read unwanted; then exit 41; fi
profile_helper() { printf no-stdin; }
''');
      expect(await peer.run('profile_helper'), containsPair('output', 'no-stdin'));
    });

    test('$shell snapshot keeps current execution metadata out of cached profile exports', () async {
      final peer = await _host(shell, r'''
printf '%s' "${CODEX_TOOL_CALL_ID-missing}" > "$HOME/capture-call"
export CODEX_THREAD_ID=stale-thread CODEX_TOOL_CALL_ID=stale-call
profile_helper() { printf '%s|%s' "$CODEX_THREAD_ID" "$CODEX_TOOL_CALL_ID"; }
''', environment: {'CODEX_THREAD_ID': 'current-thread', 'CODEX_TOOL_CALL_ID': 'current-call'});
      final result = await peer.run('profile_helper');
      expect(result['exit_code'], 0);
      expect(result['output'], 'current-thread|current-call');
      expect(await File('${peer.root.path}/capture-call').readAsString(), 'missing');
    });

    test('$shell snapshot keeps current working directory and bypasses login false', () async {
      final peer = await _host(shell, 'profile_helper() { printf initialized; }\nexport SNAPSHOT_SETTING=present\n');
      expect((await peer.run('profile_helper'))['output'], 'initialized');
      final plain = await peer.run(r'''printf '%s' "${SNAPSHOT_SETTING-absent}"''', login: false);
      expect(plain['output'], 'absent');
      final other = await Directory('${peer.root.path}/other').create();
      final changed = await peer.run(r'''printf '%s|%s' "$PWD" "${SNAPSHOT_SETTING-absent}"''', workdir: other.path);
      expect(changed['output'], '${other.path}|absent');
    });

    test('$shell snapshot preserves successful startup services and redirected startup output', () async {
      final peer = await _host(shell, r'''
printf x >> "$HOME/captures-SHELL"
/bin/sleep 60 >/dev/null 2>&1 &
export SNAPSHOT_SERVICE_PID=$!
printf '%s' "$SNAPSHOT_SERVICE_PID" > "$HOME/service-pid"
exec > >(/bin/dd bs=128 count=1 2>/dev/null; /bin/sleep 0.1; /bin/cat)
profile_helper() { /bin/kill -0 "$SNAPSHOT_SERVICE_PID" && printf 'captured:%s' "$1"; }
''');
      for (var i = 0; i < 2; i++) {
        final result = await peer.run('profile_helper $i');
        expect(result['exit_code'], 0);
        expect(result['output'], 'captured:$i');
      }
      expect(await File('${peer.root.path}/captures-$shell').readAsString(), 'x');
    }, skip: shell == 'sh' ? 'Process substitution is a Bash/Zsh feature, as in upstream.' : false);

    test('$shell snapshot returns while a startup helper still holds stdout', () async {
      final peer = await _host(shell, r'''
/bin/sleep 60 &
printf '%s' "$!" > "$HOME/service-pid"
profile_helper() { printf ready; }
''');
      expect(await peer.run('profile_helper'), containsPair('output', 'ready'));
    });
  }

  for (final shell in ['bash', 'zsh'].where((name) => File('/bin/$name').existsSync())) {
    test('$shell discards a capture when startup changes while it is pending', () async {
      final peer = await _host(shell, r'''
printf old >> "$HOME/capture-generations"
profile_helper() { printf stale; }
printf '%s' "$$" > "$HOME/capture-pid"
while [ ! -f "$HOME/ready" ]; do /bin/sleep 0.01; done
''');
      final pending = peer.batch(List.generate(4, (_) => {'cmd': 'profile_helper'}));
      await _waitFor(File('${peer.root.path}/capture-pid'));
      await peer.profile.writeAsString(r'''
printf fresh >> "$HOME/capture-generations"
profile_helper() { printf refreshed; }
''');
      await File('${peer.root.path}/ready').writeAsString('');
      final results = await pending;
      expect(results.map((value) => value['exit_code']), everyElement(0));
      expect(results.map((value) => value['output']), everyElement('refreshed'));
      expect(await File('${peer.root.path}/capture-generations').readAsString(), 'oldfresh');
    });

    for (final tty in [false, true]) {
      test('$shell concurrent snapshot replays have independent readers, tty=$tty', () async {
        final payload = 'x' * (480 * 1024);
        final options = shell == 'zsh' ? r'''
module_path=()
setopt RC_QUOTES
alias snapshot_quoted="printf '%s|' 'one''two'"
alias eval='exit 44'
alias case='exit 45'
''' : '';
        final peer = await _host(shell, '''
printf x >> "\$HOME/captures-$shell"
profile_helper() { case "${shell == 'bash' ? r'${BASH_SOURCE[0]}' : r'${(%):-%x}'}" in /dev/fd/*) ;; *) return 42 ;; esac; local payload='$payload'; [ "\${#payload}" = ${payload.length} ] || return 43; printf 'restored:%s' "\$1"; }
exec() { exit 41; }
set -u
$options
''');
        final values = await peer.batch([
          for (var i = 0; i < 8; i++) {
            'cmd': 'if [ -e /dev/fd/4 ]; then exit 47; fi\nIFS= read -r line\n${shell == 'zsh' ? 'eval snapshot_quoted\n[[ -o rcquotes ]] || exit 46\n' : ''}profile_helper "\$line"; exit 7',
            'stdin': 'input-$i\n', 'tty': tty,
          },
        ]);
        for (var i = 0; i < values.length; i++) {
          expect(values[i]['exit_code'], 7, reason: '${values[i]}');
          expect(values[i]['output'], endsWith("${shell == 'zsh' ? "one'two|" : ''}restored:input-$i"));
        }
        expect(await File('${peer.root.path}/captures-$shell').readAsString(), 'x');
      });
    }

    test('$shell streamed snapshot preserves alias and option parse order', () async {
      final peer = await _host(shell, r'''
OPTIONS
helper() { printf helper; }
function : () { exit 41; }
alias snapshot_alias="printf 'one''two'"
''');
      final result = await peer.run('eval snapshot_alias\nhelper\n');
      expect(result['exit_code'], 0);
      expect(result['output'], shell == 'zsh' ? "one'twohelper" : 'onetwohelper');
    });

    for (final size in [1024 * 1024, 4 * 1024 * 1024 + 1]) {
      test('$shell snapshot file replay size limit, function bytes=$size', () async {
        final peer = await _host(shell, "profile_helper() { local payload='${'x' * size}'; printf restored; }\n");
        final result = await peer.run("if command -v profile_helper >/dev/null; then profile_helper; else printf fallback; fi");
        expect(result['exit_code'], 0);
        expect(result['output'], size < 4 * 1024 * 1024 ? 'restored' : 'fallback');
      });
    }

    for (final recovery in [1, 2, 3, 4]) {
      test('$shell failed snapshot captures are single flight with three bounded attempts; recovery=$recovery', () async {
        final peer = await _host(shell, '''
printf x >> "\$HOME/captures-$shell"
if [ "\$(/usr/bin/wc -c < "\$HOME/captures-$shell")" -lt $recovery ]; then exit 7; fi
profile_helper() { printf recovered; }
''');
        // Bash has no speculative default-shell capture on a Zsh account.
        // A failed default-shell prewarm is deliberately not a command attempt.
        if (shell == 'zsh') {
          await _waitFor(File('${peer.root.path}/captures-$shell'));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        var recovered = false;
        for (var attempt = 1; attempt <= 5; attempt++) {
          final results = await peer.batch(List.generate(2, (_) => {
            'cmd': 'if command -v profile_helper >/dev/null; then profile_helper; else printf fallback; fi',
          }));
          expect(results.map((value) => value['exit_code']), everyElement(0));
          expect(results.map((value) => value['output']).toSet(), hasLength(1));
          recovered |= results.first['output'] == 'recovered';
          if (attempt != 5) await Future<void>.delayed(const Duration(milliseconds: 1100));
        }
        final captures = await File('${peer.root.path}/captures-$shell').readAsString();
        expect(recovered, recovery <= (shell == 'zsh' ? 4 : 3));
        expect(captures.length, lessThanOrEqualTo(shell == 'zsh' ? 4 : 3));
      });
    }
  }

  for (final failure in ['header', 'records', 'capture-limit', 'environment-limit']) {
    test('invalid snapshot falls back to login startup: $failure', () async {
      final profile = switch (failure) {
        'header' => 'echo() { builtin echo ignored; }\n',
        'records' => r'''printf() { if [ "$1" != '\0' ]; then builtin printf "$@"; fi; }
''',
        'capture-limit' => 'printf "%*s" ${8 * 1024 * 1024 + 1} ""\n',
        // The upstream limit applies before metadata filtering. A startup env
        // wrapper makes this observable even on hosts with a smaller ARG_MAX.
        _ => 'env() { printf "CODEX_THREAD_ID=%*s\\\\0" ${512 * 1024} ""; }\n',
      };
      final peer = await _host('bash', '${profile}profile_helper() { printf restored; }\n');
      final result = await peer.run('if command -v profile_helper >/dev/null; then profile_helper; else printf fallback; fi');
      expect(result['exit_code'], 0);
      expect(result['output'], 'fallback');
    }, skip: !File('/bin/bash').existsSync());
  }

  test('snapshot ignores invalid UTF-8 environment records independently', () async {
    final peer = await _host('bash', r'''
export APP_SETTING=valid
env() { printf 'INVALID=\377\0'; command env "$@"; }
profile_helper() { printf '%s' "$APP_SETTING"; }
''');
    final result = await peer.run('profile_helper');
    expect(result['exit_code'], 0);
    expect(result['output'], 'valid');
  }, skip: !File('/bin/bash').existsSync());

  for (final size in [128 * 1024, 512 * 1024 + 1]) {
    test('POSIX snapshot environment replay size limit, function bytes=$size', () async {
      final peer = await _host('sh', "profile_helper() { local payload='${'x' * size}'; printf restored; }\n");
      final result = await peer.run('if command -v profile_helper >/dev/null; then profile_helper; else printf fallback; fi');
      expect(result['exit_code'], 0);
      expect(result['output'], size < 512 * 1024 ? 'restored' : 'fallback');
    }, skip: !File('/bin/sh').existsSync());
  }

  test('POSIX snapshot rejects capture output above 4 MiB before replay', () async {
    final peer = await _host('sh', 'printf "%*s" ${4 * 1024 * 1024 + 1} ""\nprofile_helper() { printf restored; }\n');
    final result = await peer.run('if command -v profile_helper >/dev/null; then profile_helper; else printf fallback; fi');
    expect(result['exit_code'], 0);
    expect(result['output'], 'fallback');
  }, skip: !File('/bin/sh').existsSync());

  if (File('/bin/zsh').existsSync()) {
    test('snapshot prewarm does not block other tools and is reused after the startup gate opens', () async {
      final peer = await _host('zsh', r'''
printf x >> "$HOME/captures-zsh"
printf '%s' "$$" > "$HOME/capture-pid"
while [ ! -f "$HOME/ready" ]; do /bin/sleep 0.01; done
profile_helper() { printf prewarmed; }
''');
      await _waitFor(File('${peer.root.path}/capture-pid'));
      final plain = await peer.run('printf independent', login: false);
      expect(plain['output'], 'independent');
      await File('${peer.root.path}/ready').writeAsString('');
      expect((await peer.run('profile_helper'))['output'], 'prewarmed');
      expect(await File('${peer.root.path}/captures-zsh').readAsString(), 'x');
    });

    test('zsh snapshot restores tied PATH and resolves its executable', () async {
      final peer = await _host('zsh', r'''
path=("$HOME/bin" $path)
profile_helper() { snapshot_executable; }
''');
      final bin = await Directory('${peer.root.path}/bin').create();
      final executable = File('${bin.path}/snapshot_executable');
      await executable.writeAsString('#!/bin/sh\nprintf tied-path\n');
      expect((await Process.run('/bin/chmod', ['700', executable.path])).exitCode, 0);
      final result = await peer.run('profile_helper');
      expect(result['exit_code'], 0);
      expect(result['output'], 'tied-path');
    });

    test('one-shot shell commands share the snapshot and retain their output contract', () async {
      final peer = await _host('zsh', r'''
printf x >> "$HOME/captures-zsh"
profile_helper() { printf shared; }
''');
      expect((await peer.run('profile_helper'))['output'], 'shared');
      final result = (await peer.batch([{'one_shot': true, 'command': 'profile_helper'}])).single;
      expect(result['exit_code'], 0);
      expect(result['output'], 'shared');
      expect(await File('${peer.root.path}/captures-zsh').readAsString(), 'x');
    });
  }

  for (final form in ['absolute', 'variable', 'braced', 'directory', 'path-prefix',
    'path-variable', 'path-braced', 'path-empty', 'path-braced-empty', 'tilde',
    'default-unset', 'default-empty', 'default-set', 'missing', 'injection']) {
    test('POSIX snapshot ENV path expansion: $form', () async {
      final root = await Directory.systemTemp.createTemp('snapshot-env-');
      addTearDown(() async { if (await root.exists()) await root.delete(recursive: true); });
      final startup = File('${root.path}/startup.sh');
      await startup.writeAsString('profile_helper() { printf expanded; }\n');
      final config = await Directory('${root.path}/.config').create();
      await File('${config.path}/startup.sh').writeAsString('profile_helper() { printf expanded; }\n');
      final selectedPath = switch (form) {
        'path-prefix' => '${root.path}:/usr/bin:/bin',
        'path-variable' || 'path-braced' => root.path,
        'path-empty' || 'path-braced-empty' => '',
        _ => null,
      };
      if (selectedPath != null) {
        // macOS's global login profile prepends system directories. Preserve
        // this vector's deliberately selected PATH before resolving ENV.
        await File('${root.path}/.profile').writeAsString('PATH="\$STARTUP_PATH"; export PATH\n');
      }
      final env = <String, String>{
        'STARTUP_FILE': startup.path, 'STARTUP_DIR': root.path,
        'ENV': switch (form) {
          'absolute' => startup.path,
          'variable' => r'$STARTUP_FILE',
          'braced' => r'${STARTUP_FILE}',
          'directory' => r'${STARTUP_DIR}/startup.sh',
          'path-prefix' => r'${PATH%%:*}/startup.sh',
          'path-variable' => r'$PATH/startup.sh',
          'path-braced' => r'${PATH}/startup.sh',
          'path-empty' => '\$PATH${startup.path}',
          'path-braced-empty' => '\${PATH}${startup.path}',
          'tilde' => '~/startup.sh',
          'default-unset' || 'default-empty' || 'default-set' =>
              r'${XDG_CONFIG_HOME:-$HOME/.config}/startup.sh',
          'missing' => r'$MISSING',
          _ => '"; touch "${root.path}/injected"; __codex_env_file="',
        },
        'STARTUP_PATH': ?selectedPath,
        if (form == 'default-empty') 'XDG_CONFIG_HOME': '',
        if (form == 'default-set') 'XDG_CONFIG_HOME': config.path,
      };
      final peer = await _host('sh', 'profile_helper() { printf expanded; }\n', root: root, environment: env);
      final result = await peer.run('if command -v profile_helper >/dev/null; then profile_helper; else printf absent; fi');
      expect(result['exit_code'], 0);
      expect(result['output'], {'injection', 'missing'}.contains(form) ? 'absent' : 'expanded');
      expect(await File('${root.path}/injected').exists(), isFalse);
      if (!{'injection', 'missing'}.contains(form)) {
        for (final file in [startup, File('${config.path}/startup.sh')]) {
          await file.writeAsString('profile_helper() { printf refreshed; }\n');
        }
        expect((await peer.run('profile_helper'))['output'], 'refreshed');
      }
    });
  }

  for (final mode in ['cancel', 'timeout']) {
    test('snapshot capture $mode terminates the capture process and descendants', () async {
      final peer = await _host('zsh', r'''
printf '%s' "$$" > "$HOME/capture-pid"
/bin/sh -c 'printf "%s" "$$" > "$HOME/descendant-pid"; /bin/sleep 60' &
wait
''');
      final pending = peer.run('printf fallback');
      await _waitFor(File('${peer.root.path}/descendant-pid'));
      if (mode == 'cancel') peer.process.kill(ProcessSignal.sigterm);
      if (mode == 'timeout') {
        expect((await pending)['output'], 'fallback');
      } else {
        await pending.then<void>((_) {}, onError: (Object _, StackTrace _) {});
        expect(await peer.process.exitCode.timeout(const Duration(seconds: 10)), 0);
      }
      for (final name in ['capture-pid', 'descendant-pid']) {
        final pid = int.parse(await File('${peer.root.path}/$name').readAsString());
        expect(Process.killPid(pid, ProcessSignal.sigcont), isFalse, reason: '$name survived $mode');
      }
    }, skip: !File('/bin/zsh').existsSync());
  }
}

Future<_ShellHost> _host(String shell, String profile, {
  Directory? root, Map<String, String> environment = const {},
}) async {
  root ??= await Directory.systemTemp.createTemp('shell-snapshot-');
  final home = Directory(await root.resolveSymbolicLinks());
  final startup = File('${home.path}/${shell == 'sh' ? 'startup.sh' : '.${shell}rc'}');
  final options = switch (shell) {
    'bash' => 'shopt -s expand_aliases',
    'zsh' => 'setopt RC_QUOTES',
    _ => '',
  };
  await startup.writeAsString(profile.replaceAll('SHELL', shell).replaceAll('OPTIONS', options));
  final process = await Process.start(Platform.resolvedExecutable, [
    '--disable-dart-dev', '--packages=${File('.dart_tool/package_config.json').absolute.path}',
    _hostKernel, home.path, '/bin/$shell',
  ], environment: {
    'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
    for (final key in ['TMPDIR', 'SYSTEMROOT', 'SystemRoot', 'WINDIR', 'LANG'])
      if (Platform.environment[key] case final String value) key: value,
    'HOME': home.path, 'ZDOTDIR': home.path,
    if (shell == 'sh') 'ENV': startup.path,
    ...environment,
  }, includeParentEnvironment: false);
  final peer = _ShellHost(home, startup, process);
  addTearDown(() async {
    if (!peer.closed) {
      try {
        process.stdin.writeln('{"close":true}');
        await process.stdin.flush();
      } on SocketException { /* A cancelled host may already have closed stdin. */ }
      on StateError { /* A failed host may already have closed stdin. */ }
      try { await process.exitCode.timeout(const Duration(seconds: 15)); }
      on TimeoutException { process.kill(ProcessSignal.sigkill); await process.exitCode; }
    }
    await peer.output.cancel();
    for (final name in ['service-pid', 'capture-pid', 'descendant-pid']) {
      final file = File('${home.path}/$name');
      if (await file.exists()) {
        final pid = int.tryParse(await file.readAsString());
        if (pid != null) Process.killPid(pid, ProcessSignal.sigkill);
      }
    }
    if (await home.exists()) await home.delete(recursive: true);
  });
  return peer;
}

class _ShellHost {
  _ShellHost(this.root, this.profile, this.process) {
    output = StreamIterator(process.stdout.transform(utf8.decoder).transform(const LineSplitter()));
    unawaited(process.stderr.transform(utf8.decoder).join().then((value) { errors = value; }));
    unawaited(process.exitCode.then((_) { closed = true; }));
  }
  final Directory root;
  final File profile;
  final Process process;
  late final StreamIterator<String> output;
  String errors = '';
  bool closed = false;

  Future<Json> run(String command, {bool login = true, String? workdir}) async =>
      (await batch([{'cmd': command, 'login': login, 'workdir': ?workdir}])).single;

  Future<List<Json>> batch(List<Json> commands) async {
    process.stdin.writeln(jsonEncode({'commands': commands, 'parallel': true}));
    await process.stdin.flush();
    if (!await output.moveNext().timeout(const Duration(seconds: 25))) {
      throw StateError('Shell host exited: $errors');
    }
    final response = jsonObject(jsonDecode(output.current));
    if (response['error'] != null) throw StateError('${response['error']}');
    return (response['results'] as List).map(jsonObject).toList();
  }
}

Future<void> _waitFor(File file) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!await file.exists()) {
    if (DateTime.now().isAfter(deadline)) throw StateError('Startup did not create ${file.path}');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
