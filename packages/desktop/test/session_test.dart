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
      desktop.chooseModel('gpt-6-luna');
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
      expect(requests.first['model'], 'gpt-6-luna');
      expect(requests.first['reasoning']['effort'], 'low');
      firstReply.complete();
      await _until(desktop, () => !desktop.task!.running);
      expect(
        conversation(desktop.task!)
            .where((entry) => entry.role == 'Happen')
            .map((entry) => entry.text),
        ['Hello from the server.'],
      );
      final taskId = desktop.task!.id;

      desktop.chooseReasoning('high');
      expect(await desktop.send('hold'), isTrue);
      await _until(desktop, () => desktop.task!.streamingText == 'Waiting');
      expect(
        (requests.last['input'] as List).any(
          (item) => item['type'] == 'configuration_update',
        ),
        isTrue,
      );
      await desktop.stop();
      await _until(desktop, () => !desktop.task!.running);
      expect(conversation(desktop.task!).last.text, 'Stopped');

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
      expect(desktop.project!.id, 'https://github.com/acme/again');
      expect(desktop.project!.tasks.single.id, taskId);
      await desktop.select(desktop.project!, desktop.project!.tasks.single);
      expect(desktop.task!.model, 'gpt-6-luna');
      expect(desktop.task!.reasoning, 'high');
      final restored = conversation(desktop.task!);
      expect(
        restored
            .where((entry) => entry.role == 'Happen')
            .map((entry) => entry.text),
        ['Hello from the server.'],
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
    } finally {
      if (!firstReply.isCompleted) firstReply.complete();
      if (!heldReply.isCompleted) heldReply.complete();
      await session?.close();
      await server?.close();
      await provider.close(force: true);
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
