import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:desktop/local_task_sleep.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

void main() {
  test('only embedded task activity holds one macOS assertion until the last task settles', () async {
    final root = await Directory.systemTemp.createTemp('desktop-sleep-');
    final provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final replies = <String, HttpResponse>{};
    final release = Completer<void>();
    final servers = <AgentServer>[];
    final clients = <AgentClient>[];
    final owners = <LocalTaskSleepInhibitor>[];
    final errors = <Object>[];
    final abandoned = <int>[];
    provider.listen((request) async {
      try {
        final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
        final prompt = (body['input'] as List).lastWhere((item) => item['role'] == 'user')['content'] as String;
        request.response.headers.contentType = ContentType('text', 'event-stream');
        request.response.bufferOutput = false;
        request.response.write('data: {"type":"response.created"}\n\n');
        await request.response.flush();
        replies[prompt] = request.response;
        await release.future;
      } finally {
        await request.response.close();
      }
    });

    Future<({AgentServer server, AgentClient client})> open(String name, {bool embedded = false}) async {
      final directory = await Directory('${root.path}/$name').create();
      await File('${directory.path}/config.yaml').writeAsString('{}');
      await File('${directory.path}/auth.json').writeAsString(jsonEncode({
        'type': 'chatgpt', 'access_token': 'fixture', 'refresh_token': 'fixture', 'account_id': 'fixture',
        'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
      }));
      final server = embedded
        ? await AgentServer.startEmbedded(directory: directory.path, configPath: '${directory.path}/config.yaml',
            endpoint: 'http://127.0.0.1:${provider.port}/responses')
        : await AgentServer.start(directory: directory.path, configPath: '${directory.path}/config.yaml', port: 0,
            endpoint: 'http://127.0.0.1:${provider.port}/responses');
      servers.add(server);
      final client = await AgentClient.connect(server.uri, token: server.token);
      clients.add(client);
      return (server: server, client: client);
    }

    Future<String> start(AgentClient client, String prompt) async {
      final result = jsonObject(await client.request('task.start', {'cwd': root.path, 'prompt': prompt}));
      await _until(() => replies.containsKey(prompt));
      return result['task_id'] as String;
    }

    Future<void> reply(String prompt, {bool fail = false}) async {
      replies[prompt]!.write('data: ${jsonEncode(fail
        ? {'type': 'response.failed', 'response': {'status': 'failed', 'error': {'code': 'invalid_prompt', 'message': 'Fixture failure'}}}
        : {'type': 'response.completed', 'response': {'status': 'completed', 'output': []}})}\n\n');
      await replies[prompt]!.close();
    }

    LocalTaskSleepInhibitor watch(AgentServer server) {
      final owner = LocalTaskSleepInhibitor(server, onError: errors.add);
      owners.add(owner);
      return owner;
    }

    try {
      final local = await open('local', embedded: true);
      // A second server reached over TCP models another machine's task owner.
      final remote = await open('remote');
      final remoteTask = await start(remote.client, 'remote');
      // Native assertions can survive a Dart hot restart in the same process.
      abandoned.add(_createFixtureAssertion('Happen / Running local tasks'));
      abandoned.add(_createFixtureAssertion('Happen / Unrelated operation'));
      expect(await _assertions(), hasLength(1));
      final owner = watch(local.server);
      await _until(() async => (await _assertions()).isEmpty);
      expect(await _assertions('Happen / Unrelated operation'), hasLength(1),
        reason: 'Startup recovery must leave unrelated power assertions alone');
      expect(await _assertions(), isEmpty, reason: 'An active remote task cannot hold local wake');

      final activity = <int>[];
      final subscription = local.server.activeTaskCounts.listen(activity.add);
      addTearDown(subscription.cancel);
      final first = await start(local.client, 'first');
      await _until(() async => (await _assertions()).length == 1);
      final assertion = (await _assertions()).single;
      final second = await start(local.client, 'second');
      expect(local.server.activeTaskCount, 2);
      expect(await _assertions(), [assertion], reason: 'Concurrent tasks share one assertion');
      await local.client.request('task.cancel', {'task_id': second});
      await _until(() => local.server.activeTaskCount == 1);
      expect(await _assertions(), [assertion], reason: 'Stopping one task keeps the other awake');

      await local.client.request('task.send', {'task_id': first, 'prompt': 'queued', 'delivery': 'queue'});
      activity.clear();
      await reply('first');
      await _until(() => replies.containsKey('queued'));
      expect(activity, isNot(contains(0)), reason: 'Queued handoff cannot publish a false idle interval');
      expect(await _assertions(), [assertion]);
      await reply('queued');
      await _until(() => local.server.activeTaskCount == 0);
      await _until(() async => (await _assertions()).isEmpty);
      expect(remote.server.activeTaskCount, 1);
      expect(jsonObject(await remote.client.request('task.subscribe', {'task_id': remoteTask}))['running'], isTrue);

      await start(local.client, 'failure');
      await _until(() async => (await _assertions()).length == 1);
      final failed = local.client.events.stream.firstWhere((event) => event['type'] == 'turn.failed');
      await reply('failure', fail: true);
      await failed.timeout(const Duration(seconds: 10));
      await _until(() async => (await _assertions()).isEmpty);

      final archived = await start(local.client, 'archive');
      await _until(() async => (await _assertions()).length == 1);
      await local.client.request('task.archive', {'task_id': archived});
      await _until(() async => (await _assertions()).isEmpty);

      await owner.close();
      await start(local.client, 'existing');
      // Attach to an already-busy embedded server, as on a hot reload.
      final adopted = watch(local.server);
      await _until(() async => (await _assertions()).length == 1);
      await adopted.close();
      expect(await _assertions(), isEmpty, reason: 'Disposal releases wake even while the task continues');
      expect(local.server.activeTaskCount, 1);
      final closing = watch(local.server);
      await Future<void>.delayed(Duration.zero);
      await closing.close();
      expect(await _assertions(), isEmpty, reason: 'Disposal must drain an in-flight native transition');

      watch(local.server);
      await _until(() async => (await _assertions()).length == 1);
      await local.server.close();
      await _until(() async => (await _assertions()).isEmpty);
      expect(errors, isEmpty);
    } finally {
      for (final owner in owners) { await owner.close(); }
      for (final client in clients) { await client.close(); }
      for (final server in servers) { await server.close(); }
      for (final id in abandoned) { _releaseFixtureAssertion(id); }
      release.complete();
      await provider.close(force: true);
      await root.delete(recursive: true);
    }
  }, skip: !Platform.isMacOS, timeout: const Timeout(Duration(minutes: 1)));
}

