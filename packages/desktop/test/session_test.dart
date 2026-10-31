import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop/database.dart';
import 'package:desktop/session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

void main() {
  test('streams nested code-mode calls, cancels, and keeps tasks through remote changes', () async {
    final root = await Directory.systemTemp.createTemp('desktop-contract-');
    final work = await Directory('${root.path}/work').create();
    final firstReply = Completer<void>(), heldReply = Completer<void>();
    final requests = <Json>[];
    final provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    AgentServer? server;
    DesktopSession? session;
    await File('${root.path}/config.yaml').writeAsString('{}');
    await File('${root.path}/auth.json').writeAsString(
      jsonEncode({
        'type': 'chatgpt',
        'access_token': 'fixture-access-secret',
        'refresh_token': 'fixture-refresh-secret',
        'account_id': 'fixture',
        'expires_at': DateTime.now()
            .add(const Duration(hours: 1))
            .millisecondsSinceEpoch,
      }),
    );
    await File('${work.path}/input.txt').writeAsString('from a real tool');

    provider.listen((request) async {
      try {
        final body = jsonObject(
          jsonDecode(await utf8.decoder.bind(request).join()),
        );
        requests.add(body);
        final input = (body['input'] as List).map(jsonObject).toList();
        final prompt = input.lastWhere(
          (item) => item['role'] == 'user',
        )['content'];
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        request.response.bufferOutput = false;
        if (prompt == 'hold') {
          request.response.write(
            'data: {"type":"response.output_text.delta","delta":"Waiting"}\n\n',
          );
          await request.response.flush();
          await heldReply.future;
          return;
        }
        final called = input.any(
          (item) => item['type'] == 'custom_tool_call_output',
        );
        if (called) {
          request.response.write(
            'data: {"type":"response.output_text.delta","delta":"Hello"}\n\n',
          );
          await request.response.flush();
          await firstReply.future;
        }
        request.response.write(
          'data: ${jsonEncode({
            'type': 'response.completed',
            'response': {
              'status': 'completed',
              'output': called ? [
                      {
                        'type': 'message',
                        'role': 'assistant',
                        'content': [
                          {'type': 'output_text', 'text': 'Hello from the server.'},
                        ],
                      },
                    ] : [
                      {'type': 'custom_tool_call', 'namespace': 'functions', 'call_id': 'cell-1', 'name': 'exec', 'input': 'await Promise.all([1, 2].map(async () => text(await tools.exec_command({cmd: "cat input.txt", login: false}))));'},
                    ],
              'usage': {'input_tokens': 10, 'output_tokens': 5},
            },
          })}\n\n',
        );
      } finally {
        await request.response.close();
      }
    });

    Future<DesktopSession> open() async {
      server = await AgentServer.startEmbedded(
        directory: root.path,
        configPath: '${root.path}/config.yaml',
        endpoint: 'http://127.0.0.1:${provider.port}/responses',
      );
      expect(server!.uri.scheme, 'unix');
      final client = await AgentClient.connect(server!.uri);
      session = DesktopSession(client, await openDesktopDatabase(root.path));
      await session!.load();
      return session!;
    }

    Future<void> git(List<String> args) async {
      final result = await Process.run('git', ['-C', work.path, ...args]);
      expect(result.exitCode, 0);
    }

    try {
      await git(['init', '-q']);
      var desktop = await open();
      expect(desktop.providers.first['status'], 'signed_in');
      expect(
        jsonEncode(desktop.providers),
        isNot(contains('fixture-access-secret')),
      );
      expect(
        jsonEncode(desktop.providers),
        isNot(contains('fixture-refresh-secret')),
      );
      await desktop.addProject(work.path);
      final path = await work.resolveSymbolicLinks();
      expect(desktop.project!.id, path);
      desktop.chooseModel('gpt-6-astra');
      desktop.chooseReasoning('low');
      expect(await desktop.send('hello'), isTrue);
      await _until(desktop, () => desktop.task!.streamingText == 'Hello');
      expect(desktop.task!.running, isTrue);
      final streamed = conversation(desktop.task!);
      expect(streamed.last.text, 'Hello');
      final cell = streamed.singleWhere((entry) => entry.tool != null).tool!;
      expect(cell.name, 'functions.exec');
      expect(cell.children.map((child) => child.name), [
        'exec_command',
        'exec_command',
      ]);
      expect(cell.children.every((child) => child.status == 'done'), isTrue);
      expect(
        cell.children.every(
          (child) => child.output!.contains('from a real tool'),
        ),
        isTrue,
      );
      expect(requests.first['model'], 'gpt-6-astra');
      expect(requests.first['reasoning']['effort'], 'low');
      await desktop.chooseDeliveryMode('queue');
      expect(await desktop.send('queued follow-up'), isTrue);
      await desktop.chooseDeliveryMode('steer');
      expect(await desktop.send('steer this turn'), isTrue);
      expect(desktop.task!.pending.length, 2);
      expect(conversation(desktop.task!).map((e) => e.role), containsAll(['Queued', 'Steer pending']));
      final pendingTimes = {
        for (final entry in conversation(desktop.task!).where((entry) => entry.role == 'Queued' || entry.role == 'Steer pending'))
          entry.text: entry.timestamp,
      };
      expect(pendingTimes.keys, unorderedEquals(['queued follow-up', 'steer this turn']));
      expect(pendingTimes.values, everyElement(isNotNull), reason: 'Pending messages show their actual send time');
      expect(desktop.task!.events.values.where((e) => e['type'] == 'turn.started').length, 1);
      firstReply.complete();
      await _until(desktop, () => !desktop.task!.running && desktop.task!.pending.isEmpty);
      expect(
        conversation(desktop.task!)
            .where((entry) => entry.role == 'Happen')
            .map((entry) => entry.text),
        List.filled(3, 'Hello from the server.'),
      );
      final timeline = desktop.task!.events.values.toList();
      final starts = timeline.where((e) => e['type'] == 'turn.started').toList();
      expect(starts.length, 2);
      final inputs = timeline.where((e) => e['type'] == 'input.committed').toList();
      expect(inputs.length, 3);
      final committedMessages = conversation(desktop.task!).where((entry) => pendingTimes.containsKey(entry.text)).toList();
      expect(committedMessages, hasLength(2));
      for (final entry in committedMessages) {
        expect(entry.timestamp, pendingTimes[entry.text], reason: 'Processing a queued message must not change its send time');
      }
      expect(inputs[1]['turn_id'], starts[0]['turn_id']);
      expect(inputs[2]['turn_id'], starts[1]['turn_id']);
      expect((requests[2]['input'] as List).where((e) => e['role'] == 'user').last['content'], 'steer this turn');
      expect((requests[2]['input'] as List).any((e) => e['content'] == 'queued follow-up'), isFalse);
      expect((requests.last['input'] as List).where((e) => e['role'] == 'user').last['content'], 'queued follow-up');
      final taskId = desktop.task!.id;

      desktop.chooseReasoning('high');
      expect(await desktop.send('hold'), isTrue, reason: desktop.error);
      await _until(desktop, () => desktop.task!.streamingText == 'Waiting');
      expect(
        (requests.last['input'] as List).any(
          (item) => item['type'] == 'configuration_update',
        ),
        isTrue,
      );
      await desktop.chooseDeliveryMode('queue');
      expect(await desktop.send('must not run after stop'), isTrue);
      expect(desktop.task!.pending.length, 1);
      await desktop.stop();
      await _until(desktop, () => !desktop.task!.running);
      expect(conversation(desktop.task!).last.text, 'Stopped');
      expect(desktop.task!.pending, isEmpty);
      await desktop.chooseProvider('deepseek');
      expect(desktop.providerId, 'gpt');
      expect(desktop.defaultProviderId, 'deepseek');
      final archivedTask = desktop.task!;
      await desktop.setArchived(archivedTask, true);
      expect(desktop.task, isNull);
      expect(archivedTask.archived, isTrue);

      for (final (url, expected) in [
        ('git@github.com:acme/project.git', 'https://github.com/acme/project'),
        (
          'https://github.com/acme/renamed.git',
          'https://github.com/acme/renamed',
        ),
        ('', path),
        (
          'ssh://git@github.com/acme/again.git',
          'https://github.com/acme/again',
        ),
      ]) {
        await Process.run('git', [
          '-C',
          work.path,
          'config',
          '--remove-section',
          'remote.origin',
        ]);
        if (url.isNotEmpty) await git(['config', 'remote.origin.url', url]);
        await desktop.refreshProjects();
        expect(desktop.project!.id, expected);
        expect(desktop.project!.tasks.single.id, taskId);
      }

      await desktop.close();
      session = null;
      await server!.close();
      server = null;
      desktop = await open();
      expect(desktop.defaultProviderId, 'deepseek');
      expect(desktop.deliveryMode, 'queue');
      expect(desktop.project!.id, 'https://github.com/acme/again');
      expect(desktop.project!.tasks.single.id, taskId);
      expect(desktop.project!.tasks.single.archived, isTrue);
      await desktop.select(desktop.project!, desktop.project!.tasks.single);
      expect(await desktop.send('archived tasks are read-only'), isFalse);
      await desktop.setArchived(desktop.task!, false);
      expect(desktop.task!.model, 'gpt-6-astra');
      expect(desktop.task!.reasoning, 'high');
      final restored = conversation(desktop.task!);
      final restoredMessages = restored.where((entry) => pendingTimes.containsKey(entry.text)).toList();
      expect(restoredMessages, hasLength(2));
      for (final entry in restoredMessages) {
        expect(entry.timestamp, pendingTimes[entry.text], reason: 'Send times survive server and desktop restart');
      }
      final completedTurns = restored.where((entry) => entry.role == 'Status' && entry.text == 'Completed').toList();
      expect(completedTurns.length, 2);
      for (final entry in completedTurns) {
        expect(entry.startedAt, isNotNull);
        expect(entry.timestamp!.isAfter(entry.startedAt!), isTrue);
      }
      expect(
        restored
            .where((entry) => entry.role == 'Happen')
            .map((entry) => entry.text),
        List.filled(3, 'Hello from the server.'),
      );
      expect(
        restored
            .singleWhere((entry) => entry.tool != null)
            .tool!
            .children
            .length,
        2,
      );
      expect(restored.last.text, 'Stopped');
      await desktop.signOut('gpt');
      expect(desktop.authenticated, isFalse);
      expect(await File('${root.path}/auth.json').exists(), isFalse);
    } finally {
      if (!firstReply.isCompleted) firstReply.complete();
      if (!heldReply.isCompleted) heldReply.complete();
      await session?.close();
      await server?.close();
      await provider.close(force: true);
      await root.delete(recursive: true);
    }
  });

  test('desktop sign-in opens OAuth and releases it on cancel or denial', () async {
    final root = await Directory.systemTemp.createTemp('desktop-login-');
    await File('${root.path}/config.yaml').writeAsString('{}');
    final server = await AgentServer.startEmbedded(
      directory: root.path, configPath: '${root.path}/config.yaml',
    );
    final session = DesktopSession(
      await AgentClient.connect(server.uri), await openDesktopDatabase(root.path),
    );
    final http = HttpClient();
    try {
      await session.load();
      var opened = Completer<Uri>();
      Future<void> open(String url) async { opened.complete(Uri.parse(url)); }
      var signing = session.signIn('gpt', open);
      final url = await opened.future.timeout(const Duration(seconds: 5));
      expect(url.host, 'auth.openai.com');
      expect(url.path, '/oauth/authorize');
      expect(session.signingIn, isTrue);
      await session.cancelLogin();
      await signing;
      expect(session.signingIn, isFalse);
      expect(session.loginUrl, isNull);
      expect(session.loginError, isNull);

      // Reusing the fixed callback port proves cancellation released the listener.
      opened = Completer<Uri>();
      signing = session.signIn('gpt', open);
      final retry = await opened.future.timeout(const Duration(seconds: 5));
      final response = await (await http.getUrl(Uri(
        scheme: 'http', host: '127.0.0.1', port: 1455, path: '/auth/callback',
        queryParameters: {'state': retry.queryParameters['state']!, 'error': 'access_denied'},
      ))).close();
      await response.drain<void>();
      await signing;
      expect(session.loginError, contains('declined'));
      expect(session.providers.first['status'], 'signed_out');
      expect(await File('${root.path}/auth.json').exists(), isFalse);
    } finally {
      http.close(force: true);
      await session.close();
      await server.close();
      await root.delete(recursive: true);
    }
  });
}

Future<void> _until(DesktopSession session, bool Function() condition) async {
  if (condition()) return;
  final done = Completer<void>();
  void listener() {
    if (done.isCompleted) return;
    final failures = session.task?.events.values.where(
      (e) => e['type'] == 'turn.failed',
    );
    if (failures?.isNotEmpty == true) {
      done.completeError(StateError('${failures!.last['data']['error']}'));
    } else if (condition()) {
      done.complete();
    }
  }

  session.addListener(listener);
  try {
    await done.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        throw StateError(
          'Desktop did not update: ${session.error}; events: ${session.task?.events.values.map((e) => e['type']).toList()}',
        );
      },
    );
  } finally {
    session.removeListener(listener);
  }
}
