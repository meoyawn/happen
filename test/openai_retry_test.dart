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
    test('${compaction ? 'compaction' : 'sampling'} recovers across connection, HTTP, and stream failures', () {
      fakeAsync((time) {
        final transport = _Transport((attempt, _) => switch (attempt) {
          1 => throw const SocketException('Connection reset by peer'),
          2 => _json(503, {}),
          3 => _events([]),
          _ => _events([_completed]),
        });
        final events = <Json>[];
        final reply = _settle(time, _respond(_client(transport),
          input: compaction ? [{'type': 'compaction_trigger'}] : [], onEvent: events.add),
          within: const Duration(seconds: 2));
        expect(reply.error, isNull);
        expect(reply.value!.text, 'Recovered');
        expect(transport.bodies, hasLength(4));
        expect(events.map((event) => event['layer']), ['http', 'http', 'stream']);
        expect(events.map((event) => event['attempt']), [1, 2, 1]);
        expect(events.map((event) => event['max_retries']), [4, 4, 5]);
        expect(events.map((event) => event['delay_ms']), [
          inInclusiveRange(180, 220), inInclusiveRange(360, 440), inInclusiveRange(180, 220),
        ]);
        expect(transport.bodies.every((body) => jsonEncode(body) == jsonEncode(transport.bodies.first)), isTrue);
      });
    });
  }

  for (final layer in ['http', 'connection']) {
    test('cancelling a $layer backoff stops retries and leaves the shared pool usable', () {
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
        if (layer == 'connection') time.elapse(const Duration(seconds: 4));
        expect(events.last['layer'], layer);
        expect(events.last['attempt'], 1);
        token.cancel();
        expect(_settle(time, pending).error, isA<CancelledException>());
        expect(transport.bodies, hasLength(layer == 'http' ? 1 : 5));
        expect(token.hasCancellables, isFalse);
        offline = false;
        expect(_settle(time, _respond(client)).value!.text, 'Recovered');
        expect(transport.bodies, hasLength(layer == 'http' ? 2 : 6));
      });
    });
  }

  // Codex's network retry counter does not consume the sampling retry budget.
  test('connection recovery keeps five stream retries and caps network waits at 60 seconds', () {
    fakeAsync((time) {
      var offline = true;
      var streamFailures = 5;
      final transport = _Transport((_, _) {
        if (offline) throw const SocketException('Connection refused');
        return _events(streamFailures-- > 0 ? [] : [_completed]);
      });
      final events = <Json>[];
      final pending = _respond(_client(transport), onEvent: events.add);
      time.elapse(const Duration(seconds: 180));
      final network = events.where((event) => event['layer'] == 'connection');
      expect(network.map((event) => event['attempt']), [1, 2, 3, 4, 5, 6]);
      expect(network.map((event) => event['delay_ms']), [5000, 10000, 20000, 40000, 60000, 60000]);
      expect(network.every((event) => !event.containsKey('max_retries')), isTrue);
      offline = false;
      expect(_settle(time, pending, within: const Duration(seconds: 45)).value!.text, 'Recovered');
      expect(events.where((event) => event['layer'] == 'stream').map((event) => event['attempt']), [1, 2, 3, 4, 5]);
      expect(transport.bodies, hasLength(36));
    });
  });

  test('compaction connection failures exhaust both retry budgets', () {
    fakeAsync((time) {
      final transport = _Transport((_, _) => throw const SocketException('Connection refused'));
      final events = <Json>[];
      final result = _settle(time, _respond(_client(transport),
        input: [{'type': 'compaction_trigger'}], onEvent: events.add), within: const Duration(seconds: 30));
      expect(result.error, isA<SocketException>());
      expect(transport.bodies, hasLength(30));
      expect(events.where((event) => event['layer'] == 'stream').map((event) => event['attempt']), [1, 2, 3, 4, 5]);
      expect(events.any((event) => event['layer'] == 'connection'), isFalse);
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

    test('${search ? 'search times out during' : 'responses explain and wait through'} long server cooldowns without retrying early', () {
      fakeAsync((time) {
        for (final (seconds, error, streamed) in [
          (60, {'code': 'server_is_overloaded', 'message': 'The selected model is overloaded.'}, false),
          if (!search) (310, {'code': 'rate_limit_exceeded', 'message': 'Try again in 310 seconds'}, true),
        ]) {
          final transport = _Transport((attempt, _) => attempt != 1 ? _events([_completed])
            : streamed ? _events([{'type': 'response.failed', 'response': {'error': error}}])
            : _json(503, {'error': error}, headers: {'retry-after': '$seconds'}));
          final client = _client(transport);
          if (search) {
            expect(_settle(time, _search(client), within: const Duration(seconds: 31)).error,
              isA<ModelFailure>().having((error) => error.code, 'code', 'web_search_timeout'));
            expect(transport.bodies, hasLength(1));
            continue;
          }
          final events = <Json>[];
          final pending = _respond(client, onEvent: events.add);
          time.flushMicrotasks();
          expect(events.single['error'], {
            ...error, if (!streamed) 'http_status': 503,
          });
          expect(events.single['provider_delay'], isTrue);
          expect(events.single['message'], 'Retrying provider (1/${streamed ? 5 : 4})');
          expect(events.single['delay_ms'], inInclusiveRange(seconds * 1000 - 100, seconds * 1000));
          time.elapse(Duration(seconds: seconds - 1));
          expect(transport.bodies, hasLength(1));
          expect(_settle(time, pending, within: const Duration(seconds: 2)).value!.text, 'Recovered');
          expect(transport.bodies, hasLength(2));
        }
      });
    });

    test('${search ? 'search bounds' : 'responses recover from'} stalled response headers', () {
      fakeAsync((time) {
        final transport = _Transport((attempt, _) => attempt < 4
          ? Completer<HttpReply>().future
          : Future.delayed(const Duration(seconds: 45), () => _events([_completed])));
        final client = _client(transport);
        final result = _settle(time, search ? _search(client) : _respond(client),
          within: Duration(seconds: search ? 31 : 230));
        if (search) {
          expect(result.error, isA<ModelFailure>().having((error) => error.code, 'code', 'web_search_timeout'));
        } else {
          expect(result.error, isNull);
          expect(result.value, isA<ResponsesReply>().having((reply) => reply.text, 'text', 'Recovered'));
        }
        expect(transport.bodies, hasLength(search ? 3 : 4));
        expect(transport.requests.take(3).every((request) => request.aborted), isTrue);
        if (!search) {
          transport.reply = (_, _) => Completer<HttpReply>().future;
          final token = CancellationToken();
          final pending = _respond(client, cancellation: token);
          time.flushMicrotasks();
          token.cancel();
          expect(_settle(time, pending).error, isA<CancelledException>());
          expect(transport.requests.last.aborted, isTrue);
          expect(token.hasCancellables, isFalse);
        }
      });
    });
  }

  // Ported from Codex core/tests/suite/retry_after.rs: HTTP and stream
  // budgets remain independent, including when the provider supplies advice.
  for (final compaction in [false, true]) {
    for (final (name, status, code, advised, requests, httpRetries, streamRetries) in [
      ('HTTP server failure', 500, 'server_error', false, 30, 24, 5),
      ('HTTP overload without advice', 503, 'server_is_overloaded', false, 5, 4, 0),
      ('HTTP overload with advice', 503, 'server_is_overloaded', true, 30, 24, 5),
      ('HTTP rate limit without advice', 429, 'rate_limit_exceeded', false, 1, 0, 0),
      ('HTTP rate limit with advice', 429, 'rate_limit_exceeded', true, 6, 0, 5),
      ('stream server failure', null, 'server_error', false, 6, 0, 5),
      ('stream rate limit without advice', null, 'rate_limit_exceeded', false, 6, 0, 5),
      ('stream overload without advice', null, 'server_is_overloaded', false, 1, 0, 0),
      ('stream overload with advice', null, 'server_is_overloaded', true, 6, 0, 5),
    ]) {
      test('${compaction ? 'compaction' : 'sampling'} bounds $name using Codex retry budgets', () {
        fakeAsync((time) {
          final error = {'code': code, 'message': 'Fixture provider failure.',
            if (advised && status == null) 'headers': {'Retry-After': '0'}};
          final transport = _Transport((_, _) => status == null
            ? _events([{'type': 'response.failed', 'response': {'error': error}}])
            : _json(status, {'error': error}, headers: {if (advised) 'retry-after': '0'}));
          final events = <Json>[];
          final result = _settle(time, _respond(_client(transport),
            input: compaction ? [{'type': 'compaction_trigger'}] : [],
            onEvent: events.add), within: const Duration(seconds: 30));
          expect(result.error, isA<ResponseFailure>()
            .having((error) => error.code, 'code', code)
            .having((error) => error.message, 'message', 'Fixture provider failure.'));
          expect(transport.bodies, hasLength(requests));
          final http = events.where((event) => event['layer'] == 'http');
          final stream = events.where((event) => event['layer'] == 'stream');
          expect(http, hasLength(httpRetries));
          expect(http.map((event) => event['attempt']), [for (var i = 0; i < httpRetries; i++) i % 4 + 1]);
          expect(http.every((event) => event['max_retries'] == 4), isTrue);
          expect(stream.map((event) => event['attempt']), [for (var i = 1; i <= streamRetries; i++) i]);
          expect(stream.every((event) => event['max_retries'] == 5), isTrue);
          final count = transport.bodies.length;
          time.elapse(const Duration(hours: 1));
          expect(transport.bodies, hasLength(count), reason: 'Exhaustion must leave no retry timer running');
        });
      });
    }
  }

  test('search stops after five failed requests', () {
    fakeAsync((time) {
      final transport = _Transport((_, _) => _json(500, {}));
      expect(_settle(time, _search(_client(transport)), within: const Duration(seconds: 4)).error,
        isA<ModelFailure>());
      expect(transport.bodies, hasLength(5));
    });
  });

  test('search connection resets exhaust the HTTP budget', () {
    fakeAsync((time) {
      final transport = _Transport((_, _) => throw const SocketException('Connection reset by peer'));
      expect(_settle(time, _search(_client(transport)), within: const Duration(seconds: 4)).error,
        isA<ModelFailure>().having((error) => error.code, 'code', 'web_search_transport'));
      expect(transport.bodies, hasLength(5));
    });
  });

  test('socket resets after headers recover and close abandoned bodies', () {
    fakeAsync((time) {
      var closed = 0;
      final transport = _Transport((attempt, _) {
        if (attempt == 5) return _events([_completed]);
        final source = StreamController<List<int>>(onCancel: () {
          closed++;
          return Future<void>.value();
        });
        source.addError(const SocketException('Connection reset by peer'));
        unawaited(source.close());
        return HttpReply(source.stream, 200, {}, '2');
      });
      final events = <Json>[];
      final result = _settle(time, _respond(_client(transport), onEvent: events.add),
        within: const Duration(seconds: 4));
      expect(result.error, isNull);
      expect(result.value!.text, 'Recovered');
      expect(transport.bodies, hasLength(5));
      expect(closed, 4);
      expect(events.map((event) => event['attempt']), [1, 2, 3, 4]);
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
        final transport = _Transport((attempt, _) => attempt == 4 ? _events([_completed]) : HttpReply(StreamController<List<int>>(
          onCancel: () { closed++; return Future<void>.value(); },
        ).stream, status, {}, '2'));
        final result = _settle(time, _respond(_client(transport)), within: const Duration(seconds: 8));
        if (status == 400) {
          expect(result.error, isA<ResponseFailure>().having((error) => error.status, 'status', status));
        } else {
          expect(result.error, isNull);
          expect(result.value!.text, 'Recovered');
        }
        expect(transport.bodies, hasLength(status == 400 ? 1 : 4));
        expect(closed, status == 400 ? 1 : 3);
      });
    });
  }

  test('silent streams reconnect after 60 seconds and close every abandoned body', () {
    fakeAsync((time) {
      var closed = 0;
      final transport = _Transport((attempt, _) => attempt == 5 ? _events([_completed]) : HttpReply(StreamController<List<int>>(
        onCancel: () { closed++; return Future<void>.value(); },
      ).stream, 200, {}, '2'));
      final result = _settle(time, _respond(_client(transport)), within: const Duration(seconds: 244));
      expect(result.error, isNull);
      expect(result.value!.text, 'Recovered');
      expect(transport.bodies, hasLength(5));
      expect(closed, 4);
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

  // Ported from Codex's streamed Retry-After validation and precedence cases.
  for (final (name, headers, milliseconds) in [
    ('seconds', {'Retry-After': '2'}, 2000),
    ('tab padding', {'retry-after': '\t2\t'}, 2000),
    ('numeric JSON', {'retry-after': 2}, 2000),
    ('invalid newlines', {'retry-after': '\n2\n'}, 310000),
    ('negative interval', {'retry-after': '-1'}, 310000),
    ('duplicate header casing', {'Retry-After': '1', 'retry-after': '2'}, 2000),
  ]) {
    test('stream retry advice validates $name and takes precedence over plaintext', () {
      fakeAsync((time) {
        final error = {'code': 'rate_limit_exceeded', 'message': 'Try again in 310 seconds', 'headers': headers};
        final transport = _Transport((attempt, _) => _events(attempt == 1
          ? [{'type': 'response.failed', 'response': {'error': error}}] : [_completed]));
        final events = <Json>[];
        final pending = _respond(_client(transport), onEvent: events.add);
        time.flushMicrotasks();
        expect(events.single['delay_ms'], inInclusiveRange(milliseconds - 100, milliseconds));
        time.elapse(Duration(milliseconds: milliseconds - 100));
        expect(transport.bodies, hasLength(1));
        expect(_settle(time, pending).value!.text, 'Recovered');
        expect(transport.bodies, hasLength(2));
      });
    });
  }

  test('stream failures use local backoff rather than the enclosing HTTP response header', () {
    fakeAsync((time) {
      final transport = _Transport((attempt, _) => attempt == 1
        ? _events([{'type': 'response.failed', 'response': {'error': {
          'code': 'rate_limit_exceeded', 'message': 'Rate limit exceeded.',
        }}}], headers: {'retry-after': '310'}) : _events([_completed]));
      final events = <Json>[];
      expect(_settle(time, _respond(_client(transport), onEvent: events.add)).value!.text, 'Recovered');
      expect(events.single['delay_ms'], inInclusiveRange(180, 220));
      expect(events.single.containsKey('provider_delay'), isFalse);
      expect(transport.bodies, hasLength(2));
    });
  });

  for (final status in [429, 503]) {
    test('HTTP $status does not turn plaintext advice into a Retry-After header', () {
      fakeAsync((time) {
        final transport = _Transport((attempt, _) => attempt == 1 ? _json(status, {'error': {
          'code': status == 429 ? 'rate_limit_exceeded' : 'slow_down',
          'message': 'Try again in 310 seconds',
        }}) : _events([_completed]));
        final events = <Json>[];
        final result = _settle(time, _respond(_client(transport), onEvent: events.add));
        if (status == 429) {
          expect(result.error, isA<ResponseFailure>().having((error) => error.status, 'status', 429));
          expect(transport.bodies, hasLength(1));
          expect(events, isEmpty);
        } else {
          expect(result.value!.text, 'Recovered');
          expect(transport.bodies, hasLength(2));
          expect(events.single['delay_ms'], inInclusiveRange(180, 220));
          expect(events.single.containsKey('provider_delay'), isFalse);
        }
      });
    });
  }

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
        final needsAdvice = {'server_is_overloaded', 'policy_capacity_unavailable'}.contains(error['code']);
        final transport = _Transport((_, _) => _events([
          {'type': 'response.failed', 'response': {'error': {
            ...error, if (!needsAdvice) 'headers': {'Retry-After': '0'},
          }}},
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

  // These use scripted loopback WebSockets because the upgrade, frame parsing,
  // and fallback to an HTTP body are separate transport contracts.
  for (final code in ['websocket_connection_limit_reached', 'previous_response_not_found']) {
    test('WebSocket $code reconnects instead of failing the request', () async {
      final fixture = await _websocketFixture((attempt, _) => attempt == 1 ? [
        {'type': 'error', 'status': 400, 'error': {
          'code': code, 'message': 'Reconnect this WebSocket.', 'headers': {'Retry-After': '0'},
        }},
      ] : [_completed]);
      final events = <Json>[];
      expect((await _respond(fixture.client, transport: 'websocket', onEvent: events.add)).text, 'Recovered');
      expect(fixture.requests.map((request) => request.transport), ['websocket', 'websocket']);
      expect(events.single['layer'], 'stream');
      expect(events.single['attempt'], 1);
      expect(events.single['error'], {'code': code, 'message': 'Reconnect this WebSocket.', 'http_status': 400});
    });
  }

  test('WebSocket authentication refresh does not consume a retry budget', () async {
    final refreshes = <bool>[];
    final fixture = await _websocketFixture((attempt, _) => attempt == 1 ? [
      {'type': 'error', 'status': 401, 'error': {'code': 'unauthorized', 'message': 'Refresh authentication.'}},
    ] : [_completed], refreshes: refreshes);
    final events = <Json>[];
    expect((await _respond(fixture.client, transport: 'websocket', onEvent: events.add)).text, 'Recovered');
    expect(refreshes, [false, true]);
    expect(events, isEmpty);
    expect(fixture.requests, hasLength(2));
  });

  test('WebSocket fallback preserves the last provider deadline and stays on HTTP', () async {
    final fixture = await _websocketFixture((attempt, transport) => transport == 'websocket' ? [
      {'type': 'response.failed', 'response': {'error': {
        'code': 'server_error', 'message': 'Temporary stream failure.',
        'headers': {'Retry-After': attempt == 6 ? '1' : '0'},
      }}},
    ] : [_completed]);
    final events = <Json>[];
    expect((await _respond(fixture.client, transport: 'websocket', onEvent: events.add)).text, 'Recovered');
    expect(events.where((event) => event['layer'] == 'stream').map((event) => event['attempt']), [1, 2, 3, 4, 5]);
    expect(events.where((event) => event['layer'] == 'fallback'), hasLength(1));
    expect(fixture.requests.map((request) => request.transport), [
      for (var i = 0; i < 6; i++) 'websocket', 'http',
    ]);
    expect(fixture.requests[6].elapsed - fixture.requests[5].elapsed, greaterThanOrEqualTo(const Duration(seconds: 1)));
    expect(fixture.requests[5].body['type'], 'response.create');
    expect(fixture.requests[6].body.containsKey('type'), isFalse);
    expect(fixture.requests[6].body['stream'], isTrue);
    expect(fixture.requests[6].body['input'], fixture.requests[5].body['input']);
    expect((await _respond(fixture.client, transport: 'websocket')).text, 'Recovered');
    expect(fixture.requests, hasLength(8));
    expect(fixture.requests.last.transport, 'http');
  });

  for (final code in ['server_is_overloaded', 'policy_capacity_unavailable']) {
    test('WebSocket $code stops when advice is withdrawn without bypassing it through fallback', () async {
      final fixture = await _websocketFixture((attempt, _) => [
        {'type': 'error', 'status': 503, 'error': {
          'code': attempt == 6 ? code : 'server_is_overloaded',
          'message': attempt == 6 ? 'Final provider failure.' : 'Temporary overload.',
          if (attempt != 6) 'headers': {'Retry-After': '0'},
        }},
      ]);
      final events = <Json>[];
      await expectLater(_respond(fixture.client, transport: 'websocket', onEvent: events.add),
        throwsA(isA<ResponseFailure>().having((error) => error.code, 'code', code)
          .having((error) => error.message, 'message', 'Final provider failure.')));
      expect(events.map((event) => event['attempt']), [1, 2, 3, 4, 5]);
      expect(fixture.requests, hasLength(6));
      expect(fixture.requests.every((request) => request.transport == 'websocket'), isTrue);
    });
  }

  test('retry advice accepts seconds and HTTP dates and rejects malformed values', () {
    expect(retryAdvice(' 12 ')!.delay, const Duration(seconds: 12));
    expect(retryAdvice('0')!.delay, Duration.zero);
    expect(retryAdvice(HttpDate.format(DateTime.now().add(const Duration(seconds: 10))))!.delay.inSeconds, inInclusiveRange(8, 10));
    expect(retryAdvice('Wed, 21 Oct 2015 07:28:00 GMT')!.delay, Duration.zero);
    for (final value in [null, '', '-1', '1.5', 'NaN', 'Infinity', '9999999999999999999999', 'invalid']) {
      expect(retryAdvice(value), isNull, reason: '$value');
    }
  });

  // Codex scenarios_content_filter.rs and prompts/model_messages.rs. Recovery
  // changes the next actual request; ordinary transport retries above do not.
  for (final (name, guidance, expected) in [
    ('default', null, _filterGuidance), ('empty', ' \n ', _filterGuidance),
    ('catalog', 'Your previous response was blocked. Offer a permitted alternative.',
      'Your previous response was blocked. Offer a permitted alternative.'),
    ('512 UTF-8 bytes', 'é' * 256, 'é' * 256), ('oversized UTF-8', 'é' * 257, _filterGuidance),
  ]) {
    test('Codex content-filter recovery appends bounded $name guidance after each block and retains delivered output', () {
      final messages = GptModel('gpt-6.1-sol').data['model_messages'] as Map;
      final previous = messages['content_filter_guidance']; messages['content_filter_guidance'] = guidance;
      addTearDown(() => messages['content_filter_guidance'] = previous);
      fakeAsync((time) {
        const partial = {'type': 'message', 'id': 'partial-message', 'role': 'assistant',
          'content': [{'type': 'output_text', 'text': 'I can help with this topic.'}]};
        final transport = _Transport((attempt, _) => _events(attempt <= 2 ? [
          if (attempt == 1) {'type': 'response.output_item.done', 'output_index': 0, 'item': partial},
          _filtered,
        ] : [_completed]));
        final events = <Json>[];
        final result = _settle(time, _respond(_client(transport), input: const [
          {'type': 'message', 'role': 'user', 'content': [{'type': 'input_text', 'text': 'Help me with this topic.'}]},
        ], onEvent: events.add), within: const Duration(seconds: 2));
        expect(result.error, isNull); expect(result.value!.text, 'Recovered');
        expect(transport.bodies, hasLength(3));
        final inputs = transport.bodies.map((body) => body['input'] as List).toList();
        expect(inputs[0], hasLength(1)); expect(inputs[1], hasLength(3)); expect(inputs[2], hasLength(4));
        expect(inputs[1][1], partial); expect(inputs[2][1], partial);
        for (final input in [inputs[1].skip(2), inputs[2].skip(2)]) {
          for (final item in input) {
            expect(item['role'], 'developer');
            expect(item['content'], [{'type': 'input_text', 'text': '<content_filter_guidance>\n$expected\n</content_filter_guidance>'}]);
          }
        }
        expect(events.where((event) => event['type'] == 'model.output'), hasLength(1));
        expect(events.where((event) => event['type'] == 'model.retrying').map((event) => event['attempt']), [1, 2]);
      });
    });
  }
  for (final compaction in [false, true]) {
    test('Codex content-filter exhaustion keeps the stream budget and ${compaction ? 'does not add sampling guidance during compaction' : 'records guidance even for the final block'}', () {
      fakeAsync((time) {
        final transport = _Transport((_, _) => _events([_filtered]));
        final events = <Json>[];
        final result = _settle(time, _respond(_client(transport), input: [if (compaction) {'type': 'compaction_trigger'}],
          onEvent: events.add), within: const Duration(seconds: 15));
        expect(result.error, isA<ModelFailure>().having((error) => error.code, 'typed content filter', 'content_filter'));
        expect(transport.bodies, hasLength(6));
        expect(events.where((event) => event['type'] == 'model.recovery'), hasLength(compaction ? 0 : 6));
        expect(transport.bodies.map((body) => (body['input'] as List).length), compaction ? everyElement(1) : [0, 1, 2, 3, 4, 5]);
        final count = transport.bodies.length; time.elapse(const Duration(hours: 1)); expect(transport.bodies, hasLength(count));
      });
    });
  }
  test('cancelling content-filter host admission stops waiting without sending another request', () {
    fakeAsync((time) {
      final transport = _Transport((_, _) => _events([_filtered]));
      final blocked = Completer<void>(), cancellation = CancellationToken();
      var admitted = false;
      final pending = _client(transport).respond(model: 'gpt-6.1-sol', instructions: '', input: [], tools: [],
        sessionId: 'cancel-recovery', cancellation: cancellation, onRecovery: (_) { admitted = true; return blocked.future; });
      time.flushMicrotasks(); expect(admitted, true); cancellation.cancel();
      try {
        expect(_settle(time, pending).error, isA<CancelledException>());
        expect(transport.bodies, hasLength(1));
      } finally { blocked.complete(); time.flushMicrotasks(); }
    });
  });
}

const _filterGuidance = 'Your previous response was blocked by a content filter. Do not treat this as a transient failure or try to reproduce or work around the blocked content through repeated attempts, altered formatting, splitting, encoding, tools, subagents, or later wakes. Briefly explain the limitation and offer a permitted alternative. Continue unrelated authorized work.';
const _filtered = <String, dynamic>{'type': 'response.incomplete', 'response': {'incomplete_details': {'reason': 'content_filter'}}};

const _completed = <String, dynamic>{'type': 'response.completed', 'response': {
  'status': 'completed', 'output': [{'type': 'message', 'content': [{'type': 'output_text', 'text': 'Recovered'}]}],
}};

HttpReply _json(int status, Json body, {Map<String, String> headers = const {}}) =>
  HttpReply(_bytes(jsonEncode(body)), status, headers, '2');

HttpReply _events(List<Json> events, {Map<String, String> headers = const {}}) => HttpReply(_bytes(
  events.map((event) => 'data: ${jsonEncode(event)}\n\n').join()), 200, headers, '2');

Stream<List<int>> _bytes(String body) {
  // A zone-local cancellation future lets FakeAsync drive stream cleanup too.
  final source = StreamController<List<int>>(onCancel: () => Future<void>.value());
  source.add(utf8.encode(body));
  unawaited(source.close());
  return source.stream;
}

class _Transport implements HttpClient {
  _Transport(this.reply);
  FutureOr<HttpReply> Function(int attempt, Json body) reply;
  final bodies = <Json>[];
  final paths = <String>[];
  final requests = <_Request>[];

  @override
  Future<HttpClientRequest> openUrl(String method, Uri uri) async {
    final request = _Request(this, uri);
    requests.add(request);
    return request;
  }
  @override void close({bool force = false}) {}
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.transport, this.uri);
  final _Transport transport;
  @override final Uri uri;
  final bytes = <int>[];
  bool aborted = false;
  @override final headers = _Headers({});
  @override bool followRedirects = true;
  @override int contentLength = -1;
  @override void add(List<int> data) => bytes.addAll(data);
  @override Future<HttpClientResponse> close() async {
    transport.bodies.add(jsonObject(jsonDecode(utf8.decode(bytes))));
    transport.paths.add(uri.path);
    return _Response(await Future<HttpReply>.sync(() => transport.reply(transport.bodies.length, transport.bodies.last)));
  }
  @override void abort([Object? exception, StackTrace? stackTrace]) { aborted = true; }
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends StreamView<List<int>> implements HttpClientResponse {
  _Response(this.reply) : super(reply);
  final HttpReply reply;
  @override int get statusCode => reply.statusCode;
  @override String get reasonPhrase => reply.reasonPhrase;
  @override HttpHeaders get headers => _Headers(reply.headers);
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Headers implements HttpHeaders {
  _Headers(this.values);
  final Map<String, String> values;
  @override void forEach(void Function(String, List<String>) action) => values.forEach((name, value) => action(name, [value]));
  @override void set(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override List<String>? operator [](String name) => values[name] == null ? null : [values[name]!];
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ResponsesClient _client(_Transport transport, {List<bool>? refreshes}) {
  addTearDown(() => transport.close(force: true));
  return ResponsesClient(http: transport, endpoint: Uri.parse('https://fixture.test/responses'),
    credentials: ({bool refresh = false}) async {
      refreshes?.add(refresh);
      return {'access_token': 'fixture', 'account_id': 'fixture'};
    });
}

Future<ResponsesReply> _respond(ResponsesClient client, {
  CancellationToken? cancellation, List<Json> input = const [], void Function(Json)? onEvent, String transport = 'http',
}) => client.respond(model: 'gpt-6.1-sol', instructions: '', input: input, tools: [],
  sessionId: 'fixture', cancellation: cancellation ?? CancellationToken(), onEvent: onEvent, transport: transport);

Future<String> _search(ResponsesClient client, [CancellationToken? cancellation]) => client.search(
  model: 'gpt-6.1-sol', sessionId: 'fixture', commands: {}, input: [], cancellation: cancellation ?? CancellationToken());

({T? value, Object? error}) _settle<T>(FakeAsync time, Future<T> future, {
  Duration within = const Duration(seconds: 1),
}) {
  T? value;
  Object? error;
  var settled = false;
  unawaited(future.then((result) { value = result; settled = true; }, onError: (Object failure) { error = failure; settled = true; }));
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

Future<({ResponsesClient client, List<({String transport, Json body, Duration elapsed})> requests})>
  _websocketFixture(List<Json> Function(int attempt, String transport) script, {List<bool>? refreshes}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final requests = <({String transport, Json body, Duration elapsed})>[];
  final sockets = <WebSocket>[];
  final elapsed = Stopwatch()..start();
  List<Json> receive(String transport, String encoded) {
    requests.add((transport: transport, body: jsonObject(jsonDecode(encoded)), elapsed: elapsed.elapsed));
    return script(requests.length, transport);
  }
  server.listen((request) async {
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.listen((raw) {
        final events = receive('websocket', raw as String);
        for (final event in events) { socket.add(jsonEncode(event)); }
        if (events.isEmpty) unawaited(socket.close());
      });
    } else {
      final events = receive('http', await utf8.decoder.bind(request).join());
      request.response.headers.contentType = ContentType('text', 'event-stream');
      for (final event in events) { request.response.write('data: ${jsonEncode(event)}\n\n'); }
      await request.response.close();
    }
  });
  final client = ResponsesClient(endpoint: Uri.parse('http://127.0.0.1:${server.port}/responses'),
    credentials: ({bool refresh = false}) async {
      refreshes?.add(refresh);
      return {'access_token': 'fixture', 'account_id': 'fixture'};
    });
  addTearDown(() async {
    client.close();
    for (final socket in sockets) { await socket.close(); }
    await server.close(force: true);
  });
  return (client: client, requests: requests);
}