Future<List<String>> _assertions([String name = 'Happen / Running local tasks']) async {
  final result = await Process.run('/usr/bin/pmset', ['-g', 'assertions']);
  expect(result.exitCode, 0);
  final lines = (result.stdout as String).split('\n').where((line) =>
    line.contains('pid $pid(') && line.contains('named: "$name"'));
  return lines.map((line) {
    expect(line, contains('PreventUserIdleSystemSleep'), reason: 'Task activity must not request display wake');
    return RegExp(r'\[([^\]]+)\]').firstMatch(line)!.group(1)!;
  }).toList();
}

// Inject an independent OS resource with no Dart owner, modeling lost VM state.
int _createFixtureAssertion(String name) => using((arena) {
  final cf = DynamicLibrary.open('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation');
  final string = cf.lookupFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, Uint32), Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, int)>('CFStringCreateWithCString');
  final release = cf.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('CFRelease');
  Pointer<Void> value(String text) {
    final result = string(nullptr, text.toNativeUtf8(allocator: arena), 0x08000100);
    arena.onReleaseAll(() => release(result));
    return result;
  }
  final io = DynamicLibrary.open('/System/Library/Frameworks/IOKit.framework/IOKit');
  final create = io.lookupFunction<Int32 Function(Pointer<Void>, Uint32, Pointer<Void>, Pointer<Uint32>), int Function(Pointer<Void>, int, Pointer<Void>, Pointer<Uint32>)>('IOPMAssertionCreateWithName');
  final result = arena<Uint32>();
  expect(create(value('PreventUserIdleSystemSleep'), 255, value(name), result), 0);
  return result.value;
});

void _releaseFixtureAssertion(int id) {
  final io = DynamicLibrary.open('/System/Library/Frameworks/IOKit.framework/IOKit');
  // Recovery may already have released it.
  io.lookupFunction<Int32 Function(Uint32), int Function(int)>('IOPMAssertionRelease')(id);
}

Future<void> _until(FutureOr<bool> Function() condition) async {
  final clock = Stopwatch()..start();
  while (!await condition()) {
    if (clock.elapsed > const Duration(seconds: 10)) fail('Task or native power assertion did not settle');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
