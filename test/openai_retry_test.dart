import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai/ai.dart';
import 'package:fake_async/fake_async.dart';
import 'package:openai/openai.dart';
import 'package:openai/src/retry.dart';
import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  for (final compaction in [false, true]) {
    test('${compaction ? 'compaction' : 'sampling'} shares two retries across connection, HTTP, and stream failures', () {
      fakeAsync((time) {
        final transport = _Transport((attempt, _) => switch (attempt) {
          1 => throw const SocketException('Connection reset by peer'),
          2 => _json(503, {}),
          _ => _events([]),
        });
        final events = <Json>[];
        final reply = _settle(time, _respond(_client(transport),
          input: compaction ? [{'type': 'compaction_trigger'}] : [], onEvent: events.add));
        expect(reply.error, isA<ModelFailure>().having((error) => error.code, 'code', 'stream_disconnected'));
        expect(transport.bodies, hasLength(3));
        expect(events.map((event) => event['attempt']), [1, 2]);
        expect(events.every((event) => event['max_retries'] == 2), isTrue);
        expect(events.map((event) => event['delay_ms']), [
          inInclusiveRange(180, 220), inInclusiveRange(360, 440),
        ]);
        expect(transport.bodies.every((body) => jsonEncode(body) == jsonEncode(transport.bodies.first)), isTrue);
      });
    });
  }

  test('cancelling a connection backoff stops retries and leaves the shared pool usable', () {
    fakeAsync((time) {
      var offline = true;
      final transport = _Transport((_, _) {
        if (offline) throw const SocketException('Connection reset by peer');
        return _events([_completed]);
      });
      final client = _client(transport);
      final token = CancellationToken();
      final events = <Json>[];
      final pending = _respond(client, cancellation: token, onEvent: events.add);
      time.flushMicrotasks();
      expect(events.single['attempt'], 1);
      token.cancel();
      expect(_settle(time, pending).error, isA<CancelledException>());
      expect(transport.bodies, hasLength(1));
      offline = false;
      expect(_settle(time, _respond(client)).value!.text, 'Recovered');
      expect(transport.bodies, hasLength(2));
    });
  });

  for (final search in [false, true]) {
    test('${search ? 'search' : 'responses'} recover from transient 5xx within two retries', () async {
      final transport = _Transport((attempt, _) => attempt < 3
        ? _json(503, {'error': {'code': 'server_error'}})
        : search ? _json(200, {'output': 'Recovered'}) : _events([_completed]));
      final client = _client(transport);
      final events = <Json>[];
      await _fast(() => search ? _search(client) : _respond(client, onEvent: events.add));
      expect(transport.bodies, hasLength(3));
      expect(events.map((event) => event['attempt']), search ? isEmpty : [1, 2]);
      expect(transport.paths.toSet(), {search ? '/alpha/search' : '/responses'});
    });

    test('${search ? 'search' : 'responses'} stop after three failed requests', () async {
      final transport = _Transport((_, _) => _json(500, {}));
      final client = _client(transport);
      await expectLater(_fast(() => search ? _search(client) : _respond(client)), throwsA(isA<ModelFailure>()));
      expect(transport.bodies, hasLength(3));
    });

    test('${search ? 'search' : 'responses'} cancellation interrupts a request backoff', () async {
      final transport = _Transport((_, _) => _json(503, {}));
      final client = _client(transport);
      final token = CancellationToken();
      await expectLater(_fast(() => search ? _search(client, token) : _respond(client, cancellation: token),
        onWait: (_) => scheduleMicrotask(token.cancel)), throwsA(isA<CancelledException>()));
      expect(transport.bodies, hasLength(1));
    });

    test('${search ? 'search' : 'responses'} refresh authentication once without spending retry budgets', () async {
      final refreshes = <bool>[];
      final transport = _Transport((attempt, _) => attempt == 1 ? _json(401, {})
        : search ? _json(200, {'output': 'Recovered'}) : _events([_completed]));
      final client = _client(transport, refreshes: refreshes);
      await _fast(() => search ? _search(client) : _respond(client));
      expect(refreshes, [false, true]);
      expect(transport.bodies, hasLength(2));
    });

    test('${search ? 'search' : 'responses'} return long server cooldowns without waiting or retrying early', () {
      fakeAsync((time) {
        final transport = _Transport((_, _) => _json(503, {}, headers: {'retry-after': '60'}));
        final client = _client(transport);
        expect(_settle(time, search ? _search(client) : _respond(client)).error, isA<ModelFailure>());
        expect(transport.bodies, hasLength(1));
      });
    });

    test('${search ? 'search' : 'responses'} bound stalled response headers', () {
      fakeAsync((time) {
        final transport = _Transport((_, _) => Completer<HttpReply>().future);
        final client = _client(transport);
        final result = _settle(time, search ? _search(client) : _respond(client),
          within: const Duration(seconds: 31));
        expect(result.error, search
          ? isA<ModelFailure>().having((error) => error.code, 'code', 'web_search_timeout')
          : isA<TimeoutException>());
        expect(transport.bodies, hasLength(3));
      });
    });
  }

  test('search connection resets stop within a second', () {
    fakeAsync((time) {
      final transport = _Transport((_, _) => throw const SocketException('Connection reset by peer'));
      expect(_settle(time, _search(_client(transport))).error,
        isA<ModelFailure>().having((error) => error.code, 'code', 'web_search_transport'));
      expect(transport.bodies, hasLength(3));
    });
  });

  test('a socket reset after headers uses the same bounded recovery', () {
    fakeAsync((time) {
      final transport = _Transport((_, _) {
        final source = StreamController<List<int>>(onCancel: () => Future<void>.value());
        source.addError(const SocketException('Connection reset by peer'));
        unawaited(source.close());
        return HttpReply(source.stream, 200, {}, '2');
      });
      final events = <Json>[];
      final result = _settle(time, _respond(_client(transport), onEvent: events.add));
      expect(result.error, isA<ModelFailure>().having((error) => error.code, 'code', 'stream_disconnected'));
      expect(transport.bodies, hasLength(3));
      expect(events.map((event) => event['attempt']), [1, 2]);
      expect(events.every((event) => event['max_retries'] == 2), isTrue);
    });
  });

  test('short HTTP Retry-After controls the shared retry waits', () async {
    final transport = _Transport((attempt, _) => attempt <= 2
      ? _json(503, {}, headers: {'retry-after': '2'}) : _events([_completed]));
    final events = <Json>[];
    expect((await _respond(_client(transport), onEvent: events.add)).text, 'Recovered');
    expect(transport.bodies, hasLength(3));
    expect(events, hasLength(2));
    expect(events.every((event) => (event['delay_ms'] as int) >= 1900 && (event['delay_ms'] as int) <= 2000), isTrue);
  });

  test('time spent reading an error body counts toward the original retry deadline', () async {
    final transport = _Transport((attempt, _) => attempt == 1 ? HttpReply(
      Stream.fromFuture(Future.delayed(const Duration(milliseconds: 40), () => utf8.encode('{}'))),
      503, {'retry-after': '1'}, '2') : _events([_completed]));
    final events = <Json>[];
    expect((await _respond(_client(transport), onEvent: events.add)).text, 'Recovered');
    expect(events.single['delay_ms'], inInclusiveRange(100, 970));
  });

  for (final status in [400, 503]) {
    test('a stalled HTTP $status body preserves the status and closes before recovery', () {
      fakeAsync((time) {
        var closed = 0;
        final transport = _Transport((_, _) => HttpReply(StreamController<List<int>>(
          onCancel: () { closed++; return Future<void>.value(); },
        ).stream, status, {}, '2'));
        final result = _settle(time, _respond(_client(transport)), within: const Duration(seconds: 7));
        expect(result.error, isA<ResponseFailure>().having((error) => error.status, 'status', status));
        expect(transport.bodies, hasLength(status == 400 ? 1 : 3));
        expect(closed, transport.bodies.length);
      });
    });
  }

  test('silent streams reconnect after 60 seconds and close every abandoned body', () {
    fakeAsync((time) {
      var closed = 0;
      final transport = _Transport((_, _) => HttpReply(StreamController<List<int>>(
        onCancel: () { closed++; return Future<void>.value(); },
      ).stream, 200, {}, '2'));
      final result = _settle(time, _respond(_client(transport)), within: const Duration(seconds: 181));
      expect(result.error, isA<ModelFailure>().having((error) => error.code, 'code', 'stream_idle_timeout'));
      expect(transport.bodies, hasLength(3));
      expect(closed, 3);
    });
  });

  test('SSE heartbeats keep long reasoning alive without a response deadline', () {
    fakeAsync((time) {
      final transport = _Transport((_, _) {
        late Timer heartbeat;
        var ticks = 0;
        final source = StreamController<List<int>>(onCancel: () {
          heartbeat.cancel();
          return Future<void>.value();
        });
        heartbeat = Timer.periodic(const Duration(seconds: 25), (_) {
          source.add(utf8.encode(++ticks < 4 ? ': keep-alive\n\n' : 'data: ${jsonEncode(_completed)}\n\n'));
        });
        return HttpReply(source.stream, 200, {}, '2');
      });
      final result = _settle(time, _respond(_client(transport)), within: const Duration(seconds: 101));
      expect(result.error, isNull);
      expect(result.value!.text, 'Recovered');
      expect(transport.bodies, hasLength(1));
    });
  });

  test('rate limit messages supply the retry delay in milliseconds and seconds', () async {
    for (final message in ['Try again in 250 ms', 'Try again in 0.25 seconds']) {
      final transport = _Transport((attempt, _) => _events(attempt == 1 ? [
        {'type': 'response.failed', 'response': {'error': {'code': 'rate_limit_exceeded', 'message': message}}},
      ] : [_completed]));
      final waits = <Duration>[];
      await _fast(() => _respond(_client(transport)), onWait: waits.add);
      expect(waits.single.inMilliseconds, inInclusiveRange(230, 250));
    }
  });

  for (final error in [
    {'code': 'server_error'},
    {'code': 'unknown_transient_error'},
    {'code': 'rate_limit_exceeded', 'message': 'Please try again in 250 ms'},
    {'code': 'slow_down', 'message': 'Please try again in 0.25 seconds'},
    {'code': 'server_is_overloaded', 'headers': {'Retry-After': '0'}},
    {'code': 'policy_capacity_unavailable', 'headers': {'retry-after': '0'}},
  ]) {
    test('stream errors retry ${error['code']} with Codex classification', () {
      fakeAsync((time) {
        final transport = _Transport((attempt, _) => _events(attempt == 1
          ? [{'type': 'response.failed', 'response': {'error': error}}] : [_completed]));
        expect(_settle(time, _respond(_client(transport))).value!.text, 'Recovered');
        expect(transport.bodies, hasLength(2));
      });
    });
  }

  for (final error in [
    {'code': 'context_length_exceeded'}, {'code': 'insufficient_quota'},
    {'code': 'usage_limit_reached'}, {'code': 'invalid_prompt'}, {'code': 'model_not_found'},
    {'code': 'flex_unavailable'}, {'code': 'cyber_policy'},
    {'code': 'server_is_overloaded'}, {'code': 'policy_capacity_unavailable'},
  ]) {
    test('terminal stream errors do not retry ${error['code']}', () {
      fakeAsync((time) {
        final transport = _Transport((_, _) => _events([
          {'type': 'response.failed', 'response': {'error': error}},
        ]));
        expect(_settle(time, _respond(_client(transport))).error, isA<ModelFailure>());
        expect(transport.bodies, hasLength(1));
      });
    });
  }

  for (final status in [400, 401, 403, 429]) {
    test('HTTP $status without retry advice remains terminal', () async {
        final transport = _Transport((_, _) => _json(status, {}));
        await expectLater(_respond(_client(transport)), throwsA(isA<ModelFailure>()));
        expect(transport.bodies, hasLength(status == 401 ? 2 : 1));
    });
  }

  test('429 Retry-After is a stream retry; quota failures remain terminal with advice', () async {
      final transport = _Transport((attempt, _) => attempt == 1
        ? _json(429, {}, headers: {'retry-after': '0'}) : _events([_completed]));
      final events = <Json>[];
      expect((await _respond(_client(transport), onEvent: events.add)).text, 'Recovered');
      expect(events.single['attempt'], 1);
      expect(transport.bodies, hasLength(2));
      transport.reply = (_, _) => _json(429, {'error': {'type': 'insufficient_quota'}}, headers: {'retry-after': '0'});
      await expectLater(_respond(_client(transport)), throwsA(isA<ModelFailure>()));
      expect(transport.bodies, hasLength(3));
  });

  test('retry advice accepts seconds and HTTP dates and rejects malformed values', () {
    expect(retryAdvice(' 12 ')!.delay, const Duration(seconds: 12));
    expect(retryAdvice('0')!.delay, Duration.zero);
    expect(retryAdvice(HttpDate.format(DateTime.now().add(const Duration(seconds: 10))))!.delay.inSeconds, inInclusiveRange(8, 10));
    expect(retryAdvice('Wed, 21 Oct 2015 07:28:00 GMT')!.delay, Duration.zero);
    for (final value in [null, '', '-1', '1.5', 'NaN', 'Infinity', '9999999999999999999999', 'invalid']) {
      expect(retryAdvice(value), isNull, reason: '$value');
    }
  });
}

