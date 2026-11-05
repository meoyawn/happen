// Host-boundary complements to Codex MRTR shared-caller tests. Package tests own
// continuation parsing; these real clients guard response authority and cleanup
// across the server/network-isolate boundary. No UI or synthetic user action.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late HttpServer peer;
  late AgentServer server;
  final clients = <AgentClient>[], calls = <Json>[];
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mcp-input-routing-'); calls.clear();
    peer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    peer.listen((request) async {
      final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join())); calls.add(body);
      final params = jsonObject(body['params']);
      final result = switch (body['method']) {
        'server/discover' => {'supportedVersions': ['2026-07-28'], 'capabilities': {'resources': <String, Object?>{}}},
        'resources/read' when params['inputResponses'] == null => {'resultType': 'input_required', 'requestState': ' opaque/☃\n',
          'inputRequests': {'confirm': {'method': 'elicitation/create', 'params': {'mode': 'form', 'message': 'Confirm ${params['uri']}',
            'requestedSchema': {'type': 'object', 'properties': {'answer': {'type': 'string'}}}, '_meta': {'caller': params['uri']}}}}},
        'resources/read' => {'resultType': 'complete', 'contents': [{'uri': params['uri'], 'text': params['inputResponses']['confirm']['content']['answer']}]},
        _ => throw StateError('Unexpected host-input request ${body['method']}'),
      };
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': result})); await request.response.close();
    });
    await File('${root.path}/config.yaml').writeAsString(jsonEncode({'mcp_servers': {'peer': {'url': 'http://127.0.0.1:${peer.port}/mcp', 'oauth': false}}}));
    server = await AgentServer.start(directory: root.path, configPath: '${root.path}/config.yaml', skillsHome: root.path, port: 0);
  });
  tearDown(() async { for (final client in clients) { await client.close(); } clients.clear(); await server.close(); await peer.close(force: true); await root.delete(recursive: true); });
  Future<AgentClient> client({bool capable = true}) async {
    final c = await AgentClient.connect(server.uri); clients.add(c);
    if (capable) await c.request('client.capabilities', {'mcp_inputs': true}); return c;
  }
  Future<Json> read(AgentClient c, String uri) async => jsonObject(await c.request('mcp.request', {'server': 'peer', 'method': 'resources/read', 'arguments': {'uri': uri}}));
  Future<Json> input(AgentClient c, Future<Json> operation) => Future.any([
    c.events.stream.firstWhere((event) => event['method'] == 'mcp.input.requested').then((event) => jsonObject(event['params'])),
    operation.then<Json>((result) => throw TestFailure('Request completed before caller input: $result')),
  ]).timeout(const Duration(seconds: 5));

  test('shared resources route raw elicitation and replies only to each calling client', () async {
    final first = await client(), second = await client(), observer = await client();
    final observed = <Json>[], observedSub = observer.events.stream.listen(observed.add); addTearDown(observedSub.cancel);
    final a = read(first, 'memo://first'); unawaited(a.then<void>((_) {}, onError: (Object _) {}));
    final ai = await input(first, a);
    final b = read(second, 'memo://second'); unawaited(b.then<void>((_) {}, onError: (Object _) {}));
    final bi = await input(second, b);
    expect(ai['request_id'], isNot(bi['request_id']));
    expect(ai['request']['params']['_meta']['caller'], 'memo://first'); expect(bi['request']['params']['_meta']['caller'], 'memo://second');
    await expectLater(first.request('mcp.input.reply', {'request_id': bi['request_id'], 'response': {'action': 'accept', 'content': {'answer': 'forged'}}}), throwsStateError);
    expect(await observer.request('mcp.input.list'), isEmpty);
    await second.request('mcp.input.reply', {'request_id': bi['request_id'], 'response': {'action': 'accept', 'content': {'answer': 'second'}, '_meta': {'client': 'second'}}});
    await first.request('mcp.input.reply', {'request_id': ai['request_id'], 'response': {'action': 'accept', 'content': {'answer': 'first'}, '_meta': {'client': 'first'}}});
    expect((await a)['contents'].single['text'], 'first'); expect((await b)['contents'].single['text'], 'second');
    expect(observed.where((e) => e['method'] == 'mcp.input.requested'), isEmpty);
    expect(await first.request('mcp.input.list'), isEmpty); expect(await second.request('mcp.input.list'), isEmpty);
    for (final call in calls.where((c) => c['params']['inputResponses'] != null)) {
      expect(call['params']['requestState'], ' opaque/☃\n');
      expect(call['params']['inputResponses']['confirm']['_meta']['client'], (call['params']['uri'] as String).split('//').last);
    }
  });

  test('disconnect releases only that caller input; another caller can still answer', () async {
    final first = await client(), second = await client();
    final a = read(first, 'memo://first'); unawaited(a.then<void>((_) {}, onError: (Object _) {})); await input(first, a);
    final b = read(second, 'memo://second'); unawaited(b.then<void>((_) {}, onError: (Object _) {})); final pending = await input(second, b);
    await first.close(); await expectLater(a, throwsStateError);
    final list = await second.request('mcp.input.list') as List; expect(list.single['request_id'], pending['request_id']);
    await second.request('mcp.input.reply', {'request_id': pending['request_id'], 'response': {'action': 'accept', 'content': {'answer': 'survived'}}});
    expect((await b)['contents'].single['text'], 'survived');
    expect(calls.where((c) => c['params']['inputResponses'] != null).map((c) => c['params']['uri']), ['memo://second']);
  });

  test('an unadvertised client never receives a fake prompt or synthesized acceptance', () async {
    final c = await client(capable: false), events = <Json>[];
    final subscription = c.events.stream.listen(events.add); addTearDown(subscription.cancel);
    await expectLater(read(c, 'memo://no-client'), throwsStateError);
    expect(events.where((e) => e['method'] == 'mcp.input.requested'), isEmpty);
    expect(calls.where((c) => c['method'] == 'resources/read'), hasLength(1));
  });

  test('agent-owned inputs stay with their thread; Stop cancels only that invocation', () async {
    final first = await client(), second = await client();
    final aThread = jsonObject(await first.request('thread/start', {'cwd': root.path}))['thread']['id'] as String;
    final bThread = jsonObject(await second.request('thread/start', {'cwd': root.path}))['thread']['id'] as String;
    final lifetime = TimeoutCancellationToken(const Duration(seconds: 10));
    Future<Json> agentRead(String thread, String uri) async => jsonObject(await callIsolate(server.network.port, 'mcp.request', {
      'task_id': thread, 'server': 'peer', 'method': 'resources/read', 'arguments': {'uri': uri},
    }, cancellation: lifetime));
    try {
      final a = agentRead(aThread, 'memo://agent-first'); unawaited(a.then<void>((_) {}, onError: (Object _) {})); final ai = await input(first, a);
      final b = agentRead(bThread, 'memo://agent-second'); unawaited(b.then<void>((_) {}, onError: (Object _) {})); final bi = await input(second, b);
      expect(ai['threadId'], aThread); expect(bi['threadId'], bThread);
      await expectLater(first.request('mcp.input.reply', {'request_id': bi['request_id'], 'response': {'action': 'accept'}}), throwsStateError);
      await callIsolate(server.network.port, 'cancel', {'task_id': aThread}, cancellation: lifetime);
      await expectLater(a, throwsA(isA<CancelledException>()));
      await second.request('mcp.input.reply', {'request_id': bi['request_id'], 'response': {'action': 'accept', 'content': {'answer': 'agent-second'}}});
      expect((await b)['contents'].single['text'], 'agent-second');
      expect(jsonObject(await first.request('thread/read', {'threadId': aThread, 'includeTurns': true}))['thread']['turns'], isEmpty);
      expect(jsonObject(await second.request('thread/read', {'threadId': bThread, 'includeTurns': true}))['thread']['turns'], isEmpty);
      expect(server.activeTaskCount, 0, reason: 'Transport input is not a model/history injection.');
    } finally { lifetime.cancel(); }
  });
}
