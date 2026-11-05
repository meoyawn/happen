// Modified Codex 5112ce6edeb9 rmcp-client/src/oauth/{refresh_lock_tests,
// tests/{persistor,credential_store,store_lock}_tests}.rs and ordinary
// streamable_http_oauth_store_pinning.rs ports. One private file per credential
// replaces Codex's aggregate File/Secrets/keyring stores; no fake keyring, legacy
// migration, public guard API or alternate backend is introduced.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:mcp/mcp.dart';
import 'package:mcp/src/oauth.dart';
import 'package:mcp/src/transport.dart' show McpCredentialFailure;
import 'package:protocol/protocol.dart';
import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

import 'fixtures/mcp_oauth_owner.dart';

void main() {
  late _Credentials peer;
  setUp(() async { peer = await _Credentials.start(); });
  tearDown(() => peer.close());
  final requiresAuth = isA<McpCredentialFailure>().having((e) => e.authenticationRequired, 'reauthorization required', true);

  for (final mode in ['same owner', 'distinct owners', 'another isolate', 'another process']) {
    test('Codex credential refresh is serialized and carries omitted grant fields: $mode', () async {
      await peer.seed();
      final first = peer.auth(); await first.authorization(peer.lifetime);
      final second = mode == 'same owner' ? first : mode == 'distinct owners' ? peer.auth() : null;
      await second?.authorization(peer.lifetime);
      final remote = second == null ? await peer.remote(mode) : null;
      final gate = peer.block();
      final one = peer.refresh(first); await peer.grant(1);
      final mark = peer.traceEvents.length;
      final two = second == null ? remote!.start() : peer.refresh(second);
      if (mode != 'same owner') await peer.contended(mark, escaped: peer.grant(2));
      gate.complete(const _Grant());
      expect(await one, 'rotated-access'); expect(await two, 'rotated-access');
      expect(peer.grants, hasLength(1));
      final saved = await peer.saved();
      expect(saved['refresh_token'], 'refresh-token'); expect(saved['scope'], 'read offline_access');
      expect(saved['issuer'], peer.origin); expect(saved['resource'], peer.url);
      expect(saved['access_token'], 'rotated-access');
    });
  }

  for (final same in [false, true]) {
    for (final mutation in ['login', 'logout']) {
      test('Codex $mutation follows the completed refresh: same owner=$same', () async {
        await peer.seed(); final first = peer.auth(); await first.authorization(peer.lifetime);
        final other = same ? first : peer.auth();
        final gate = peer.block(); final refreshing = peer.refresh(first); await peer.grant(1);
        final mark = peer.traceEvents.length;
        final change = peer.traced(() => mutation == 'login' ? peer.login(other) : other.logout(peer.lifetime));
        if (!same) await peer.contended(mark, escaped: change);
        else if (mutation == 'logout') {
          // A cancelled provider socket is also observable: a later successful
          // refresh result is required, not merely an eventually missing file.
          expect(await peer.file.exists(), true);
        }
        gate.complete(const _Grant()); expect(await refreshing, 'rotated-access'); await change;
        if (mutation == 'login') expect((await peer.saved())['access_token'], 'login-access');
        else expect(await peer.file.exists(), false);
        expect(peer.grants.map((g) => g['grant_type']), mutation == 'login' ? ['refresh_token', 'authorization_code'] : ['refresh_token']);
        if (mutation == 'login') expect(peer.grants.last['durable_before_exchange'], 'rotated-access');
      });
    }
  }

  test('Codex fresh preparation uses its pinned snapshot without waiting for another refresh guard', () async {
    await peer.seed(); final holder = peer.auth(), fresh = peer.auth();
    await holder.authorization(peer.lifetime); await fresh.authorization(peer.lifetime);
    final gate = peer.block(), work = peer.refresh(holder); await peer.grant(1);
    expect(await fresh.authorization(peer.lifetime), 'old-access'); expect(peer.grants, hasLength(1));
    gate.complete(const _Grant()); await work;
  });

  test('Codex caller cancellation does not cancel shared refresh persistence', () async {
    await peer.seed(expires: 0); final auth = peer.auth(), caller = CancellationToken();
    final gate = peer.block(); final work = auth.authorization(caller);
    final cancelled = expectLater(work, throwsA(isA<CancelledException>()));
    await peer.grant(1); caller.cancel(); await cancelled;
    gate.complete(const _Grant()); expect(await auth.authorization(peer.lifetime), 'rotated-access');
    expect((await peer.saved())['access_token'], 'rotated-access'); expect(peer.grants, hasLength(1));
  });

  for (final replacement in ['removed', 'client', 'issuer', 'issuerless']) {
    test('Codex guarded reread rejects $replacement authority without sending a refresh token', () async {
      await peer.seed(); final auth = peer.auth(); await auth.authorization(peer.lifetime);
      final saved = await peer.saved();
      switch (replacement) {
        case 'removed': await peer.file.delete();
        case 'client': await peer.write({...saved, 'client_id': 'different-client'});
        case 'issuer': await peer.write({...saved, 'issuer': 'https://other-issuer.example'});
        case 'issuerless': await peer.write({...saved}..remove('issuer'));
      }
      final before = await peer.bytes();
      await expectLater(peer.refresh(auth), throwsA(requiresAuth));
      expect(peer.grants, isEmpty); expect(await peer.bytes(), before);
    });
  }

  for (final expiry in ['absolute', 'unknown']) {
    for (final failure in ['malformed', 'rejected']) {
      test('Codex failed refresh adopts a bound completed login: expiry=$expiry failure=$failure', () async {
        await peer.seed(expires: 0); final original = await peer.saved();
        final replacement = {...original, 'client_id': 'new-login-client', 'access_token': 'new-login-access',
          'refresh_token': 'new-login-refresh', 'expires_at': expiry == 'absolute' ? peer.future : null};
        peer.exchange = (_) async {
          await peer.write(replacement); return failure == 'malformed' ? const _Grant(text: 'not JSON') : const _Grant(status: 400, body: {'error': 'invalid_grant'});
        };
        expect(await peer.auth().authorization(peer.lifetime), 'new-login-access');
        expect(await peer.saved(), replacement); expect(peer.grants, hasLength(1));
      });
    }
  }
  for (final issuer in [null, 'https://different-issuer.example']) {
    for (final failure in ['malformed', 'rejected']) {
      test('Codex failed refresh rejects an unbound replacement without overwriting it: issuer=$issuer failure=$failure', () async {
        await peer.seed(expires: 0); final replacement = {...await peer.saved(), 'access_token': 'unbound-access',
          'issuer': issuer, 'expires_at': peer.future};
        peer.exchange = (_) async { await peer.write(replacement); return failure == 'malformed'
          ? const _Grant(text: 'invalid JSON') : const _Grant(status: 400, body: {'error': 'invalid_grant'}); };
        final auth = peer.auth(); await expectLater(auth.authorization(peer.lifetime), throwsA(requiresAuth));
        expect(await peer.saved(), replacement); expect(peer.grants, hasLength(1));
      });
    }
  }

  for (final failure in ['malformed', 'transient', 'rejected']) {
    test('Codex expired $failure refresh preserves credentials and permits only safe later retries', () async {
      await peer.seed(expires: 0); final before = await peer.bytes(), auth = peer.auth();
      peer.exchange = (_) async => switch (failure) {
        'malformed' => const _Grant(text: 'invalid JSON'), 'transient' => const _Grant(status: 503, body: {}),
        _ => const _Grant(status: 400, body: {'error': 'invalid_grant', 'error_description': 'provider-secret'}),
      };
      await expectLater(auth.authorization(peer.lifetime), throwsA(requiresAuth)); expect(await peer.bytes(), before);
      peer.exchange = (_) async => const _Grant();
      if (failure == 'rejected') { await expectLater(auth.authorization(peer.lifetime), throwsA(requiresAuth)); expect(peer.grants, hasLength(1)); }
      else { expect(await auth.authorization(peer.lifetime), 'rotated-access'); expect(peer.grants, hasLength(2)); }
    });
  }

  test('reformatting an unchanged credential cannot turn a rejected refresh into a replacement login', () async {
    await peer.seed(); final auth = peer.auth(); await auth.authorization(peer.lifetime);
    final original = await peer.saved(), reordered = <String, dynamic>{for (final entry in (await peer.saved()).entries.toList().reversed) entry.key: entry.value};
    peer.exchange = (_) async { await peer.write(reordered); return const _Grant(status: 400, body: {'error': 'invalid_grant'}); };
    await expectLater(peer.refresh(auth), throwsA(requiresAuth));
    expect(await peer.saved(), original); expect(await peer.file.readAsString(), jsonEncode(reordered));
    await expectLater(auth.authorization(peer.lifetime), throwsA(requiresAuth)); expect(peer.grants, hasLength(1));
  });

  test('Codex rejected refresh remains retired when the authoritative file becomes corrupt and diagnostics are redacted', () async {
    await peer.seed(expires: 0); final auth = peer.auth(), original = await peer.saved();
    peer.exchange = (_) async { await peer.file.writeAsString('{"invalid":"credential-backend-secret"}');
      return const _Grant(status: 400, body: {'error': 'invalid_grant', 'error_description': 'provider-secret'}); };
    await expectLater(peer.traced(() => auth.authorization(peer.lifetime)), throwsA(requiresAuth));
    expect(await peer.file.readAsString(), '{"invalid":"credential-backend-secret"}');
    await peer.write(original); await expectLater(auth.authorization(peer.lifetime), throwsA(requiresAuth));
    expect(peer.grants, hasLength(1)); expect(jsonEncode(peer.traceEvents), isNot(anyOf(contains('credential-backend-secret'), contains('provider-secret'))));
  });

  for (final operation in ['refresh', 'login']) {
    for (final failSave in [false, true]) {
      test('Codex $operation publishes only durably saved credentials: fail=$failSave', () async {
        await peer.seed(); final auth = peer.auth(); await auth.authorization(peer.lifetime);
        final original = await peer.saved();
        peer.exchange = (form) async {
          if (failSave) { await peer.file.delete(); await Directory(peer.file.path).create(); await File('${peer.file.path}/sentinel').writeAsString('untouched'); }
          return _Grant(body: {'access_token': operation == 'login' ? 'login-access' : 'rotated-access', 'refresh_token': 'rotated-refresh', 'expires_in': 3600});
        };
        final work = operation == 'refresh' ? peer.refresh(auth) : peer.login(auth);
        if (failSave) {
          await expectLater(work, throwsA(isA<McpFailure>()));
          if (operation == 'login') expect(await auth.authorization(peer.lifetime), 'old-access');
          else await expectLater(auth.authorization(peer.lifetime), throwsA(isA<McpFailure>()),
            reason: 'A known rejected token cannot be reused, and the unsaved provider token cannot become a fresh cached success.');
          expect(await File('${peer.file.path}/sentinel').readAsString(), 'untouched');
          expect((await peer.file.parent.list().toList()).where((entry) => entry.path.endsWith('.tmp')), isEmpty);
          await Directory(peer.file.path).delete(recursive: true); await peer.write(original);
        } else {
          await work; final durable = await peer.saved(); expect(durable['access_token'], operation == 'login' ? 'login-access' : 'rotated-access');
          expect(await auth.authorization(peer.lifetime), durable['access_token']);
        }
      });
    }
  }

  test('Codex pinned authoritative read failures do not clear or replace a previously cached credential', () async {
    await peer.seed(); final auth = peer.auth(); await auth.authorization(peer.lifetime);
    final before = await peer.bytes(); await peer.file.delete(); await Directory(peer.file.path).create();
    await expectLater(peer.refresh(auth), throwsA(requiresAuth));
    expect(auth.authenticated, true, reason: 'A storage read failure is not permission to publish an empty runtime snapshot.');
    expect(peer.grants, isEmpty); await Directory(peer.file.path).delete(); await peer.file.writeAsString(before!);
  });

  for (final broken in ['removed', 'directory', 'symlink']) {
    test('Codex session recovery stays pinned to its file authority and never uses stale fallback credentials: $broken', () async {
      await peer.seed(); final stale = peer.fileFor('local:race', peer.url);
      await stale.writeAsString(jsonEncode({...await peer.saved(), 'server_name': 'local:race', 'access_token': 'stale-fallback-token'}));
      final manager = McpManager(http: peer.http, directory: peer.root.path, onEvent: (_, _) {}); peer.managers.add(manager);
      await manager.configure({'race': {'url': peer.url}}, peer.lifetime);
      while (manager.status().single['state'] != 'ready') { await cancellableDelay(const Duration(milliseconds: 10), peer.lifetime); }
      await manager.request('race', 'tools/call', {'name': 'echo'}, peer.lifetime);
      peer.expireSession = () async {
        await peer.file.delete();
        if (broken == 'directory') await Directory(peer.file.path).create();
        if (broken == 'symlink') await Link(peer.file.path).create(stale.path);
      };
      try { await manager.request('race', 'tools/call', {'name': 'echo'}, peer.lifetime); } on McpFailure { /* A closed authority may fail safely. */ }
      expect(peer.rpc, isNotEmpty);
      expect(peer.rpc.map((r) => r['authorization']), everyElement('Bearer old-access'));
      expect(peer.grants, isEmpty); expect((await stale.readAsString()), contains('stale-fallback-token'));
    });
  }

  test('Codex repeated local prefixes and complete URLs retain separate private file authorities', () async {
    final variants = [('local:foo', peer.url), ('local:local:foo', peer.url), ('local:foo', '${peer.url}?tenant=two')];
    for (final (index, (name, url)) in variants.indexed) {
      await peer.seed(name: name, url: url, access: 'access-$index');
    }
    for (final (index, (name, url)) in variants.indexed) {
      expect(await peer.auth(name: name, url: url).authorization(peer.lifetime), 'access-$index');
    }
    expect(peer.grants, isEmpty);
  });

  test('Codex different credential files can refresh concurrently without losing either server update', () async {
    await peer.seed(expires: 0); await peer.seed(name: 'other', expires: 0);
    final gate = peer.block(), a = peer.auth(), b = peer.auth(name: 'other');
    final first = a.authorization(peer.lifetime), second = b.authorization(peer.lifetime);
    await peer.grant(2); gate.complete(const _Grant()); await Future.wait([first, second]);
    expect((await peer.saved())['access_token'], 'rotated-access');
    expect(jsonObject(jsonDecode(await peer.fileFor('other', peer.url).readAsString()))['access_token'], 'rotated-access');
  });

  test('Codex a crashed credential holder releases its lock for another owner', () async {
    await peer.seed(); final remote = await peer.remote('another process'), gate = peer.block();
    final ignored = remote.start(); unawaited(ignored.then<void>((_) {}, onError: (Object _) {})); await peer.grant(1);
    final other = peer.auth(); await other.authorization(peer.lifetime); final mark = peer.traceEvents.length;
    final waiting = peer.refresh(other); await peer.contended(mark, escaped: peer.grant(2));
    remote.kill(); gate.complete(const _Grant()); expect(await waiting, 'rotated-access');
    expect((await peer.saved())['access_token'], 'rotated-access');
  });

  test('Codex provider timeout releases the credential lock and preserves the durable grant', () async {
    await peer.seed(expires: 0); final before = await peer.bytes(); peer.block();
    await expectLater(peer.auth().authorization(peer.lifetime), throwsA(requiresAuth));
    expect(await peer.bytes(), before);
    peer.exchange = (_) async => const _Grant(); expect(await peer.auth().authorization(peer.lifetime), 'rotated-access');
  }, timeout: const Timeout(Duration(seconds: 35)));

  test('Codex provider timeout excludes time spent waiting for another refresh transaction', () async {
    await peer.seed(); final remote = await peer.remote('another process');
    peer.delayMetadata = const Duration(seconds: 12);
    peer.exchange = (_) async { await cancellableDelay(const Duration(seconds: 12), peer.lifetime); return const _Grant(); };
    final first = remote.start(); await peer.metadataStarted.future;
    final other = peer.auth(); await other.authorization(peer.lifetime); final mark = peer.traceEvents.length;
    final waiting = peer.refresh(other); await peer.contended(mark, escaped: peer.grant(2));
    expect(await first, 'rotated-access'); expect(await waiting, 'rotated-access'); expect(peer.grants, hasLength(1));
  }, timeout: const Timeout(Duration(seconds: 45)));

  test('Codex credential-lock acquisition times out without stealing a live holder and later reacquires', () async {
    await peer.seed(); final remote = await peer.remote('another process'), gate = peer.block();
    final work = remote.start(); unawaited(work.then<void>((_) {}, onError: (Object _) {})); await peer.grant(1);
    // Suspend only this test-owned Dart process. Its real refresh guard stays
    // held while its HTTP timeout clock cannot finish the refresh for us.
    expect(remote.process!.kill(ProcessSignal.sigstop), true);
    try {
      final other = peer.auth(); await other.authorization(peer.lifetime);
      await expectLater(peer.refresh(other), throwsA(requiresAuth));
      expect(peer.grants, hasLength(1));
      final third = peer.auth(); await third.authorization(peer.lifetime); final mark = peer.traceEvents.length;
      final waiting = peer.refresh(third); await peer.contended(mark, escaped: peer.grant(2));
      remote.process!.kill(ProcessSignal.sigcont); gate.complete(const _Grant());
      expect(await waiting, 'rotated-access');
    } finally { remote.process!.kill(ProcessSignal.sigcont); }
  }, timeout: const Timeout(Duration(seconds: 85)), skip: Platform.isWindows ? 'Unix-only suspended-process boundary; Windows locking is not claimed by this local port.' : false);
}