const _completed = <String, dynamic>{'type': 'response.completed', 'response': {
  'status': 'completed', 'output': [{'type': 'message', 'content': [{'type': 'output_text', 'text': 'Recovered'}]}],
}};

HttpReply _json(int status, Json body, {Map<String, String> headers = const {}}) =>
  HttpReply(_bytes(jsonEncode(body)), status, headers, '2');

HttpReply _events(List<Json> events) => HttpReply(_bytes(
  events.map((event) => 'data: ${jsonEncode(event)}\n\n').join()), 200, {}, '2');

Stream<List<int>> _bytes(String body) {
  // A zone-local cancellation future lets FakeAsync drive stream cleanup too.
  final source = StreamController<List<int>>(onCancel: () => Future<void>.value());
  source.add(utf8.encode(body));
  unawaited(source.close());
  return source.stream;
}

class _Transport extends HttpConnections {
  _Transport(this.reply);
  FutureOr<HttpReply> Function(int attempt, Json body) reply;
  final bodies = <Json>[];
  final paths = <String>[];

  @override
  Future<HttpReply> send(HttpClient http, String method, Uri uri, {
    required CancellationToken cancellation, Map<String, String> headers = const {}, List<int> body = const [],
  }) async {
    cancellation.throwIfCancelled();
    bodies.add(jsonObject(jsonDecode(utf8.decode(body))));
    paths.add(uri.path);
    return Future<HttpReply>.sync(() => reply(bodies.length, bodies.last)).asCancellable(cancellation);
  }
}

