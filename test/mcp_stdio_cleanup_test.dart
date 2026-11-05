// Complete applicable local Unix ports of Codex 5112ce6edeb9 rmcp-client/tests/
// process_group_cleanup.rs, stdio_descriptor_boundary.rs, stdio_stderr_cleanup.rs.
// Dart children replace Python/Rust fixtures. Explicit connection shutdown and
// final config-owner disposal replace deterministic Rust Drop, not fake GC.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp/mcp.dart';
import 'package:mcp/src/transport.dart';
import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

import 'fixtures/stdio_unix.dart';

void main() {
  group('Codex Unix stdio ownership', () {
    late Directory root;
    late HttpClient http;
    late CancellationToken lifetime;
    final connections = <McpConnection>[], managers = <McpManager>[];
    final packages = File('.dart_tool/package_config.json').absolute.path;
    final fixture = File('test/fixtures/mcp_stdio_lifecycle.dart').absolute.path;
    List<String> args(String mode, [List<String> extra = const []]) => ['--disable-dart-dev', '--packages=$packages', fixture, mode, root.path, ...extra];
    setUp(() async { root = await Directory.systemTemp.createTemp('codex-stdio-cleanup-'); http = HttpClient(); lifetime = TimeoutCancellationToken(const Duration(seconds: 20)); });
    tearDown(() async {
      lifetime.cancel();
      // Only fixture-written, individually validated PIDs. Never signal the
      // host/test group, even on the pre-fix launcher that shares that group.
      for (final name in ['server', 'child', 'escaped']) {
        final file = File('${root.path}/$name.pid');
        if (file.existsSync()) { final child = int.tryParse(file.readAsStringSync()); if (child != null && child > 1 && child != pid) kill(child, 9); }
      }
      await Future.wait(managers.map((m) => m.close())); await Future.wait(connections.map((c) => c.close()));
      managers.clear(); connections.clear(); http.close(force: true); await root.delete(recursive: true);
    });
    Future<int> writtenPid(String name) async {
      final file = File('${root.path}/$name.pid');
      while (!file.existsSync() || file.readAsStringSync().trim().isEmpty) { await cancellableDelay(const Duration(milliseconds: 10), lifetime); }
      final result = int.parse(file.readAsStringSync()); expect(result, greaterThan(1)); expect(result, isNot(pid)); return result;
    }
    Future<void> exited(int child) async {
      for (var attempt = 0; attempt < 200 && exists(child); attempt++) { await cancellableDelay(const Duration(milliseconds: 10), lifetime); }
      expect(exists(child), false, reason: 'Fixture PID $child survived teardown');
    }
    McpConnection connection(Json config) { final c = McpConnection(config, http, (_) {}); connections.add(c); return c; }

    test('final owner disposal kills an uninitialized wrapper and its descendant group', () async {
      final manager = McpManager(http: http, onEvent: (_, _) {}); managers.add(manager);
      final configuring = manager.configure({'wrapper': {'command': Platform.resolvedExecutable, 'args': args('wrapper')}}, lifetime);
      unawaited(configuring.then<void>((_) {}, onError: (Object _) {}));
      final child = await writtenPid('child'), server = await writtenPid('server');
      expect(exists(child), true); expect(exists(server), true);
      await manager.close().timeout(const Duration(seconds: 5)); await exited(child); await exited(server);
    });

    test('shutdown reaps an initialized server with an admitted in-flight call', () async {
      final c = connection({'command': Platform.resolvedExecutable, 'args': args('in-flight')});
      await c.connect(lifetime); final server = await writtenPid('server'); expect(exists(server), true);
      final work = c.request('tools/call', {'name': 'probe'}, cancellation: lifetime);
      final stopped = expectLater(work, throwsA(isA<McpFailure>()));
      while (!File('${root.path}/in-flight').existsSync()) { await cancellableDelay(const Duration(milliseconds: 5), lifetime); }
      await c.close(); await stopped; await exited(server);
    });

    test('inheritable descriptors stay outside absolute, relative and shell-fallback servers and descendants', () async {
      final child = await Process.start(Platform.resolvedExecutable, ['--disable-dart-dev', '--packages=$packages',
        File('test/fixtures/mcp_stdio_descriptor_owner.dart').absolute.path, root.path]);
      addTearDown(() async { child.kill(ProcessSignal.sigkill); await child.exitCode; });
      final out = utf8.decoder.bind(child.stdout).join(), err = utf8.decoder.bind(child.stderr).join();
      expect(await child.exitCode.asCancellable(lifetime), 0, reason: await err);
      final report = jsonObject(jsonDecode(await out));
      expect(report['oracleStatus'], 0); expect(report['oracleSawSentinel'], true, reason: 'An oracle that also closes FDs would be a false proof.');
      expect(report['oracleStderr'], 'descriptor fixture stderr\n');
      expect(report['results'], [for (final launch in ['absolute', 'relative', 'shell fallback']) {
        'launch': launch, 'result': {'server': false, 'descendant': false, 'descendantStderr': 'descriptor fixture stderr\n'},
        'parentFlags': 0,
      }], reason: 'All variants must close only child descriptors and preserve explicit stdio.');
    });

    test('missing-interpreter launch reports the exec error, not discovery success or timeout', () async {
      final script = File('${root.path}/missing-interpreter'); await script.writeAsString('#!${root.path}/does-not-exist\n');
      expect((await Process.run('/bin/chmod', ['700', script.path])).exitCode, 0);
      final c = connection({'command': script.path});
      await expectLater(c.connect(lifetime), throwsA(isA<ProcessException>().having((e) => e.errorCode, 'native exec errno', 2)));
    });

    // A native launcher must preserve Process.start's string boundary: silently
    // truncating at NUL can execute a different command/configuration.
    for (final field in ['command', 'argument', 'cwd', 'environment']) {
      test('native launch rejects embedded NUL in $field before executing a child', () async {
        final config = <String, dynamic>{'command': Platform.resolvedExecutable, 'args': args('in-flight'), 'cwd': root.path};
        switch (field) {
          case 'command': config['command'] = '${Platform.resolvedExecutable}\u0000ignored';
          case 'argument': config['args'] = [...args('in-flight'), 'visible\u0000ignored'];
          case 'cwd': config['cwd'] = '${root.path}\u0000ignored';
          case 'environment': config['env'] = {'MCP_FIXTURE_VALUE': 'visible\u0000ignored'};
        }
        await expectLater(connection(config).connect(lifetime), throwsA(isA<ArgumentError>()));
        expect(File('${root.path}/server.pid').existsSync(), false);
      });
    }

    // Separate owners make process-wide FD counts independent of the runner.
    // Both paths keep the escaped setsid child alive through the FD assertion.
    for (final cleanup in ['shutdown', 'owner-disposal']) {
      test('$cleanup closes stderr and retains diagnostics queued while its reader cannot run', () async {
        final child = await Process.start(Platform.resolvedExecutable, ['--disable-dart-dev', '--packages=$packages',
          File('test/fixtures/mcp_stdio_stderr_owner.dart').absolute.path, root.path, cleanup]);
        addTearDown(() async { child.kill(ProcessSignal.sigkill); await child.exitCode; });
        final out = utf8.decoder.bind(child.stdout).join(), err = utf8.decoder.bind(child.stderr).join();
        expect(await child.exitCode.asCancellable(lifetime), 0, reason: await err);
        final report = jsonObject(jsonDecode(await out));
        expect(report['escapedGroup'], true); expect(report['escapedAlive'], true);
        expect(report['after'], report['baseline'], reason: 'The escaped child still holds stderr open.');
        expect(await err, contains('queued diagnostic before $cleanup'));
        expect(report['isolated'], true, reason: 'Only a launcher-owned group can be signalled safely.');
      });
    }
  }, skip: Platform.isWindows ? 'Unix process-group/FD contracts; Windows job objects are not claimed by this port.' : false);
}