class _Grant {
  const _Grant({this.status = 200, this.body = const {'access_token': 'rotated-access', 'expires_in': 3600}, this.text});
  final int status;
  final Json body;
  final String? text;
}

class _Remote {
  final ready = Completer<void>(), done = Completer<String?>();
  Process? process;
  Isolate? isolate;
  SendPort? control;
  StreamSubscription<Object?>? messages;
  ReceivePort? port;
  void receive(Json event, void Function(Json) trace) {
    if (event['control'] is SendPort) control = event['control'] as SendPort;
    if (event['trace'] is Map) trace(jsonObject(event['trace']));
    if (event['ready'] == true && !ready.isCompleted) ready.complete();
    if (event.containsKey('result') && !done.isCompleted) done.complete(event['result'] as String?);
    if (event['error'] != null) {
      final error = McpCredentialFailure(event['error'] as String, authenticationRequired: event['authenticationRequired'] == true);
      if (!ready.isCompleted) ready.completeError(error);
      if (!done.isCompleted) done.completeError(error);
    }
  }
  Future<String?> start() { if (process != null) process!.stdin.writeln('start'); else control!.send('start'); return done.future; }
  void kill() { process?.kill(ProcessSignal.sigkill); isolate?.kill(priority: Isolate.immediate); }
  Future<void> close() async { kill(); await messages?.cancel(); port?.close(); if (process != null) await process!.exitCode; }
}

