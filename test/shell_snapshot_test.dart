// Modified ports of OpenAI Codex shell snapshot tests, ddd1812a51f4aded35c3ec5446672474d5cb546b.
// See packages/tool_runtime/UPSTREAM.md for source cases and applicability.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  for (final shell in ['bash', 'zsh', 'sh'].where((name) => File('/bin/$name').existsSync())) {
    test('$shell snapshot preserves initialized functions, aliases, options and multiline exports once', () async {
      final peer = await _host(shell, r'''
printf x >> "$HOME/captures-SHELL"
export APP_SETTING='first
second 😀'
profile_helper() { printf 'restored:%s|%s' "$1" "$APP_SETTING"; }
alias snapshot_alias="printf alias"
OPTIONS
''');
      final first = await peer.run(r'''profile_helper first; printf '|'; eval snapshot_alias''');
      expect(first['exit_code'], 0);
      expect(first['output'], 'restored:first|first\nsecond 😀|alias');
      await peer.profile.writeAsString('printf poison >> "\$HOME/captures-$shell"\nexport APP_SETTING=changed\n');
      final second = await peer.run(r'''profile_helper second; printf '|'; eval snapshot_alias''');
      expect(second['exit_code'], 0);
      expect(second['output'], 'restored:second|first\nsecond 😀|alias');
      expect(await File('${peer.root.path}/captures-$shell').readAsString(), 'x');
    });

    test('$shell snapshot does not inherit command stdin', () async {
      final peer = await _host(shell, r'''
if read unwanted; then exit 41; fi
profile_helper() { printf no-stdin; }
''');
      expect(await peer.run('profile_helper'), containsPair('output', 'no-stdin'));
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
exec > >(/bin/sleep 0.1; /bin/cat)
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
profile_helper() { local payload='$payload'; [ "\${#payload}" = ${payload.length} ] || return 43; printf 'restored:%s' "\$1"; }
exec() { exit 41; }
set -u
$options
''');
        final values = await peer.batch([
          for (var i = 0; i < 8; i++) {
            'cmd': 'IFS= read -r line\n${shell == 'zsh' ? 'eval snapshot_quoted\n[[ -o rcquotes ]] || exit 46\n' : ''}profile_helper "\$line"; exit 7',
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

  if (File('/bin/zsh').existsSync()) {
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
  }

  for (final form in ['absolute', 'variable', 'braced', 'directory', 'path-prefix', 'tilde', 'default', 'injection']) {
    test('POSIX snapshot ENV path expansion: $form', () async {
      final root = await Directory.systemTemp.createTemp('snapshot-env-');
      addTearDown(() async { if (await root.exists()) await root.delete(recursive: true); });
      final startup = File('${root.path}/startup.sh');
      await startup.writeAsString('profile_helper() { printf expanded; }\n');
      final env = <String, String>{
        'STARTUP_FILE': startup.path, 'STARTUP_DIR': root.path,
        'ENV': switch (form) {
          'absolute' => startup.path,
          'variable' => r'$STARTUP_FILE',
          'braced' => r'${STARTUP_FILE}',
          'directory' => r'${STARTUP_DIR}/startup.sh',
          'path-prefix' => r'${PATH%%:*}/startup.sh',
          'tilde' => '~/startup.sh',
          'default' => r'${MISSING:-$HOME}/startup.sh',
          _ => '"; touch "${root.path}/injected"; __codex_env_file="',
        },
        if (form == 'path-prefix') 'PATH': '${root.path}:/usr/bin:/bin',
      };
      final peer = await _host('sh', 'profile_helper() { printf expanded; }\n', root: root, environment: env);
      final result = await peer.run('if command -v profile_helper >/dev/null; then profile_helper; else printf absent; fi');
      expect(result['exit_code'], 0);
      expect(result['output'], form == 'injection' ? 'absent' : 'expanded');
      expect(await File('${root.path}/injected').exists(), isFalse);
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
  final home = root;
  final startup = File('${home.path}/${shell == 'sh' ? 'startup.sh' : '.${shell}rc'}');
  final options = switch (shell) {
    'bash' => 'shopt -s expand_aliases',
    'zsh' => 'setopt RC_QUOTES',
    _ => '',
  };
  await startup.writeAsString(profile.replaceAll('SHELL', shell).replaceAll('OPTIONS', options));
  final process = await Process.start(Platform.resolvedExecutable, [
    '--disable-dart-dev', '--packages=${File('.dart_tool/package_config.json').absolute.path}',
    File('test/fixtures/shell_snapshot_host.dart').absolute.path, home.path, '/bin/$shell',
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
      process.stdin.writeln('{"close":true}');
      await process.stdin.flush();
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
      (await batch([{'cmd': command, 'login': login, if (workdir != null) 'workdir': workdir}])).single;

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
