import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai/ai.dart';
import 'package:deepseek/deepseek.dart';
import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late HttpServer server;
  late HttpClient http;
  late OpenCodeAuthManager auth;
  late Uri endpoint;
  late Future<void> Function(HttpRequest, Json) handler;
  late Future<void> Function(HttpRequest, Json) tokenHandler;
  final requests = <Json>[];

  Future<void> ordinary(HttpRequest request, Json body) async {
    switch (request.uri.path) {
      case '/console/auth/device/code':
        await _reply(request, _device());
      case '/console/auth/device/token':
        await tokenHandler(request, body);
      case '/console/api/user':
        await _reply(request, {
          'id': 'fixture-user',
          'email': 'fixture@example.invalid',
        });
      case '/console/api/orgs':
        await _reply(request, [
          {'id': 'unrelated-org', 'name': 'A different workspace'},
          {'id': 'personal-org', 'name': 'Personal'},
        ]);
      case '/health':
        await _reply(request, {'okay': true});
      default:
        await _reply(request, {}, status: 404);
    }
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('happen-console-auth-');
    http = HttpClient();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    endpoint = Uri.parse('http://127.0.0.1:${server.port}/console');
    auth = OpenCodeAuthManager(directory.path, http: http, endpoint: endpoint);
    requests.clear();
    tokenHandler = (request, _) => _reply(request, _token());
    handler = ordinary;
    server.listen((request) async {
      try {
        final text = await utf8.decoder.bind(request).join();
        final body = text.isEmpty
            ? <String, dynamic>{}
            : jsonObject(jsonDecode(text));
        requests.add({
          'path': request.uri.path,
          'method': request.method,
          'body': body,
          'authorized':
              request.headers.value(HttpHeaders.authorizationHeader) ==
              'Bearer fixture-access-1',
        });
        await handler(request, body);
      } catch (_) {
        await request.response.close().catchError((Object _) {});
      }
    });
  });
  tearDown(() async {
    auth.close();
    http.close(force: true);
    await server.close(force: true);
    await directory.delete(recursive: true);
  });

  Future<void> login() =>
      auth.login(notify: (_, _) {}, cancellation: CancellationToken());

  test('Console inference uses the owned organization login and only the free route', () async {
    await login();
    final provider = DeepSeekProvider.opencode(
      http: http,
      auth: auth,
      endpoint: endpoint.resolve('/inference/openai/v1'),
    );
    final settings = provider.resolveSettings({'reasoning': 'low'});
    expect(settings['context_limit'], 200000);
    expect(settings['max_output_tokens'], 32000);
    expect(
      () => provider.resolveSettings({}, model: 'deepseek-v4.1-flash'),
      throwsArgumentError,
    );
    expect(
      () => provider.resolveSettings({'max_output_tokens': 32001}),
      throwsArgumentError,
    );
    expect(
      () => provider.resolveSettings({'context_limit': 200001}),
      throwsArgumentError,
    );
    final request = ModelRequest(
      taskId: 'console-task',
      model: openCodeDeepSeekModel,
      instructions: 'Follow instructions.',
      input: [ConversationItem.text('user', 'Ready?')],
      tools: [],
      settings: settings,
      effectiveReasoning: 'low',
    );
    handler = (http, body) async {
      expect(http.uri.path, '/inference/openai/v1/chat/completions');
      expect(http.headers.value('Authorization'), 'Bearer fixture-access-1');
      expect(http.headers.value('x-org-id'), 'personal-org');
      expect(http.headers.value('User-Agent'), startsWith('happen/'));
      expect(body['model'], 'deepseek-v4.1-flash-free');
      expect(body['max_tokens'], 32000);
      http.response.headers.contentType = ContentType('text', 'event-stream');
      http.response.write(
        'data: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': 'READY'},
              'finish_reason': 'stop',
            },
          ],
        })}\n\ndata: [DONE]\n\n',
      );
      await http.response.close();
    };
    final reply = await provider.respond(
      request,
      cancellation: CancellationToken(),
    );
    expect(reply.text, 'READY');
    expect(jsonEncode(reply.toJson()), isNot(contains('fixture-access')));
    var denied = 0;
    handler = (http, _) async {
      denied++;
      await _reply(http, {
        'error': {'type': 'FreeUsageLimitError', 'message': 'fixture-access-1'},
      }, status: 429);
    };
    await expectLater(
      provider.respond(request, cancellation: CancellationToken()),
      throwsA(
        isA<ModelFailure>()
            .having((e) => e.code, 'code', 'free_usage_limit')
            .having(
              (e) => e.toString(),
              'message',
              isNot(contains('fixture-access')),
            ),
      ),
    );
    expect(denied, 1);
  });

  test('device polling selects the authorized organization and privately persists coalesced refreshes', () async {
    var polls = 0, refreshes = 0;
    final refreshing = Completer<void>();
    final release = Completer<void>();
    tokenHandler = (request, body) async {
      if (body['grant_type'] == 'refresh_token') {
        refreshes++;
        if (!refreshing.isCompleted) refreshing.complete();
        await release.future;
        await _reply(
          request,
          _token(access: 'fixture-access-2', refresh: 'fixture-refresh-2')
            ..remove('org_id'),
        );
      } else if (++polls == 1) {
        await _reply(request, {'error': 'authorization_pending'}, status: 400);
      } else {
        await _reply(request, _token());
      }
    };
    final notifications = <List<String>>[];
    await auth.login(
      notify: (url, code) => notifications.add([url, code]),
      cancellation: CancellationToken(),
    );
    expect(notifications, [
      [endpoint.resolve('/console/verify?user_code=ABCD').toString(), 'ABCD'],
    ]);
    final device = requests.first;
    expect(device['method'], 'POST');
    expect(device['body'], {
      'client_id': 'opencode-cli',
      'supports_org_scope': true,
    });
    expect(
      requests
          .where((request) => request['path'] == '/console/auth/device/token')
          .map((request) => request['body']),
      everyElement({
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        'device_code': 'fixture-device',
        'client_id': 'opencode-cli',
      }),
    );
    expect(polls, 2);
    expect(
      requests
          .where(
            (request) =>
                (request['path'] as String).startsWith('/console/api/'),
          )
          .map((request) => request['authorized']),
      everyElement(true),
    );
    expect(await auth.credentials(), {
      'access_token': 'fixture-access-1',
      'org_id': 'personal-org',
    });
    final file = File('${directory.path}/opencode-auth.json');
    final original = jsonObject(jsonDecode(await file.readAsString()));
    expect(original['refresh_token'], 'fixture-refresh-1');
    expect(original['server'], endpoint.toString());
    if (!Platform.isWindows) {
      expect((await file.stat()).mode & 0x1ff, 0x180);
      expect((await directory.stat()).mode & 0x1ff, 0x1c0);
    }
    final concurrent = List.generate(
      12,
      (_) => auth.credentials(refresh: true),
    );
    await refreshing.future.timeout(const Duration(seconds: 2));
    release.complete();
    final credentials = await Future.wait(concurrent);
    expect(refreshes, 1);
    expect(
      credentials,
      everyElement({
        'access_token': 'fixture-access-2',
        'org_id': 'personal-org',
      }),
    );
    final refreshed = jsonObject(jsonDecode(await file.readAsString()));
    expect(refreshed['refresh_token'], 'fixture-refresh-2');
    final refreshRequest = requests.lastWhere(
      (request) => request['body']['grant_type'] == 'refresh_token',
    );
    expect(refreshRequest['body'], {
      'grant_type': 'refresh_token',
      'refresh_token': 'fixture-refresh-1',
      'client_id': 'opencode-cli',
    });
    auth.close();
    auth = OpenCodeAuthManager(directory.path, http: http, endpoint: endpoint);
    expect(await auth.credentials(), {
      'access_token': 'fixture-access-2',
      'org_id': 'personal-org',
    });
    expect(refreshes, 1);
  });

  test('ambiguous or unknown organizations fail without saving a different workspace', () async {
    for (final selected in [null, 'unknown-org']) {
      tokenHandler = (request, _) {
        final token = _token();
        if (selected == null) {
          token.remove('org_id');
        } else {
          token['org_id'] = selected;
        }
        return _reply(request, token);
      };
      await expectLater(login(), throwsStateError);
      expect(
        await File('${directory.path}/opencode-auth.json').exists(),
        false,
      );
    }
  });

  for (final phase in ['headers', 'body']) {
    test(
      'caller cancellation releases pending auth $phase and permits a fresh login',
      () async {
        final waiting = Completer<void>();
        handler = (request, _) async {
          if (phase == 'body') {
            request.response.headers.contentType = ContentType.json;
            request.response.write('{"device_code":');
            await request.response.flush();
          }
          waiting.complete();
        };
        final cancellation = CancellationToken();
        final outcome = expectLater(
          auth.login(notify: (_, _) {}, cancellation: cancellation),
          throwsA(isA<CancelledException>()),
        );
        await waiting.future.timeout(const Duration(seconds: 2));
        cancellation.cancel();
        await outcome.timeout(const Duration(seconds: 2));
        expect(
          await File('${directory.path}/opencode-auth.json').exists(),
          false,
        );
        handler = ordinary;
        await login();
        expect((await auth.credentials())['org_id'], 'personal-org');
      },
    );
  }

  test(
    'slow_down postpones polling until device expiry cancels the wait',
    () async {
      handler = (request, body) async {
        if (request.uri.path == '/console/auth/device/code') {
          await _reply(request, _device()..['expires_in'] = 0.1);
        } else {
          await ordinary(request, body);
        }
      };
      var polls = 0;
      tokenHandler = (request, _) async {
        polls++;
        if (polls == 1) {
          await _reply(request, {'error': 'slow_down'}, status: 400);
        } else {
          await _reply(request, _token());
        }
      };
      await expectLater(login(), throwsA(isA<TimeoutException>()));
      expect(polls, 1);
      expect(
        await File('${directory.path}/opencode-auth.json').exists(),
        false,
      );
    },
  );

  test('owner disposal aborts shared refresh and preserves the last committed login', () async {
    await login();
    final file = File('${directory.path}/opencode-auth.json');
    final committed = await file.readAsString();
    final waiting = Completer<void>();
    tokenHandler = (request, _) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"access_token":');
      await request.response.flush();
      waiting.complete();
    };
    final one = auth.credentials(refresh: true),
        two = auth.credentials(refresh: true);
    final outcomes = [
      expectLater(one, throwsA(isA<CancelledException>())),
      expectLater(two, throwsA(isA<CancelledException>())),
    ];
    await waiting.future.timeout(const Duration(seconds: 2));
    auth.close();
    await Future.wait(outcomes).timeout(const Duration(seconds: 2));
    expect(await file.readAsString(), committed);
    final request = await http.getUrl(endpoint.replace(path: '/health'));
    final response = await request.close();
    expect(response.statusCode, 200);
    await response.drain<void>();
  });

  test('refresh denials and changed organization do not expose response data or replace saved credentials', () async {
    await login();
    final file = File('${directory.path}/opencode-auth.json');
    final committed = await file.readAsString();
    tokenHandler = (request, _) => _reply(request, {
      'error': 'invalid_grant',
      'message': 'secret-response-fixture',
    }, status: 400);
    await expectLater(
      auth.credentials(refresh: true),
      throwsA(
        isA<StateError>().having(
          (error) => error.toString(),
          'safe message',
          isNot(contains('secret-response-fixture')),
        ),
      ),
    );
    expect(await file.readAsString(), committed);
    tokenHandler = (request, _) =>
        _reply(request, _token()..['org_id'] = 'unrelated-org');
    await expectLater(auth.credentials(refresh: true), throwsStateError);
    expect(await file.readAsString(), committed);
    final other = OpenCodeAuthManager(
      directory.path,
      http: http,
      endpoint: endpoint.replace(path: '/other-console'),
    );
    final previousCount = requests.length;
    await expectLater(other.credentials(refresh: true), throwsStateError);
    expect(requests.length, previousCount);
    other.close();
  });
}

Json _device() => {
  'device_code': 'fixture-device',
  'user_code': 'ABCD',
  'verification_uri_complete': 'verify?user_code=ABCD',
  'expires_in': 30,
  'interval': 0.01,
};

Json _token({
  String access = 'fixture-access-1',
  String refresh = 'fixture-refresh-1',
}) => {
  'access_token': access,
  'refresh_token': refresh,
  'expires_in': 3600,
  'org_id': 'personal-org',
};

Future<void> _reply(
  HttpRequest request,
  Object body, {
  int status = 200,
}) async {
  request.response.statusCode = status;
  request.response.headers.contentType = ContentType.json;
  request.response.write(jsonEncode(body));
  await request.response.close();
}
