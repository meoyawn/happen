import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:agent/agent.dart';
import 'package:ai/ai.dart';
import 'package:openai/openai.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  test('agent inspection reads its retained buffer and cancellation never stops another read or inference', () async {
    final writer = ReceivePort(), network = ReceivePort();
    final loading = Completer<Json>();
    var reads = 0, networkCancels = 0;
    final original = ConversationItem.text('user', 'Original model input').toJson();
    var saved = <Json>[original];
    Json snapshot() => {'input': saved, 'through': 1, 'sourceThrough': 1, 'tokens': null};
    writer.listen((raw) {
      final message = jsonObject(raw);
      if (message['method'] == 'context') {
        reads++;
        if (!loading.isCompleted) { loading.complete(message); }
        else { (message['reply'] as SendPort).send({'result': snapshot()}); }
      }
    });
    network.listen((raw) {
      if (jsonObject(raw)['method'] == 'cancel') networkCancels++;
    });
    final config = <String, dynamic>{'provider': 'openai', 'tool_interface': 'openai',
      'model': 'gpt-6.1-sol', 'instructions': '', 'provider_settings': {'reasoning': 'high'}};
    var agent = await startAgent(taskId: newId(), config: config, writer: writer.sendPort,
      network: network.sendPort, taskTools: network.sendPort, codeInterrupt: 0);
    addTearDown(() async { await agent.close(); writer.close(); network.close(); });
    final cancelled = CancellationToken(), lifetime = CancellationToken();
    addTearDown(lifetime.cancel);
    final first = callIsolate(agent.port, 'context', {}, cancellation: cancelled);
    final pending = await loading.future;
    final second = callIsolate(agent.port, 'context', {}, cancellation: lifetime);
    final stopped = expectLater(first, throwsA(isA<CancelledException>()));
    cancelled.cancel();
    await stopped;
    (pending['reply'] as SendPort).send({'result': snapshot()});
    final inspected = jsonObject(await second);
    expect(inspected['input'], [original]);
    expect(networkCancels, 0);
    // Neither a caller editing its copy nor later durable data replaces a live
    // agent's buffer. Only the agent's own committed model transitions do that.
    (inspected['input'] as List).clear();
    saved = [ConversationItem.text('user', 'Different durable data').toJson()];
    expect(jsonObject(await callIsolate(agent.port, 'context', {}, cancellation: lifetime))['input'], [original]);
    expect(reads, 1);
    await agent.close();
    agent = await startAgent(taskId: newId(), config: config, writer: writer.sendPort,
      network: network.sendPort, taskTools: network.sendPort, codeInterrupt: 0);
    expect(jsonObject(await callIsolate(agent.port, 'context', {}, cancellation: lifetime))['input'], saved);
    expect(reads, 2);
  });

  test('inspection equals inference, preserves bootstrap order, and restores through sleep, restart and compaction', () async {
    final root = await Directory.systemTemp.createTemp('agent-inspection-');
    final data = await Directory('${root.path}/data').create();
    final work = await Directory('${root.path}/work').create();
    final home = await Directory('${root.path}/home').create();
    await Directory('${work.path}/.git').create();
    final instructions = File('${work.path}/AGENTS.md');
    await instructions.writeAsString('Keep the original repository guidance.');
    final skill = File('${home.path}/.agents/skills/inspect/SKILL.md');
    await skill.parent.create(recursive: true);
    await skill.writeAsString('---\ndescription: Inspect the canonical model context.\n---\nSkill body.');
    await File('${data.path}/auth.json').writeAsString(jsonEncode({
      'type': 'chatgpt', 'access_token': 'fixture', 'refresh_token': 'fixture', 'account_id': 'fixture',
      'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
    }));
    final provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final incoming = StreamController<({Json body, HttpResponse response})>();
    final requests = StreamIterator(incoming.stream);
    var requestCount = 0;
    provider.listen((request) async {
      final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
      requestCount++;
      incoming.add((body: body, response: request.response));
    });
    final endpoint = 'http://127.0.0.1:${provider.port}/responses';
    Future<AgentServer> start() => AgentServer.startEmbedded(directory: data.path,
      configPath: '${data.path}/config.yaml', skillsHome: home.path, endpoint: endpoint);
    var server = await start();
    var client = await AgentClient.connect(server.uri);
    final lifetime = CancellationToken();
    addTearDown(() async {
      lifetime.cancel();
      await client.close();
      await server.close();
      await requests.cancel();
      await incoming.close();
      await provider.close(force: true);
      await root.delete(recursive: true);
    });
    Future<({Json body, HttpResponse response})> nextRequest() async {
      expect(await requests.moveNext().timeout(const Duration(seconds: 15)), true);
      return requests.current;
    }
    Future<Json> terminal() => client.events.stream.firstWhere((event) =>
      {'session.execution.succeeded', 'session.execution.failed', 'session.execution.interrupted'}.contains(event['type']))
        .timeout(const Duration(seconds: 15));
    Future<void> respond(HttpResponse response, List<Json> output) async {
      response.headers.contentType = ContentType('text', 'event-stream');
      response.write('data: ${jsonEncode({'type': 'response.completed', 'response': {
        'status': 'completed', 'output': output, 'usage': {'input_tokens': 30, 'output_tokens': 3},
      }})}\n\n');
      await response.close();
    }
    List<Json> wire(Json context) => gptPromptInput(context['instructions'] as String, (context['input'] as List)
      .map((item) => ConversationItem.fromJson(jsonObject(item))));
    final admitted = jsonObject(await client.request('session.create', {
      'cwd': work.path, 'prompt': 'Inspect this exact context', 'client_tools': [{
        'name': 'lookup', 'description': 'Deferred lookup', 'inputSchema': {'type': 'object'},
      }],
    }));
    final id = admitted['sessionID'] as String;
    Future<Json> inspect([Json params = const {}]) => client.sessionRead('session.context',
      {'sessionID': id, ...params}, cancellation: lifetime);
    final firstRequest = await nextRequest();
    final initial = await inspect();
    expect(initial['running'], true);
    expect(initial['instructions'], isNotEmpty);
    expect(initial['tools'], isNotEmpty);
    expect(firstRequest.body.containsKey('instructions'), false);
    expect(gptTools((initial['tools'] as List).map((tool) => ToolDefinition.fromJson(jsonObject(tool)))), firstRequest.body['tools']);
    expect(wire(initial), firstRequest.body['input']);
    expect((initial['input'] as List).map((item) => item['native']?['harness']?['context'] ?? item['role']),
      ['skills', 'tool_catalog', 'agents_md', 'environment', 'user']);
    final paged = await inspect({'limit': 2});
    final fencedInput = <Json>[...(paged['input'] as List).map(jsonObject)];
    final observer = await AgentClient.connect(server.uri);
    try {
      await expectLater(observer.request('session.context', {'sessionID': id, 'cursor': paged['cursor']['next']}),
        throwsA(isA<StateError>()));
    } finally { await observer.close(); }
    await respond(firstRequest.response, [
      {'type': 'reasoning', 'id': 'reasoning_fixture', 'summary': [], 'encrypted_content': 'opaque-native-state'},
      {'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec', 'call_id': 'inspect_call',
        'input': 'text("visible tool output");'},
    ]);
    final secondRequest = await nextRequest();
    final afterTool = await inspect();
    expect(wire(afterTool), secondRequest.body['input']);
    expect(jsonEncode(afterTool['input']), contains('opaque-native-state'));
    expect((afterTool['input'] as List).last['role'], 'tool');
    final finished = terminal();
    await respond(secondRequest.response, [
      {'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'Done'}]},
    ]);
    expect((await finished)['type'], 'session.execution.succeeded');
    final idle = await inspect();
    final countBeforeInspection = requestCount;
    expect((idle['input'] as List).take((afterTool['input'] as List).length), afterTool['input']);
    expect(idle['running'], false);
    final store = TaskStore(data.path, id, create: false);
    try { expect(idle['input'], store.modelContext()); }
    finally { store.close(); }
    await client.request('session.hibernate', {'sessionID': id});
    expect((await inspect())['input'], idle['input']);
    await client.close();
    await server.close();
    // Read-only restoration must not refresh external context or admit a turn.
    await instructions.writeAsString('New guidance applies only on the next turn.');
    await skill.writeAsString('---\ndescription: Updated skill catalog.\n---\nChanged body.');
    server = await start();
    client = await AgentClient.connect(server.uri);
    final reopened = await inspect();
    for (final key in ['input', 'instructions', 'tools', 'settings', 'effectiveReasoning', 'tokens', 'windowID', 'sourceThrough']) {
      expect(reopened[key], idle[key], reason: '$key changed during restoration');
    }
    expect(requestCount, countBeforeInspection);
    var beforeCompaction = await inspect({'limit': 2});
    final beforeCompactionInput = <Json>[...(beforeCompaction['input'] as List).map(jsonObject)];
    // A compaction replaces the actual model buffer, rather than just hiding
    // transcript messages. The inspector must include its opaque native item.
    final compacted = terminal();
    await client.request('session.compact', {'sessionID': id});
    final compactRequest = await nextRequest();
    expect(compactRequest.body['input'].last['type'], 'compaction_trigger');
    await respond(compactRequest.response, [{'type': 'compaction', 'encrypted_content': 'replacement-history'}]);
    expect((await compacted)['type'], 'session.execution.succeeded');
    final replacement = await inspect();
    expect((replacement['input'] as List).where((item) => item['kind'] == 'compaction'), hasLength(1));
    expect(jsonEncode(replacement['input']), contains('replacement-history'));
    expect(replacement['tokens'], isNull);
    while (beforeCompaction['cursor']['next'] != null) {
      final next = await inspect({'limit': 2, 'cursor': beforeCompaction['cursor']['next']});
      expect(next['snapshotID'], beforeCompaction['snapshotID']);
      expect(next['windowID'], reopened['windowID']);
      beforeCompactionInput.addAll((next['input'] as List).map(jsonObject));
      beforeCompaction = next;
    }
    expect(beforeCompactionInput, reopened['input']);
    final resumed = terminal();
    await client.request('session.prompt', {'sessionID': id, 'prompt': 'Continue'});
    final continuation = await nextRequest();
    expect((continuation.body['input'] as List).take(wire(replacement).length), wire(replacement));
    expect(wire(await inspect()), continuation.body['input']);
    await respond(continuation.response, [
      {'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'Continued'}]},
    ]);
    expect((await resumed)['type'], 'session.execution.succeeded');
    // The first connection owned its cursor. Closing it releases that snapshot.
    await expectLater(inspect({'cursor': paged['cursor']['next']}), throwsA(isA<StateError>()));
    // A new multi-page snapshot remains fixed even as another turn appends data.
    var page = await inspect({'limit': 2});
    final frozen = await inspect();
    final frozenInput = <Json>[...(page['input'] as List).map(jsonObject)];
    final nextTurn = terminal();
    await client.request('session.prompt', {'sessionID': id, 'prompt': 'Another turn'});
    final another = await nextRequest();
    await respond(another.response, [
      {'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'Another answer'}]},
    ]);
    expect((await nextTurn)['type'], 'session.execution.succeeded');
    while (page['cursor']['next'] != null) {
      final next = await inspect({'limit': 2, 'cursor': page['cursor']['next']});
      expect(next['snapshotID'], page['snapshotID']);
      expect(next['sourceThrough'], page['sourceThrough']);
      frozenInput.addAll((next['input'] as List).map(jsonObject));
      page = next;
    }
    expect(frozenInput, frozen['input']);
    expect(fencedInput, (initial['input'] as List).take(2));
  });
}
