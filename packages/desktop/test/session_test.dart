import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:desktop/composer_attachments.dart';
import 'package:desktop/database.dart';
import 'package:desktop/session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

void main() {
  test('composer model selections route new tasks through ChatGPT and OpenCode', () async {
    final root = await Directory.systemTemp.createTemp('desktop-models-');
    final provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    AgentServer? server;
    DesktopSession? desktop;
    addTearDown(() async {
      await desktop?.close();
      await server?.close();
      await provider.close(force: true);
      await root.delete(recursive: true);
    });
    await File('${root.path}/config.yaml').writeAsString(jsonEncode({
      'default_provider': 'opencode',
      'providers': {'opencode': {'endpoint': 'http://127.0.0.1:${provider.port}/v1'}},
    }));
    final expires = DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch;
    await File('${root.path}/auth.json').writeAsString(jsonEncode({
      'type': 'chatgpt', 'access_token': 'fixture', 'refresh_token': 'fixture',
      'account_id': 'fixture', 'expires_at': expires,
    }));
    await File('${root.path}/opencode-auth.json').writeAsString(jsonEncode({
      'version': 1, 'type': 'opencode', 'server': 'https://opencode.ai/console',
      'access_token': 'fixture', 'refresh_token': 'fixture', 'org_id': 'fixture',
      'expires_at': expires,
    }));
    final requests = <({String path, Json body})>[];
    provider.listen((request) async {
      requests.add((path: request.uri.path,
        body: jsonObject(jsonDecode(await utf8.decoder.bind(request).join()))));
      request.response.headers.contentType = ContentType('text', 'event-stream');
      final response = request.uri.path == '/responses'
        ? {'type': 'response.completed', 'response': {
            'status': 'completed', 'output': [{'type': 'message', 'role': 'assistant',
              'content': [{'type': 'output_text', 'text': 'ChatGPT reply'}]}],
          }}
        : {'choices': [{'delta': {'content': 'OpenCode reply'}, 'finish_reason': 'stop'}]};
      request.response.write('data: ${jsonEncode(response)}\n\n');
      if (request.uri.path != '/responses') request.response.write('data: [DONE]\n\n');
      await request.response.close();
    });
    server = await AgentServer.start(directory: root.path, configPath: '${root.path}/config.yaml', port: 0,
      endpoint: 'http://127.0.0.1:${provider.port}/responses');
    final database = await openDesktopDatabase(root.path);
    await callIsolate(database.port, 'settings.set', {'key': 'provider', 'value': 'deepseek'});
    final session = desktop = DesktopSession(await AgentClient.connect(server.uri), database);
    await session.load();
    expect(session.providers.map((p) => p['id']), ['openai', 'opencode']);
    expect(session.models.map((m) => m['id']), isNot(contains('deepseek-flash')));
    expect(session.providerId, 'openai', reason: 'Desktop selection no longer follows a saved default provider');
    await session.addProject(root.path);
    for (final (id, model, effort, path, reply) in [
      ('opencode', 'deepseek-v4.1-flash-free', 'max', '/v1/chat/completions', 'OpenCode reply'),
      ('openai', 'gpt-6-astra', 'low', '/responses', 'ChatGPT reply'),
    ]) {
      await session.select(session.project!);
      session.chooseModel(model);
      session.chooseReasoning(effort);
      await session.refreshProviders();
      expect(session.providerId, id);
      expect(session.modelId, model);
      expect(session.reasoning, effort);
      expect(session.authenticated, true);
      expect(await session.send('Use the selected model'), true, reason: session.error);
      await _until(session, () => !session.task!.running);
      expect(requests.last.path, path);
      expect(requests.last.body['model'], model);
      expect(requests.last.body[id == 'openai' ? 'reasoning' : 'reasoning_effort'],
        id == 'openai' ? {'effort': effort} : effort);
      expect(session.task!.provider, id);
      expect(conversation(session.task!).where((entry) => entry.role == 'Happen').single.text, reply);
    }
  });

  test('remote desktop prepares a 100 MiB image before transport and preserves originals for retry', () async {
    final root = await Directory.systemTemp.createTemp('desktop-images-server-');
    final local = await Directory.systemTemp.createTemp('desktop-images-client-');
    final provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <WebSocket>[];
    final sent = <Json>[], modelInput = <Json>[];
    AgentServer? server;
    DesktopSession? desktop;
    await File('${root.path}/config.yaml').writeAsString('{}');
    await File('${root.path}/auth.json').writeAsString(jsonEncode({
      'type': 'chatgpt', 'access_token': 'fixture', 'refresh_token': 'fixture', 'account_id': 'fixture',
      'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
    }));
    provider.listen((request) async {
      modelInput.add(jsonObject(jsonDecode(await utf8.decoder.bind(request).join())));
      request.response.headers.contentType = ContentType('text', 'event-stream');
      request.response.write('data: ${jsonEncode({'type': 'response.completed', 'response': {
        'status': 'completed', 'output': [{'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'Received'}]}],
      }})}\n\n');
      await request.response.close();
    });
    try {
      server = await AgentServer.start(directory: root.path, configPath: '${root.path}/config.yaml', port: 0,
        endpoint: 'http://127.0.0.1:${provider.port}/responses');
      proxy.listen((request) async {
        final outgoing = await WebSocket.connect(server!.uri.toString());
        final incoming = await WebSocketTransformer.upgrade(request);
        sockets.addAll([incoming, outgoing]);
        incoming.listen((raw) {
          final message = jsonObject(jsonDecode(raw as String));
          if (message['method'] == 'task.start' || message['method'] == 'task.send') sent.add(message);
          outgoing.add(raw);
        }, onDone: outgoing.close);
        outgoing.listen(incoming.add, onDone: incoming.close);
      });
      final session = desktop = DesktopSession(
        await AgentClient.connect(Uri.parse('ws://127.0.0.1:${proxy.port}/ws')),
        await openDesktopDatabase(local.path), attachmentDirectory: '${local.path}/attachments',
      );
      await session.load();
      await session.addProject(root.path);
      final image = await _largeBitmap('${local.path}/100 MiB.bmp');
      final small = await File('${local.path}/small.png').writeAsBytes(base64Decode(_png));
      final file = await File('${local.path}/report.txt').writeAsString('File from another machine');
      final images = [
        ComposerAttachment(name: '100 MiB.bmp', path: image.path, image: true),
        ComposerAttachment(name: 'small.png', path: small.path, image: true),
      ];
      expect(await session.send('', attachments: [...images,
        ComposerAttachment(name: 'report.txt', path: file.path, image: false),
      ]), isTrue, reason: session.error);
      await _until(session, () => session.task?.running == false);
      final attachments = sent.single['params']['attachments'] as List;
      final transmittedImages = attachments.where((part) => part['type'] == 'image').toList();
      expect(transmittedImages, hasLength(2));
      expect(transmittedImages.any((part) => part.containsKey('path') || part.containsKey('upload_id')), isFalse);
      expect(transmittedImages.fold<int>(0, (size, part) => size + attachmentDataUrl(jsonObject(part)).length), lessThanOrEqualTo(32 * 1024 * 1024));
      final header = ByteData.sublistView(base64Decode(transmittedImages.first['data'] as String));
      expect((header.getUint32(16), header.getUint32(20)), (1600, 1600));
      expect(transmittedImages.last['data'], _png, reason: 'Small source bytes should be unchanged');
      expect(modelInput, hasLength(1));
      final user = (modelInput.single['input'] as List).lastWhere((item) => item['role'] == 'user');
      expect((user['content'] as List).where((part) => part['type'] == 'input_image'), hasLength(2));
      expect(await image.length(), 100 * 1024 * 1024 + 54);

      void cancelPreparation() {
        if (session.attachmentStatus == 'Preparing images…') session.cancelUpload();
      }
      session.addListener(cancelPreparation);
      await expectLater(session.send('', attachments: images), throwsA(isA<CancelledException>()));
      session.removeListener(cancelPreparation);
      expect(sent, hasLength(1));
      expect(session.submitting, isFalse);
      expect(await image.exists(), isTrue);
      final oversized = await File('${local.path}/too-large.png').open(mode: FileMode.write);
      try { await oversized.truncate(1024 * 1024 * 1024 + 1); } finally { await oversized.close(); }
      expect(await session.send('', attachments: [
        ComposerAttachment(name: 'too-large.png', path: '${local.path}/too-large.png', image: true),
      ]), isFalse);
      expect(session.error, contains('1 GiB'));
      expect(sent, hasLength(1));
    } finally {
      await desktop?.close();
      for (final socket in sockets) { await socket.close(); }
      await server?.close();
      await proxy.close(force: true);
      await provider.close(force: true);
      await root.delete(recursive: true);
      await local.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

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
          if (prompt == 'hello') {
            request.response.write(
              'data: {"type":"response.output_text.delta","delta":"Hello"}\n\n',
            );
            await request.response.flush();
          }
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
      expect(desktop.dictationMode, 'live');
      await desktop.chooseDictationMode('on_stop');
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
      final configuration = desktop.task!.events.values.where((event) => event['type'] == 'task.created').toList();
      expect(configuration, hasLength(1), reason: 'A fresh task needs its context limit before history replay');
      expect(configuration.single['data']['provider_settings']['context_limit'], 272000);
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
      desktop.chooseReasoning('max');
      expect(desktop.reasoning, 'max');
      expect(await desktop.send('queued follow-up'), isTrue, reason: desktop.error);
      final pendingTimes = {
        'queued follow-up': conversation(desktop.task!).singleWhere((entry) => entry.role == 'Queued').timestamp,
      };
      await desktop.chooseDeliveryMode('steer');
      desktop.chooseReasoning('high');
      expect(desktop.reasoning, 'high');
      final steeredPending = desktop.client.events.stream.firstWhere((event) => event['type'] == 'input.pending' && event['data']['prompt'] == 'steer this turn');
      expect(await desktop.send('steer this turn'), isTrue, reason: desktop.error);
      pendingTimes['steer this turn'] = DateTime.parse((await steeredPending)['data']['created_at'] as String);
      await _until(desktop, () => desktop.task!.pending.length == 1);
      expect(desktop.task!.streamingText, isEmpty, reason: 'Interrupted inference must not leave abandoned partial text visible');
      expect(desktop.task!.retryStatus, isNull, reason: 'Steering is an input change, not stream recovery');
      await expectLater(desktop.client.request('task.send', {
        'task_id': desktop.task!.id, 'prompt': 'invalid effort', 'reasoning': 'ultra',
      }), throwsA(isA<StateError>().having((error) => error.message, 'message', contains('Unsupported single-agent GPT reasoning effort'))));
      await expectLater(desktop.client.request('task.send', {
        'task_id': desktop.task!.id, 'prompt': 'change model', 'model': 'gpt-6.1-sol',
      }), throwsStateError);
      expect(desktop.task!.pending.length, 1);
      expect(conversation(desktop.task!).map((e) => e.role), contains('Queued'));
      expect(pendingTimes.keys, unorderedEquals(['queued follow-up', 'steer this turn']));
      expect(pendingTimes.values, everyElement(isNotNull), reason: 'Pending messages show their actual send time');
      expect(desktop.task!.events.values.where((e) => e['type'] == 'turn.started').length, 1);
      desktop.chooseReasoning('medium');
      firstReply.complete();
      await _until(desktop, () => !desktop.task!.running && desktop.task!.pending.isEmpty);
      expect(
        conversation(desktop.task!)
            .where((entry) => entry.role == 'Happen')
            .map((entry) => entry.text),
        List.filled(2, 'Hello from the server.'),
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
      for (final (request, effort) in [(requests[2], 'high'), (requests.last, 'max')]) {
        final input = (request['input'] as List).map(jsonObject).toList();
        final user = input.lastIndexWhere((item) => item['role'] == 'user');
        expect(input[user - 1], {'type': 'configuration_update', 'reasoning': {'effort': effort}});
      }
      for (final request in requests) {
        expect(request['reasoning'], {'effort': 'low'});
        expect(request['instructions'], requests.first['instructions']);
        expect(request['tools'], requests.first['tools']);
      }
      expect(requests[2]['input'].take((requests[1]['input'] as List).length), requests[1]['input']);
      expect(requests.last['input'].take((requests[2]['input'] as List).length), requests[2]['input']);
      expect(desktop.task!.reasoning, 'max');
      expect(desktop.reasoning, 'medium', reason: 'Committed updates must preserve a newer unsent selection');
      final taskId = desktop.task!.id;

      final cached = desktop.task!;
      final createdId = cached.events.remove(1)!['id'];
      final eventCount = cached.events.length;
      desktop.drafts[taskId] = 'Keep this draft';
      expect(cached.loaded, isTrue);
      await desktop.select(desktop.project!, cached);
      expect(cached.events[1]?['data']['provider_settings']['context_limit'], 272000,
        reason: 'A live-only cache missing admission must recover the frozen context limit');
      expect(cached.events[1]?['id'], createdId);
      expect(cached.events.length, eventCount + 1, reason: 'History replay must not duplicate live token usage');
      expect(desktop.drafts[taskId], 'Keep this draft');
      expect(desktop.reasoning, 'medium');

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
      desktop.chooseModel('deepseek-v4.1-flash-free');
      expect(desktop.providerId, 'openai');
      expect(desktop.modelId, 'gpt-6-astra');
      final archivedTask = desktop.task!;
      await desktop.setArchived(archivedTask, true);
      expect(desktop.task, isNull);
      expect(archivedTask.archived, isTrue);
      desktop.chooseModel('deepseek-v4.1-flash-free');
      expect(desktop.providerId, 'opencode');
      expect(desktop.modelId, 'deepseek-v4.1-flash-free');

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
      expect(desktop.providerId, 'openai');
      expect(desktop.deliveryMode, 'queue');
      expect(desktop.dictationMode, 'on_stop');
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
        List.filled(2, 'Hello from the server.'),
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
      expect(await desktop.send('hold'), isTrue);
      await _until(desktop, () => desktop.task!.streamingText == 'Waiting');
      final historyBefore = await desktop.client.request('history.page', {'task_id': taskId, 'limit': 100}) as List;
      final stopped = desktop.client.events.stream.firstWhere((event) => event['task_id'] == taskId && event['type'] == 'turn.cancelled');
      await desktop.removeProject(desktop.project!);
      await stopped.timeout(const Duration(seconds: 5));
      expect(desktop.projects, isEmpty);
      expect(desktop.project, isNull);
      expect(desktop.task, isNull);
      final historyAfter = await desktop.client.request('history.page', {'task_id': taskId, 'limit': 100}) as List;
      expect(historyAfter, containsAll(historyBefore), reason: 'Removing a project keeps the server task history');
      expect(await File('${work.path}/input.txt').readAsString(), 'from a real tool');
      await desktop.signOut('openai');
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
      var signing = session.signIn('openai', open);
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
      signing = session.signIn('openai', open);
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

const _png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==';

Future<File> _largeBitmap(String path) async {
  const pixels = 5120, size = 54 + pixels * pixels * 4;
  final header = ByteData(54)..setUint8(0, 0x42)..setUint8(1, 0x4d)
    ..setUint32(2, size, Endian.little)..setUint32(10, 54, Endian.little)
    ..setUint32(14, 40, Endian.little)..setUint32(18, pixels, Endian.little)
    ..setUint32(22, pixels, Endian.little)..setUint16(26, 1, Endian.little)
    ..setUint16(28, 32, Endian.little)..setUint32(34, pixels * pixels * 4, Endian.little);
  final file = File(path), output = await File(path).open(mode: FileMode.write);
  try {
    await output.writeFrom(header.buffer.asUint8List());
    await output.truncate(size);
  } finally { await output.close(); }
  return file;
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