ResponsesClient _client(_Transport transport, {List<bool>? refreshes}) {
  final http = HttpClient();
  addTearDown(() { http.close(force: true); return transport.close(); });
  return ResponsesClient(http: http, connections: transport, endpoint: Uri.parse('https://fixture.test/responses'),
    credentials: ({bool refresh = false}) async {
      refreshes?.add(refresh);
      return {'access_token': 'fixture', 'account_id': 'fixture'};
    });
}

Future<ResponsesReply> _respond(ResponsesClient client, {
  CancellationToken? cancellation, List<Json> input = const [], void Function(Json)? onEvent,
}) => client.respond(model: 'gpt-6.1-sol', instructions: '', input: input, tools: [],
  sessionId: 'fixture', cancellation: cancellation ?? CancellationToken(), onEvent: onEvent);

Future<String> _search(ResponsesClient client, [CancellationToken? cancellation]) => client.search(
  model: 'gpt-6.1-sol', sessionId: 'fixture', commands: {}, input: [], cancellation: cancellation ?? CancellationToken());

({T? value, Object? error}) _settle<T>(FakeAsync time, Future<T> future, {
  Duration within = const Duration(seconds: 1),
}) {
  T? value;
  Object? error;
  var settled = false;
  future.then((result) { value = result; settled = true; }, onError: (Object failure) { error = failure; settled = true; });
  time.flushMicrotasks();
  time.elapse(within);
  expect(settled, isTrue, reason: 'Retry operation did not settle');
  return (value: value, error: error);
}

Future<T> _fast<T>(Future<T> Function() run, {void Function(Duration)? onWait}) => runZoned(run,
  zoneSpecification: ZoneSpecification(createTimer: (self, parent, zone, duration, callback) {
    final backoff = duration >= const Duration(milliseconds: 100) && duration <= const Duration(milliseconds: 450);
    if (backoff) onWait?.call(duration);
    return parent.createTimer(zone, backoff ? Duration.zero : duration, callback);
  }));