class _Credentials {
  _Credentials(this.root, this.server) {
    server.listen((request) async {
      try { await serve(request); }
      on CancelledException { if (!lifetime.isCancelled) rethrow; }
      on TimeoutException { if (!lifetime.isCancelled) rethrow; }
    });
    traceListener = tracePort.listen((event) { final value = jsonObject(event); traceEvents.add(value); traceStream.add(value); });
  }
  final Directory root;
  final HttpServer server;
  final http = HttpClient();
  final lifetime = TimeoutCancellationToken(const Duration(seconds: 70));
  final owners = <McpOAuth>[], remotes = <_Remote>[], managers = <McpManager>[];
  final grants = <Json>[], rpc = <Json>[], traceEvents = <Json>[];
  final changes = StreamController<void>.broadcast(), traceStream = StreamController<Json>.broadcast(), tracePort = ReceivePort();
  late final StreamSubscription<Object?> traceListener;
  final gates = <Completer<_Grant>>[];
  final metadataStarted = Completer<void>();
  Duration? delayMetadata;
  Future<_Grant> Function(Json)? exchange;
  Future<void> Function()? expireSession;
  String get origin => 'http://127.0.0.1:${server.port}';
  String get url => '$origin/mcp';
  int get future => DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch;
  File fileFor(String name, String url) => File('${root.path}/mcp-auth/${sha256.convert(utf8.encode('$name\u0000$url'))}.json');
  File get file => fileFor('race', url);
  static Future<_Credentials> start() async => _Credentials(await Directory.systemTemp.createTemp('codex-oauth-credentials-'), await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
  Future<void> seed({String name = 'race', String? url, int? expires, String access = 'old-access'}) async {
    final target = fileFor(name, url ?? this.url); await target.parent.create(recursive: true);
    await target.writeAsString(jsonEncode({'server_name': name, 'server_url': url ?? this.url, 'issuer': origin, 'resource': this.url,
      'client_id': 'client', 'access_token': access, 'refresh_token': 'refresh-token', 'scope': 'read offline_access', 'expires_at': expires ?? future}));
  }
  Future<void> write(Json saved) => file.writeAsString(jsonEncode(saved));
  Future<Json> saved() async => jsonObject(jsonDecode(await file.readAsString()));
  Future<String?> bytes() async => await file.exists() ? file.readAsString() : null;
  McpOAuth auth({String name = 'race', String? url}) { final owner = McpOAuth(root.path, name, {'url': url ?? this.url}, http); owners.add(owner); return owner; }
  T traced<T>(T Function() action) => withTrace(TraceContext(sink: tracePort.sendPort, service: 'network'), action);
  Future<String?> refresh(McpOAuth auth) {
    auth.challenge(401, ['Bearer error="invalid_token"'], sentToken: true);
    final work = traced(() => auth.authorization(lifetime));
    unawaited(work.then<void>((_) {}, onError: (Object _) {})); return work;
  }
  Future<void> login(McpOAuth auth) => auth.login(lifetime, (value) {
    final opened = Uri.parse(value); auth.completeLogin(Uri.parse(opened.queryParameters['redirect_uri']!).replace(queryParameters: {'code': 'code', 'state': opened.queryParameters['state']!}).toString());
  });
  Completer<_Grant> block() {
    final gate = Completer<_Grant>(); gates.add(gate);
    exchange = (form) => form['grant_type'] == 'authorization_code' ? Future.value(const _Grant(body: {'access_token': 'login-access', 'expires_in': 3600}))
      : gate.future.asCancellable(lifetime); return gate;
  }
  Future<void> grant(int count) async { while (grants.length < count) { await changes.stream.first.asCancellable(lifetime); } }
  Future<void> contended(int mark, {required Future<dynamic> escaped}) async {
    bool matches(Json value) => value['event']?['name'] == 'mcp.oauth.lock.contended';
    final check = Future.any<Object?>([
      if (traceEvents.skip(mark).any(matches)) Future.value() else traceStream.stream.firstWhere(matches),
      escaped.then<Object?>((_) => throw TestFailure('A second operation escaped the held credential transaction before actual lock contention.')),
    ]);
    await check.timeout(const Duration(seconds: 5));
  }
  Future<_Remote> remote(String mode) async {
    final remote = _Remote(); remotes.add(remote);
    final args = <String, dynamic>{'directory': root.path, 'name': 'race', 'url': url};
    void trace(Json event) { traceEvents.add(event); traceStream.add(event); }
    unawaited(remote.done.future.then<void>((_) {}, onError: (Object _) {}));
    if (mode == 'another isolate') {
      remote.port = ReceivePort(); remote.messages = remote.port!.listen((value) => remote.receive(jsonObject(value), trace));
      remote.isolate = await Isolate.spawn(credentialIsolate, {...args, 'output': remote.port!.sendPort});
    } else {
      remote.process = await Process.start(Platform.resolvedExecutable, ['--disable-dart-dev', '--packages=${File('.dart_tool/package_config.json').absolute.path}',
        File('test/fixtures/mcp_oauth_owner.dart').absolute.path, jsonEncode(args)]);
      remote.messages = utf8.decoder.bind(remote.process!.stdout).transform(const LineSplitter()).listen((line) => remote.receive(jsonObject(jsonDecode(line)), trace));
      unawaited(remote.process!.stderr.drain<void>());
    }
    await remote.ready.future.asCancellable(lifetime); return remote;
  }
  Future<void> serve(HttpRequest request) async {
    Json body = {}; var status = 200; String? text;
    if (request.uri.path == '/mcp' && request.method == 'POST') {
      final input = jsonObject(jsonDecode(await utf8.decoder.bind(request).join())); rpc.add({...input, 'authorization': request.headers.value('authorization')});
      if (input['method'] == 'tools/call' && expireSession != null) { final expire = expireSession!; expireSession = null; await expire(); status = 404; }
      else if (input['method'] == 'server/discover') body = {'jsonrpc': '2.0', 'id': input['id'], 'error': {'code': -32601, 'message': 'method not found'}};
      else if (input['method'] == 'notifications/initialized') status = 202;
      else {
        request.response.headers.set('mcp-session-id', 'session-${rpc.length}');
        body = {'jsonrpc': '2.0', 'id': input['id'], 'result': switch (input['method']) {
          'initialize' => {'protocolVersion': '2025-06-18', 'capabilities': {'tools': <String, Object?>{}}, 'serverInfo': {'name': 'race', 'version': '1'}},
          'tools/list' => {'tools': <Object?>[]}, _ => {'content': [{'type': 'text', 'text': 'ran'}]},
        }};
      }
    } else if (request.uri.path == '/mcp') {
      status = 401; request.response.headers.set('www-authenticate', 'Bearer resource_metadata="$origin/resource-metadata"');
    } else if (request.uri.path == '/resource-metadata') body = {'resource': url, 'authorization_servers': [origin]};
    else if (request.uri.path == '/.well-known/oauth-authorization-server') {
      if (!metadataStarted.isCompleted) metadataStarted.complete();
      if (delayMetadata != null) { final delay = delayMetadata!; delayMetadata = null; await cancellableDelay(delay, lifetime); }
      body = {'issuer': origin, 'authorization_endpoint': '$origin/authorize', 'token_endpoint': '$origin/token', 'registration_endpoint': '$origin/register',
        'code_challenge_methods_supported': ['S256']};
    } else if (request.uri.path == '/register') {
      await request.drain<void>(); body = {'client_id': 'new-login-client'};
    } else if (request.uri.path == '/token') {
      final form = Uri.splitQueryString(await utf8.decoder.bind(request).join()); grants.add(form); changes.add(null);
      // The successful refresh must already be durable when a queued login is
      // allowed to exchange its code, not only when that login later saves.
      if (form['grant_type'] == 'authorization_code' && grants.any((g) => g['grant_type'] == 'refresh_token')) {
        form['durable_before_exchange'] = (await saved())['access_token'] as String;
      }
      final response = await (exchange?.call(form) ?? Future.value(form['grant_type'] == 'authorization_code'
        ? const _Grant(body: {'access_token': 'login-access', 'expires_in': 3600}) : const _Grant()));
      body = response.body; status = response.status; text = response.text;
    } else status = 404;
    try { request.response.statusCode = status; request.response.headers.contentType = ContentType.json; request.response.write(text ?? jsonEncode(body)); await request.response.close(); }
    on HttpException { /* A timed-out/cancelled owner closed its response. */ }
    on SocketException { /* A timed-out/cancelled owner closed its response. */ }
  }
  Future<void> close() async {
    lifetime.cancel(); for (final gate in gates) { if (!gate.isCompleted) gate.complete(const _Grant()); }
    await Future.wait(managers.map((manager) => manager.close())); await Future.wait(owners.map((owner) => owner.close()));
    await Future.wait(remotes.map((remote) => remote.close())); http.close(force: true); await server.close(force: true);
    await traceListener.cancel(); tracePort.close(); await traceStream.close(); await changes.close(); await root.delete(recursive: true);
  }
}
