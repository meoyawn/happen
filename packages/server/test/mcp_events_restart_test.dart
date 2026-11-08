// Real process / HTTP / SQLite contracts for Happen's Events draft. Codex's
// plugin-only Events test is deliberately not used as a durability substitute.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart' show AgentClient;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../../../test/support/thread_names.dart';

void main() {
  late _Events peer;
  setUp(() async { peer = await _Events.start(); });
  tearDown(() => peer.close());

  test('polling recovers after six upstream failures without losing its watch or cursor', () async {
    final server = await peer.launch(), id = await peer.thread(server);
    final subscription = await peer.subscribe(server, id, 'poll');
    await peer.unload(server, id);
    final before = peer.calls.length;
    peer.pollFailures.addAll(List.generate(6, (_) => {'code': -32025, 'message': 'ResourceExhausted',
      'data': {'limit': 'github_api', 'retryAfterMs': 1000}}));
    peer.occurrences.add(peer.event(1));
    final deadline = TimeoutCancellationToken(const Duration(seconds: 45));
    try {
      while (peer.pollFailures.isNotEmpty) { await cancellableDelay(const Duration(milliseconds: 20), deadline); }
      await peer.until(() async {
        final saved = await server.request('mcp.events.subscriptions', {'threadId': id}) as List;
        return saved.single['state'] != 'active';
      });
      final reconnecting = (await server.request('mcp.events.subscriptions', {'threadId': id}) as List).single;
      expect(reconnecting['state'], 'reconnecting');
      expect(reconnecting['subscription_id'], subscription['subscription_id']);
      expect(reconnecting['cursor'], 'seed');
      expect(reconnecting['error']['code'], -32025);
      expect(peer.indexedThreads(), contains(id));
      expect(jsonEncode(peer.snapshot(id)), contains('seed'));
      while (peer.responses.length < 2) { await cancellableDelay(const Duration(milliseconds: 20), deadline); }
    } finally { deadline.cancel(); }
    await peer.until(() async => (await server.request('thread/read', {'threadId': id}))['running'] == false);
    final recovered = (await server.request('mcp.events.subscriptions', {'threadId': id}) as List).single;
    expect(recovered['state'], 'active'); expect(recovered['cursor'], 'cursor-1');
    expect(recovered, isNot(contains('error')));
    expect(peer.calls.skip(before).where((call) => call['method'] == 'events/poll').take(7)
      .map((call) => call['params']['cursor']), everyElement('seed'));
    expect((await server.request('thread/read', {'threadId': id, 'includeTurns': true}))['thread']['turns'], hasLength(2));
    peer.pollFailures.add({'code': -32603, 'message': 'temporarily unavailable'});
    await peer.until(() async => (await server.request('mcp.events.subscriptions', {'threadId': id}) as List).single['state'] == 'reconnecting');
    await server.request('mcp.events.unsubscribe', {'threadId': id, 'subscription_id': subscription['subscription_id']});
    final stopped = peer.calls.length;
    await Future<void>.delayed(const Duration(milliseconds: 1250));
    expect(peer.calls.skip(stopped).where((call) => call['method'] == 'events/poll'), isEmpty);
    expect(peer.indexedThreads(), isNot(contains(id)));
  }, timeout: const Timeout(Duration(seconds: 75)));

  test('startup queries indexed unarchived owners and resumes polling after an offline interval', () async {
    peer.nextPollMs = const Duration(days: 3).inMilliseconds;
    var server = await peer.launch();
    final watching = <String>[];
    for (var index = 0; index < 2; index++) {
      final id = await peer.thread(server); watching.add(id);
      await peer.subscribe(server, id, 'poll');
    }
    final archived = await peer.thread(server);
    await peer.subscribe(server, archived, 'poll');
    final ordinary = await peer.thread(server);
    expect(peer.indexedThreads(), unorderedEquals([...watching, archived]),
      reason: 'The server-wide SQLite catalog must durably identify subscription owners.');
    await server.request('thread/archive', {'threadId': archived});
    expect(peer.indexedThreads(), unorderedEquals(watching));
    final before = peer.responses.length, calls = peer.calls.length;
    await server.stop(crash: true);
    // A retained upstream event can predate the new process. The old poll's
    // three-day sleep is a runtime handle, not a persisted resumption deadline.
    peer.occurrences.add({...peer.event(1),
      'timestamp': DateTime.now().subtract(const Duration(days: 2)).toUtc().toIso8601String()});
    server = await peer.launch();
    try { await peer.until(() => peer.responses.length == before + watching.length); }
    catch (error) {
      final states = <String, Object?>{};
      for (final id in watching) {
        states[id] = {'subscriptions': await server.request('mcp.events.subscriptions', {'threadId': id}),
          'thread': (await server.request('thread/read', {'threadId': id, 'includeTurns': true}))['thread']};
      }
      fail('Restart did not wake indexed owners: $error; index: ${peer.indexedThreads()}; '
        'responses: ${peer.responses.length}/$before; '
        'calls: ${peer.calls.skip(calls).map((call) => call['method']).toList()}; states: $states');
    }
    for (final id in watching) {
      await peer.until(() async => (await server.request('thread/read', {'threadId': id}))['running'] == false);
      expect((await server.request('thread/read', {'threadId': id, 'includeTurns': true}))['thread']['turns'], hasLength(2));
      expect(jsonEncode(peer.snapshot(id)), contains('cursor-1'));
    }
    expect(peer.calls.skip(calls).where((call) => call['method'] == 'events/poll'), hasLength(watching.length));
    for (final id in [archived, ordinary]) {
      expect((await server.request('thread/read', {'threadId': id, 'includeTurns': true}))['thread']['turns'], hasLength(1));
    }
    final after = peer.calls.length;
    await server.stop(); server = await peer.launch();
    await peer.until(() => peer.calls.skip(after).where((call) => call['method'] == 'events/poll').length == watching.length);
    expect(peer.calls.skip(after).where((call) => call['method'] == 'events/poll')
      .map((call) => call['params']['cursor']), everyElement('cursor-1'));
    expect(peer.responses, hasLength(before + watching.length), reason: 'A later restart must not replay the same event turn.');
  }, timeout: const Timeout(Duration(seconds: 90)));

  for (final mode in ['push', 'poll', 'webhook']) {
    for (final crash in [false, true]) {
      test('$mode subscription, cursor and receipts survive a real ${crash ? 'killed' : 'gracefully stopped'} server process', () async {
        var server = await peer.launch();
        final id = await peer.thread(server), subscription = await peer.subscribe(server, id, mode), savedRegistration = peer.registration;
        await peer.deliver(server, subscription, mode, peer.event(1));
        await peer.until(() => peer.responses.length == 2);
        await peer.unload(server, id);
        final before = peer.calls.length, oldPid = server.pid;
        await server.stop(crash: crash);
        server = await peer.launch();
        expect(server.pid, isNot(oldPid));
        // No client RPC may cause this reconnection: restoration is server-owned.
        await peer.until(() => peer.calls.skip(before).any((call) => call['method'] == peer.transportMethod(mode)));
        final resumed = peer.calls.skip(before).firstWhere((call) => call['method'] == peer.transportMethod(mode));
        expect(resumed['params']['cursor'], 'cursor-1');
        expect(resumed['params']['arguments'], {'document_id': 'doc-123'});
        expect(resumed['params'], isNot(contains('threadId')));
        final restored = await server.request('mcp.events.subscriptions', {'threadId': id}) as List;
        expect(restored.single['subscription_id'], subscription['subscription_id']);
        expect(restored.single['cursor'], 'cursor-1');
        expect((await server.request('thread/loaded/list'))['data'], isEmpty);
        expect(peer.responses, hasLength(2), reason: 'Restoring control state must not run a model or load a thread.');
        if (mode == 'webhook') {
          expect(peer.registration!['delivery']['url'], savedRegistration!['delivery']['url']);
          expect(peer.registration!['delivery']['secret'], savedRegistration['delivery']['secret']);
        }
        await peer.deliver(server, subscription, mode, peer.event(1), registration: savedRegistration, replay: true);
        await Future<void>.delayed(Duration(milliseconds: mode == 'poll' ? 1250 : 150));
        expect(peer.responses, hasLength(2), reason: 'A transport-local empty seen set is not a durable deduplication receipt.');
        await peer.deliver(server, subscription, mode, peer.event(2), registration: savedRegistration);
        await peer.until(() => peer.responses.length == 3);
        await peer.until(() async => (await server.request('thread/read', {'threadId': id}))['running'] == false);
        final message = (peer.responses.last['input'] as List).map(jsonObject).where((item) => jsonEncode(item).contains('evt-2')).single;
        expect(message['role'], 'user'); expect(jsonEncode(message), contains('untrusted external event data'));
        expect(jsonEncode(peer.responses.last), isNot(contains('whsec_')));
        final history = await server.request('thread/read', {'threadId': id, 'includeTurns': true});
        expect(history['thread']['turns'], hasLength(3));
        if (mode == 'webhook') {
          final privateSecret = (savedRegistration!['delivery']['secret'] as String).substring(6);
          expect(jsonEncode(peer.responses.last), isNot(contains(privateSecret)));
          expect(jsonEncode(history), isNot(contains(privateSecret)));
        }
        expect((await server.request('mcp.events.subscriptions', {'threadId': id}) as List).single['cursor'], 'cursor-2');
      }, timeout: const Timeout(Duration(seconds: 75)));
    }
  }

  test('a finishing agent turn cannot cancel a public thread subscription during activation', () async {
    final server = await peer.launch(), id = await peer.thread(server);
    peer.holdNext = true; peer.responseGate = Completer<void>(); peer.pollGate = Completer<void>(); peer.pollStarted = Completer<void>();
    await server.request('turn/start', {'threadId': id, 'input': [{'type': 'text', 'text': 'Finish this ordinary turn during subscription activation.'}]});
    await peer.held.future;
    final creating = peer.subscribe(server, id, 'poll');
    unawaited(creating.then<void>((_) {}, onError: (Object _) {}));
    await peer.pollStarted!.future;
    peer.responseGate!.complete();
    await peer.until(() async => (await server.request('thread/read', {'threadId': id}))['running'] == false);
    peer.pollGate!.complete();
    final subscription = await creating;
    expect(subscription['state'], 'active');
    expect((await server.request('mcp.events.subscriptions', {'threadId': id}) as List).single['subscription_id'], subscription['subscription_id']);
    expect(peer.responses, hasLength(2));
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a durably admitted thread subscription survives client disconnect during activation', () async {
    final server = await peer.launch(), id = await peer.thread(server), observer = await AgentClient.connect(server.uri);
    try {
      peer.pollGate = Completer<void>(); peer.pollStarted = Completer<void>();
      final creating = peer.subscribe(server, id, 'poll');
      unawaited(creating.then<void>((_) {}, onError: (Object _) {}));
      await peer.pollStarted!.future;
      await server.client.close(); await expectLater(creating, throwsStateError);
      peer.pollGate!.complete();
      await peer.until(() async {
        final values = await observer.request('mcp.events.subscriptions', {'threadId': id}) as List;
        return values.length == 1 && values.single['state'] == 'active';
      });
      expect(peer.responses, hasLength(1), reason: 'Activation is control state, never a model turn.');
    } finally { await observer.close(); }
  }, timeout: const Timeout(Duration(seconds: 60)));

  for (final fault in ['inbox', 'checkpoint']) {
    test('event $fault fault rolls back inbox, receipt and cursor; accepted/duplicate admission uses one/zero WAL commits', () async {
      var server = await peer.launch();
      final id = await peer.thread(server), subscription = await peer.subscribe(server, id, 'webhook');
      await peer.deliver(server, subscription, 'webhook', peer.event(1));
      await peer.until(() => peer.responses.length == 2);
      await peer.until(() async => (await server.request('thread/read', {'threadId': id}))['running'] == false);
      // Install the fault offline. Never open a competing writable SQLite
      // connection while the production storage isolate owns this file.
      await server.stop();
      var database = sqlite3.open(peer.database(id));
      final condition = fault == 'inbox' ? "instr(NEW.data,'evt-2')>0" : "NEW.key IS 'mcp_event_subscriptions' AND instr(NEW.value,'cursor-2')>0";
      database.execute('CREATE TRIGGER event_fault BEFORE UPDATE ON ${fault == 'inbox' ? 'happen_runtime' : 'metadata'} WHEN $condition BEGIN SELECT RAISE(ABORT,\'injected event transaction fault\'); END');
      database.close();
      server = await peer.launch();
      peer.holdNext = true;
      await server.request('turn/start', {'threadId': id, 'input': [{'type': 'text', 'text': 'Hold this ordinary turn while the inbox admits an event.'}]});
      await peer.held.future;
        final before = peer.snapshot(id), commits = peer.commits(id);
        expect(await peer.webhook(server, subscription, peer.event(2)), 503);
        expect(peer.snapshot(id), before, reason: 'Neither half of admission may become durable when the other half fails.');
        expect(peer.commits(id), commits);
        await server.stop(crash: true);
        database = sqlite3.open(peer.database(id));
        database.execute('DROP TRIGGER event_fault');
        database.close();
        server = await peer.launch(); peer.holdNext = true; peer.held = Completer<void>();
        await server.request('turn/start', {'threadId': id, 'input': [{'type': 'text', 'text': 'Hold the next ordinary turn for the accepted admission.'}]});
        await peer.held.future;
        final accepted = peer.commits(id);
        expect(await peer.webhook(server, subscription, peer.event(2)), 200);
        expect(peer.commits(id) - accepted, 1, reason: 'Cursor and receipt must join the input.pending commit, not follow in another transaction.');
        final duplicate = peer.commits(id);
        expect(await peer.webhook(server, subscription, peer.event(2)), 200);
        expect(peer.commits(id), duplicate);
        final inbox = await server.request('session.inbox', {'sessionID': id});
        expect((inbox['data'] as List).where((dynamic input) => (input['prompt'] as String).contains('evt-2')), hasLength(1));
        final durable = peer.snapshot(id);
        expect(durable, contains('mcp_event_subscriptions'), reason: 'The cursor checkpoint must exist in the same real database as its admitted inbox/receipt.');
        final state = jsonObject(jsonDecode(durable['mcp_event_subscriptions'] as String));
        expect(state[subscription['subscription_id']]['cursor'], 'cursor-2');
    }, timeout: const Timeout(Duration(seconds: 90)));
  }

  for (final unsubscribe in [false, true]) {
  test('a webhook acknowledged into a busy inbox wakes after process death${unsubscribe ? ' even after unsubscribe' : ''} without a new occurrence', () async {
    var server = await peer.launch(); final id = await peer.thread(server), subscription = await peer.subscribe(server, id, 'webhook');
    final registration = peer.registration;
    peer.holdNext = true;
    await server.request('turn/start', {'threadId': id, 'input': [{'type': 'text', 'text': 'An ordinary turn is already active.'}]});
    await peer.held.future;
    expect(await peer.webhook(server, subscription, peer.event(1)), 200);
    expect((await server.request('session.inbox', {'sessionID': id}))['data'], hasLength(1));
    if (unsubscribe) await server.request('mcp.events.unsubscribe', {'threadId': id, 'subscription_id': subscription['subscription_id']});
    expect(peer.indexedThreads(), contains(id), reason: 'An acknowledged inbox event still needs a startup recovery owner.');
    final before = peer.responses.length;
    await server.stop(crash: true); server = await peer.launch();
    // Do not resume/read the thread or send another event to make this happen.
    await peer.until(() => peer.responses.length == before + 1);
    expect(jsonEncode(peer.responses.last['input']), contains('evt-1'));
    expect(await peer.webhook(server, subscription, peer.event(1), registration: registration), unsubscribe ? 410 : 200);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(peer.responses, hasLength(before + 1));
  }, timeout: const Timeout(Duration(seconds: 60)));
  }

  test('webhook restoration adopts a fresh provider-issued identity after expiry and rejects the retired identity', () async {
    var server = await peer.launch(); final id = await peer.thread(server), subscription = await peer.subscribe(server, id, 'webhook');
    final registration = peer.registration;
    await peer.deliver(server, subscription, 'webhook', peer.event(1)); await peer.until(() => peer.responses.length == 2);
    await peer.unload(server, id); await server.stop(crash: true);
    peer.remoteId = 'replacement-provider-subscription';
    server = await peer.launch();
    await peer.until(() async {
      final subscriptions = await server.request('mcp.events.subscriptions', {'threadId': id}) as List;
      return subscriptions.isNotEmpty && subscriptions.single['state'] == 'active';
    });
    expect(await peer.webhook(server, subscription, peer.event(2), registration: registration, remoteId: 'remote-subscription'), 401);
    expect(await peer.webhook(server, subscription, peer.event(2), registration: registration), 200);
    await peer.until(() => peer.responses.length == 3);
    expect(peer.registration!['delivery']['url'], registration!['delivery']['url']);
    expect(peer.registration!['delivery']['secret'], registration['delivery']['secret']);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('unsubscribe clears retained intent even when the configured server is disabled on restart', () async {
    var server = await peer.launch(); final id = await peer.thread(server), subscription = await peer.subscribe(server, id, 'webhook');
    await server.stop();
    final config = File('${peer.cwd}/.happen/config.yaml'), original = await config.readAsString();
    await config.writeAsString('$original    enabled: false\n');
    server = await peer.launch();
    await server.request('mcp.events.unsubscribe', {'threadId': id, 'subscription_id': subscription['subscription_id']});
    final saved = jsonObject(jsonDecode(peer.snapshot(id)['mcp_event_subscriptions'] as String));
    expect(saved, isNot(contains(subscription['subscription_id'])));
    await server.stop(); await config.writeAsString(original); server = await peer.launch();
    expect(await server.request('mcp.events.subscriptions', {'threadId': id}), isEmpty);
    expect(peer.responses, hasLength(1));
  }, timeout: const Timeout(Duration(seconds: 75)));

  for (final remove in ['unsubscribe', 'archive', 'provider termination']) {
    test('$remove is durable and cannot resurrect a subscription on the next process', () async {
      var server = await peer.launch(); final id = await peer.thread(server), subscription = await peer.subscribe(server, id, 'webhook');
      if (remove == 'archive') await server.request('thread/archive', {'threadId': id});
      else if (remove == 'unsubscribe') await server.request('mcp.events.unsubscribe', {'threadId': id, 'subscription_id': subscription['subscription_id']});
      else expect(await peer.webhook(server, subscription, {'type': 'terminated', 'eventId': 'provider-termination',
        'error': {'code': -32024, 'message': 'Forbidden'}}), 200);
      final saved = peer.snapshot(id)['mcp_event_subscriptions'];
      if (saved != null) expect(jsonObject(jsonDecode(saved as String)), isNot(contains(subscription['subscription_id'])),
        reason: 'Desired state must be removed durably, not only hidden from an in-memory registry.');
      await server.stop(crash: true); server = await peer.launch();
      expect(await server.request('mcp.events.subscriptions', {'threadId': id}), isEmpty);
      expect(await peer.webhook(server, subscription, peer.event(1)), 410);
      expect(peer.responses, hasLength(1));
    }, timeout: const Timeout(Duration(seconds: 60)));
  }
}

class _Server {
  _Server(this.process, this.client, this.pid, this.uri, this.output, this.errorOutput);
  final Process process;
  final AgentClient client;
  final int pid;
  final Uri uri;
  final StreamSubscription<String> output;
  final StreamSubscription<String> errorOutput;
  bool stopped = false;
  Future<dynamic> request(String method, [Json params = const {}]) => client.request(method, params);
  Future<void> stop({bool crash = false}) async {
    if (stopped) return; stopped = true;
    try { await client.close().timeout(const Duration(seconds: 3)); }
    finally {
      if (crash) process.kill(ProcessSignal.sigkill); else process.stdin.writeln('stop');
      try { await process.exitCode.timeout(const Duration(seconds: 8)); }
      on TimeoutException { process.kill(ProcessSignal.sigkill); await process.exitCode; }
      await process.stdin.close().then<void>((_) {}, onError: (Object _) {});
      await output.cancel(); await errorOutput.cancel();
    }
  }
}

class _Events {
  _Events(this.root, this.upstream) {
    upstream.listen((request) async {
      try { await serve(request); }
      on IOException { /* A real server crash closed this test-owned socket. */ }
      on CancelledException { if (!lifetime.isCancelled) rethrow; }
      on TimeoutException { if (!lifetime.isCancelled) rethrow; }
    });
  }
  final Directory root;
  final HttpServer upstream;
  final http = HttpClient()..findProxy = (_) => 'DIRECT';
  final lifetime = TimeoutCancellationToken(const Duration(minutes: 2));
  final servers = <_Server>[], processes = <Process>[], calls = <Json>[], responses = <Json>[], occurrences = <Json>[];
  var held = Completer<void>();
  Completer<void>? responseGate, pollGate, pollStarted;
  ({HttpResponse response, String id})? stream;
  Json? registration, pollReplay;
  final pollFailures = <Json>[];
  String remoteId = 'remote-subscription';
  bool holdNext = false;
  int nextPollMs = 1000;
  String get origin => 'http://127.0.0.1:${upstream.port}';
  String get cwd => '${root.path}/project';
  static Future<_Events> start() async {
    final peer = _Events(await Directory.systemTemp.createTemp('mcp-restart-'), await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    await Directory('${peer.cwd}/.git').create(recursive: true);
    await Directory('${peer.cwd}/.happen').create();
    await File('${peer.cwd}/.happen/config.yaml').writeAsString('mcp_servers:\n  comments:\n    url: ${peer.origin}/mcp\n    oauth: false\n    legacy_fallback: false\n');
    await File('${peer.root.path}/auth.json').writeAsString(jsonEncode({'type': 'chatgpt', 'access_token': 'fixture', 'refresh_token': 'fixture', 'account_id': 'fixture',
      'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch}));
    return peer;
  }
  Future<_Server> launch() async {
    final assets = File('.dart_tool/native_assets.yaml').absolute;
    if (!assets.existsSync()) throw StateError('Run the Dart test runner to prepare native assets before the restart fixture.');
    final process = await Process.start(Platform.resolvedExecutable, ['--disable-dart-dev',
      '--packages=${File('.dart_tool/package_config.json').absolute.path}',
      File('packages/server/test/fixtures/mcp_event_server.dart').absolute.path,
      jsonEncode({'directory': root.path, 'endpoint': '$origin/responses'})]);
    processes.add(process);
    final ready = Completer<Json>(), errors = StringBuffer();
    final errorOutput = utf8.decoder.bind(process.stderr).listen(errors.write);
    final output = utf8.decoder.bind(process.stdout).transform(const LineSplitter()).listen((line) {
      if (line.startsWith('{') && !ready.isCompleted) ready.complete(jsonObject(jsonDecode(line)));
    });
    unawaited(process.exitCode.then((code) { if (!ready.isCompleted) ready.completeError(StateError('Server exited $code: $errors')); }));
    final startup = TimeoutCancellationToken(const Duration(seconds: 30));
    try {
      final info = await ready.future.asCancellable(lifetime.merge(startup));
      final child = info['pid'] as int;
      if (child != process.pid || child < 2 || child == pid) throw StateError('Fixture did not directly own the server VM');
      final server = _Server(process, await AgentClient.connect(Uri.parse(info['uri'] as String)), child, Uri.parse(info['uri'] as String), output, errorOutput);
      servers.add(server); return server;
    } catch (_) {
      process.kill(ProcessSignal.sigkill); await process.exitCode;
      await process.stdin.close().then<void>((_) {}, onError: (Object _) {});
      await output.cancel(); await errorOutput.cancel(); rethrow;
    } finally { startup.cancel(); }
  }
  Future<void> until(FutureOr<bool> Function() predicate) async {
    final deadline = TimeoutCancellationToken(const Duration(seconds: 8));
    try { while (!await predicate()) { await cancellableDelay(const Duration(milliseconds: 20), deadline.merge(lifetime)); } }
    finally { deadline.cancel(); }
  }
  Future<String> thread(_Server server) async {
    final started = await server.request('thread/start', {'cwd': cwd, 'config': {'thread_unload_delay_secs': 0}});
    final id = started['thread']['id'] as String;
    await server.request('turn/start', {'threadId': id, 'input': [{'type': 'text', 'text': 'Watch doc-123 for new comments.'}]});
    await until(() async => (await server.request('thread/read', {'threadId': id}))['running'] == false && responses.isNotEmpty);
    return id;
  }
  Future<Json> subscribe(_Server server, String id, String mode) async => jsonObject(await server.request('mcp.events.subscribe', {
    'threadId': id, 'server': 'comments', 'name': 'comment.created', 'arguments': {'document_id': 'doc-123'}, 'mode': mode, 'cursor': 'seed',
  }));
  String transportMethod(String mode) => switch (mode) {'push' => 'events/stream', 'poll' => 'events/poll', _ => 'events/subscribe'};
  Json event(int index) => {'eventId': 'evt-$index', 'name': 'comment.created', 'timestamp': '2026-11-05T12:05:00Z',
    'data': {'document_id': 'doc-123', 'text': 'Comment $index'}, 'cursor': 'cursor-$index'};
  Future<void> unload(_Server server, String id) async {
    await until(() async => (await server.request('thread/read', {'threadId': id}))['running'] == false);
    await server.request('thread/unsubscribe', {'threadId': id});
    await until(() async => ((await server.request('thread/loaded/list'))['data'] as List).isEmpty);
  }
  Future<void> deliver(_Server server, Json subscription, String mode, Json event, {Json? registration, bool replay = false}) async {
    if (mode == 'webhook') expect(await webhook(server, subscription, event, registration: registration), 200);
    else if (mode == 'poll') { if (replay) pollReplay = event; else occurrences.add(event); }
    else {
      stream!.response.write('data: ${jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/events/event',
        'params': {...event, '_meta': {'io.modelcontextprotocol/subscriptionId': stream!.id}}})}\n\n');
      await stream!.response.flush();
    }
  }
  Future<int> webhook(_Server server, Json subscription, Json event, {Json? registration, String? remoteId}) async {
    final grant = registration ?? this.registration!, bytes = utf8.encode(jsonEncode(event)), stamp = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    final secret = base64Decode((grant['delivery']['secret'] as String).substring(6));
    final signature = base64Encode(Hmac(sha256, secret).convert([...utf8.encode('${event['eventId']}.$stamp.'), ...bytes]).bytes);
    final request = await http.postUrl(Uri.parse('http://127.0.0.1:${server.uri.port}/mcp-events/${subscription['subscription_id']}'));
    request.headers.set('webhook-id', event['eventId'] as String); request.headers.set('webhook-timestamp', stamp);
    request.headers.set('webhook-signature', 'v1,$signature'); request.headers.set('x-mcp-subscription-id', remoteId ?? this.remoteId); request.add(bytes);
    final response = await request.close(); await response.drain<void>(); return response.statusCode;
  }
  String database(String id) => '${root.path}/tasks/$id/history.sqlite';
  List<String> indexedThreads() {
    final file = File('${root.path}/server.sqlite');
    if (!file.existsSync()) return [];
    final db = sqlite3.open(file.path, mode: OpenMode.readOnly);
    try { return db.select('SELECT thread_id FROM mcp_event_threads').map((row) => row['thread_id'] as String).toList(); }
    finally { db.close(); }
  }
  Json snapshot(String id) {
    final db = sqlite3.open(database(id), mode: OpenMode.readOnly);
    try { return {for (final row in db.select("SELECT key,value FROM metadata WHERE key IN ('mcp_event_receipts','mcp_event_subscriptions')")) row['key'] as String: row['value'],
      'runtime': db.select('SELECT data FROM happen_runtime').single['data']}; }
    finally { db.close(); }
  }
  int commits(String id) {
    // Independent physical WAL commit markers. The busy thread keeps its writer
    // open; inference is held at HTTP, so no unrelated turn commits can intrude.
    final bytes = File('${database(id)}-wal').readAsBytesSync(), data = ByteData.sublistView(bytes);
    if (bytes.length < 32) return 0;
    final frame = 24 + data.getUint32(8); var commits = 0;
    for (var offset = 32; offset + frame <= bytes.length; offset += frame) { if (data.getUint32(offset + 4) != 0) commits++; }
    return commits;
  }
  Future<void> serve(HttpRequest request) async {
    final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
    request.response.headers.contentType = ContentType.json;
    if (request.uri.path == '/responses') {
      if (await respondToThreadName(request, body)) return;
      responses.add(body);
      if (holdNext) { holdNext = false; if (!held.isCompleted) held.complete(); await (responseGate ?? Completer<void>()).future.asCancellable(lifetime); }
      request.response.headers.contentType = ContentType('text', 'event-stream');
      request.response.write('data: ${jsonEncode({'type': 'response.completed', 'response': {'id': 'response-${responses.length}', 'status': 'completed',
        'output': [{'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'Done'}]}]}})}\n\n');
    } else {
      calls.add(body); final params = jsonObject(body['params']);
      expect(params, isNot(contains('threadId')));
      if (body['method'] == 'events/stream') {
        request.response.bufferOutput = false; request.response.headers.contentType = ContentType('text', 'event-stream');
        stream = (response: request.response, id: body['id'] as String);
        request.response.write('data: ${jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/events/active',
          'params': {'cursor': params['cursor'], 'truncated': false, '_meta': {'io.modelcontextprotocol/subscriptionId': body['id']}}})}\n\n');
        await request.response.flush(); return;
      }
      Json result;
      switch (body['method']) {
        case 'server/discover': result = {'supportedVersions': ['2026-07-28'], 'capabilities': {'events': <String, Object?>{}}};
        case 'events/list': result = {'events': [{'name': 'comment.created', 'delivery': ['push', 'poll', 'webhook'], 'inputSchema': {'type': 'object'}, 'payloadSchema': {'type': 'object'}}]};
        case 'events/poll':
          if (pollFailures.isNotEmpty) {
            request.response.write(jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'error': pollFailures.removeAt(0)}));
            await request.response.close(); return;
          }
          final gate = pollGate;
          if (gate != null) {
            if (pollStarted?.isCompleted == false) pollStarted!.complete();
            await gate.future.asCancellable(lifetime); pollGate = null;
          }
          final after = params['cursor'] == 'seed' ? 0 : int.parse((params['cursor'] as String).split('-').last);
          final events = pollReplay == null ? occurrences.where((e) => int.parse((e['cursor'] as String).split('-').last) > after).toList() : [pollReplay!];
          pollReplay = null;
          result = {'events': events, 'cursor': events.isEmpty ? params['cursor'] : events.last['cursor'], 'truncated': false, 'hasMore': false, 'nextPollMs': nextPollMs};
        case 'events/subscribe': registration = params; result = {'id': remoteId, 'cursor': params['cursor'], 'truncated': false,
          'refreshBefore': DateTime.now().add(const Duration(minutes: 5)).toUtc().toIso8601String()};
        case 'events/unsubscribe': result = {};
        default: throw StateError('Unexpected MCP request ${body['method']}');
      }
      request.response.write(jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': result}));
    }
    await request.response.close();
  }
  Future<void> close() async {
    lifetime.cancel(); for (final server in servers) { await server.stop(crash: true); }
    for (final process in processes) { process.kill(ProcessSignal.sigkill); await process.exitCode; }
    http.close(force: true); await upstream.close(force: true); await root.delete(recursive: true);
  }
}
