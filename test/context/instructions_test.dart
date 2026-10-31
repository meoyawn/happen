import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';

void main() {
  late Directory root, data;
  late HttpServer provider;
  late AgentServer server;
  late AgentClient client;
  final requests = <Json>[];

  Future<void> start() async {
    server = await AgentServer.startEmbedded(
      directory: data.path,
      configPath: '${data.path}/config.yaml',
      endpoint: 'http://127.0.0.1:${provider.port}/responses',
    );
    client = await AgentClient.connect(server.uri);
  }

  setUp(() async {
    requests.clear();
    root = await Directory.systemTemp.createTemp('server-agents-md-');
    data = await Directory('${root.path}/data').create();
    await File('${data.path}/auth.json').writeAsString(jsonEncode({
      'type': 'chatgpt',
      'access_token': 'fixture',
      'refresh_token': 'fixture',
      'account_id': 'fixture',
      'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
    }));
    provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    provider.listen((request) async {
      requests.add(jsonObject(jsonDecode(await utf8.decoder.bind(request).join())));
      request.response.headers.contentType = ContentType('text', 'event-stream');
      request.response.write('data: ${jsonEncode({
        'type': 'response.completed',
        'response': {
          'status': 'completed',
          'output': [{
            'type': 'message',
            'role': 'assistant',
            'content': [{'type': 'output_text', 'text': 'Ready'}],
          }],
          'usage': {'input_tokens': 100, 'output_tokens': 10},
        },
      })}\n\n');
      await request.response.close();
    });
    await start();
  });

  tearDown(() async {
    await client.close();
    await server.close();
    await provider.close(force: true);
    await root.delete(recursive: true);
  });

  Future<String> turn(String method, Json params) async {
    final terminal = client.events.stream.firstWhere((event) =>
      ['turn.completed', 'turn.failed', 'turn.cancelled'].contains(event['type']),
    );
    await client.request(method, {...params, 'prompt': 'continue'});
    final result = await terminal.timeout(const Duration(seconds: 15));
    expect(result['type'], 'turn.completed', reason: result.toString());
    return result['task_id'] as String;
  }

  List<String> instructions() => (requests.last['input'] as List)
      .where((item) => item['role'] == 'user')
      .map((item) => item['content'] is String ? item['content'] as String
          : (item['content'] as List).map((part) => part['text'] ?? '').join())
      .where((text) => text.startsWith('# AGENTS.md instructions'))
      .toList();

  Future<List<Json>> updates(String id) async =>
      (await client.request('history.page', {'task_id': id, 'limit': 500}) as List)
          .map(jsonObject).where((event) => event['type'] == 'agents.updated').toList();

  test('multi-turn repository context stays deduplicated and reloads on cwd changes and cold resumes', () async {
    final work = await Directory('${root.path}/repo/sub/deeper').create(recursive: true);
    final repo = work.parent.parent;
    final cwd = work.parent.path;
    await File('${repo.path}/.git').writeAsString('gitdir: /unused-worktree-marker');
    await File('${root.path}/AGENTS.md').writeAsString('outside repository');
    final parent = File('${repo.path}/AGENTS.md');
    final override = File('$cwd/AGENTS.override.md');
    final regular = File('$cwd/AGENTS.md');
    await parent.writeAsString('parent maple');
    await override.writeAsString('nested override');
    await regular.writeAsString('nested regular');
    await File('${work.path}/AGENTS.md').writeAsString('unvisited descendant');

    final id = await turn('task.start', {'cwd': cwd});
    final initial = instructions().single;
    expect(initial, contains('parent maple'));
    expect(initial, contains('nested override'));
    expect(initial.indexOf('parent maple'), lessThan(initial.indexOf('nested override')));
    expect(initial, isNot(contains('nested regular')));
    expect(initial, isNot(contains('outside repository')));
    expect(initial, isNot(contains('unvisited descendant')));
    final prefix = requests.last['input'] as List;

    await parent.writeAsString('parent cedar');
    await override.delete();
    var previousInput = prefix;
    for (var i = 0; i < 4; i++) {
      await turn('task.send', {'task_id': id});
      expect(instructions(), [initial]);
      final input = requests.last['input'] as List;
      expect(input.take(previousInput.length).toList(), previousInput);
      // This fixture adds only the previous assistant reply and the new user input.
      expect(input.length, previousInput.length + 2);
      expect(requests.last['instructions'], requests.first['instructions']);
      expect(requests.last['tools'], requests.first['tools']);
      previousInput = input;
    }
    expect((await updates(id)).length, 1);

    await turn('task.start', {'cwd': cwd});
    expect(instructions().single, contains('parent cedar'));
    expect(instructions().single, contains('nested regular'));

    final plain = await Directory('${root.path}/plain/sub').create(recursive: true);
    await File('${plain.parent.path}/AGENTS.md').writeAsString('plain parent excluded');
    await File('${plain.path}/AGENTS.md').writeAsString('plain directory');
    await turn('task.send', {'task_id': id, 'cwd': plain.path});
    expect(instructions().last, contains('replace all previously provided AGENTS.md instructions.'));
    expect(instructions().last, contains('plain directory'));
    expect(instructions().last, isNot(contains('plain parent excluded')));
    expect(instructions().last, isNot(contains('parent cedar')));
    final changed = (await updates(id)).length;
    for (var i = 0; i < 3; i++) {
      await turn('task.send', {'task_id': id});
      expect((await updates(id)).length, changed);
    }

    await turn('task.send', {'task_id': id, 'cwd': cwd});
    expect(instructions().last, contains('parent cedar'));
    expect(instructions().last, contains('nested regular'));
    final beforeColdResume = instructions();
    await client.close();
    await server.close();
    await start();
    await turn('task.send', {'task_id': id});
    expect(instructions(), beforeColdResume);
    await parent.delete();
    await regular.delete();
    final beforeRestart = instructions();
    await turn('task.send', {'task_id': id});
    expect(instructions(), beforeRestart);

    await client.close();
    await server.close();
    await start();
    await turn('task.send', {'task_id': id});
    expect(instructions().take(beforeRestart.length).toList(), beforeRestart);
    expect(instructions().last,
      contains('The previously provided AGENTS.md instructions no longer apply.'));
    final removals = (await updates(id)).length;
    for (var i = 0; i < 3; i++) {
      await turn('task.send', {'task_id': id});
      expect((await updates(id)).length, removals);
    }

    await turn('task.start', {'cwd': cwd});
    expect(instructions(), isEmpty);
  });

  test('project instruction budgets count UTF-8 bytes across the ancestor chain', () async {
    final work = await Directory('${root.path}/repo/sub').create(recursive: true);
    await Directory('${work.parent.path}/.git').create();
    await File('${work.parent.path}/AGENTS.md').writeAsString('a' * 32765);
    await File('${work.path}/AGENTS.md').writeAsString('ééSECRET_TAIL');
    await File('${data.path}/AGENTS.md').writeAsString('global independent budget');

    final id = await turn('task.start', {'cwd': work.path});
    final snapshot = (await updates(id)).single['data']['snapshot'];
    final files = (snapshot['files'] as List).map(jsonObject).toList();
    expect(files.map((file) => file['text']), ['global independent budget', 'a' * 32765, 'é�']);
    expect(files.last['truncated'], isTrue);
    expect(snapshot['truncated'], isTrue);
    expect(instructions().single, contains('Instruction budget reached'));
    expect(instructions().single, isNot(contains('SECRET_TAIL')));
  });

  test('project overrides select one file per directory and allow symlinked instruction files', () async {
    final work = await Directory('${root.path}/repo/sub').create(recursive: true);
    await Directory('${work.parent.path}/.git').create();
    final parent = File('${work.parent.path}/AGENTS.md');
    await parent.writeAsString('suppressed regular instruction');
    final overridePath = '${work.parent.path}/AGENTS.override.md';
    await File(overridePath).writeAsString(' \n');
    await File('${work.path}/AGENTS.md').writeAsString('child instruction');

    await turn('task.start', {'cwd': work.path});
    expect(instructions().single, contains('child instruction'));
    expect(instructions().single, isNot(contains('suppressed regular instruction')));
    await File(overridePath).delete();
    await Directory(overridePath).create();
    await turn('task.start', {'cwd': work.path});
    expect(instructions().single, contains('suppressed regular instruction'));

    await Directory(overridePath).delete();
    final target = File('${root.path}/linked.md');
    await target.writeAsString('linked instruction');
    await Link(overridePath).create(target.path);
    await turn('task.start', {'cwd': work.path});
    expect(instructions().single, contains('linked instruction'));
    expect(instructions().single, isNot(contains('suppressed regular instruction')));
  });
}
