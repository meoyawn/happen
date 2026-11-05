import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:protocol/protocol.dart';

import 'stdio_unix.dart';

Future<void> main(List<String> arguments) async {
  final mode = arguments[0], root = Directory(arguments[1]);
  final packages = (await Isolate.packageConfig)!.toFilePath();
  final lifetime = TimeoutCancellationToken(const Duration(seconds: 45));
  // Every fixture is independently bounded, including orphans on a failed run.
  Timer(const Duration(seconds: 45), () => exit(0));
  if (mode == 'leaf' || mode == 'escaped') {
    if (mode == 'escaped') {
      if (setsid() != pid) throw StateError('Fixture failed to escape its group');
      closeFd(0); closeFd(1);
    }
    File('${root.path}/${mode == 'escaped' ? 'escaped' : 'child'}.pid').writeAsStringSync('$pid');
    await Completer<void>().future.asCancellable(lifetime); return;
  }
  if (mode == 'probe') {
    if ([0, 1, 2].any((fd) => fdFlags(fd) < 0)) throw StateError('Explicit stdio is broken');
    writeDiagnostic('descriptor fixture stderr\n');
    stdout.writeln(jsonEncode(fdFlags(int.parse(arguments[2])) >= 0));
    await stdout.flush(); exit(0);
  }
  File('${root.path}/server.pid').writeAsStringSync('$pid');
  if (mode == 'wrapper' || mode == 'stderr') {
    final child = await Process.start(Platform.resolvedExecutable, [
      '--disable-dart-dev', '--packages=$packages',
      Platform.script.toFilePath(), mode == 'stderr' ? 'escaped' : 'leaf', root.path,
    ], mode: ProcessStartMode.inheritStdio);
    unawaited(child.exitCode);
    if (mode == 'stderr') {
      while (!File('${root.path}/escaped.pid').existsSync()) { await cancellableDelay(const Duration(milliseconds: 5), lifetime); }
      Timer.periodic(const Duration(milliseconds: 5), (timer) {
        if (!File('${root.path}/emit').existsSync()) return;
        writeDiagnostic('${arguments[2]}\n'); File('${root.path}/written').writeAsStringSync('written'); timer.cancel();
      });
    }
  }
  void send(Object id, Json result) => stdout.writeln(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}));
  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((line) async {
    final message = jsonObject(jsonDecode(line)), method = message['method'];
    final id = message['id'] as Object?;
    if (mode == 'wrapper' || id == null) return;
    if (method == 'server/discover') {
      stdout.writeln(jsonEncode({'jsonrpc': '2.0', 'id': id, 'error': {'code': -32601, 'message': 'Method not found'}}));
    } else if (method == 'initialize') {
      send(id, {'protocolVersion': '2025-06-18', 'capabilities': {'tools': <String, Object?>{}}, 'serverInfo': {'name': 'lifecycle-fixture', 'version': '1'}});
    } else if (method == 'tools/list') {
      send(id, {'tools': [{'name': 'probe', 'inputSchema': {'type': 'object'}}]});
    } else if (method == 'tools/call') {
      File('${root.path}/in-flight').writeAsStringSync('admitted');
      if (mode == 'in-flight') return;
      if (mode == 'descriptor') {
        final result = await inheritedProbe(['--disable-dart-dev', '--packages=$packages',
          Platform.script.toFilePath(), 'probe', root.path, arguments[2]], root, lifetime);
        if (result.exitCode != 0) throw StateError('Descriptor descendant failed: ${result.stderr}');
        if ([0, 1, 2].any((fd) => fdFlags(fd) < 0)) throw StateError('Server stdio is broken');
        send(id, {'content': <Object?>[], 'structuredContent': {'server': fdFlags(int.parse(arguments[2])) >= 0,
          'descendant': jsonDecode(result.stdout), 'descendantStderr': result.stderr}});
      }
    }
  }, onDone: () { if (mode != 'in-flight') exit(0); });
}
