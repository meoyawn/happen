// Modified ports of Codex 6abffd442d68 (Apache-2.0): rmcp-client/src/
// rmcp_client.rs timeout tests and codex-mcp/src/pagination_tests.rs.
// Exercise Happen's real operation/manager boundary with a virtual HTTP peer;
// the peer supplies wire replies, never timeout or retry decisions.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:mcp/mcp.dart';
import 'package:mcp/src/transport.dart' show McpConnection;
import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  test('Codex operation timeout identifies the method and rounds its duration', () {
    fakeAsync((time) {
      final peer = _Peer();
      try {
        peer.connect(time);
        peer.reply = (_) => Completer<_Reply>().future;
        final result = _Outcome(peer.connection.request('tools/list', {}, cancellation: peer.lifetime,
          timeout: const Duration(microseconds: 29999999)));
        time.elapse(const Duration(seconds: 30));
        expect(result.error, isA<TimeoutException>().having((error) => error.message,
          'diagnostic', 'timed out awaiting tools/list after 30s'));
        expect(peer.requests.last.aborted, true);
      } finally { peer.dispose(time); }
    });
  });

  for (final fallback in [false, true]) {
    test('Codex startup permits discovery past ten seconds and shares thirty seconds with fallback: $fallback', () {
      fakeAsync((time) {
        final peer = _Peer();
        try {
          peer.reply = (body) async {
            if (body['method'] == 'server/discover') {
              await Future<void>.delayed(const Duration(seconds: 20));
              return fallback ? const _Reply(error: {'code': -32601, 'message': 'method not found'}) : _normal(body);
            }
            await Future<void>.delayed(const Duration(seconds: 11));
            return _normal(body);
          };
          final result = _Outcome(peer.connection.connect(peer.lifetime));
          time.elapse(const Duration(seconds: 29));
          if (fallback) {
            expect(result.done, false);
            expect(peer.methods, ['server/discover', 'initialize']);
            time.elapse(const Duration(seconds: 1));
            expect(result.error, isA<TimeoutException>());
            expect(peer.methods, ['server/discover', 'initialize']);
            expect(peer.requests.last.aborted, true);
          } else {
            expect(result.error, isNull);
            expect(result.done, true);
            expect(peer.methods, ['server/discover']);
          }
        } finally { peer.dispose(time); }
      });
    });
  }

  test('Codex startup without a reply stops at thirty seconds without trying legacy', () {
    fakeAsync((time) {
      final peer = _Peer();
      try {
        peer.reply = (_) => Completer<_Reply>().future;
        final result = _Outcome(peer.connection.connect(peer.lifetime));
        time.elapse(const Duration(seconds: 29));
        expect(result.done, false);
        time.elapse(const Duration(seconds: 1));
        expect(result.error, isA<TimeoutException>());
        expect(peer.methods, ['server/discover']);
        expect(peer.requests.single.aborted, true);
      } finally { peer.dispose(time); }
    });
  });

  test('desktop MCP calls can complete after sixty seconds with Codex tool defaults', () {
    fakeAsync((time) {
      final peer = _Peer();
      try {
        final manager = peer.manager(time);
        peer.reply = (body) async {
          await Future<void>.delayed(const Duration(seconds: 90));
          return _normal(body);
        };
        final result = _Outcome(manager.callTool('mcp__peer__slow', {}, peer.lifetime));
        time.elapse(const Duration(seconds: 90));
        expect(result.error, isNull);
        expect(result.value, _complete);
      } finally { peer.dispose(time); }
    });
  });

  for (final (label, requested, limit) in [
    ('default', null, 300), ('shorter request', const Duration(seconds: 2), 2),
    ('longer request', const Duration(seconds: 600), 300),
  ]) {
    test('Codex tool timeout caps the $label at $limit seconds without closing the shared connection', () {
      fakeAsync((time) {
        final peer = _Peer();
        try {
          final manager = peer.manager(time);
          peer.reply = (_) => Completer<_Reply>().future;
          final result = _Outcome(requested == null
            ? manager.callTool('mcp__peer__slow', {}, peer.lifetime)
            : manager.callTool('mcp__peer__slow', {}, peer.lifetime, timeout: requested));
          time.elapse(Duration(seconds: limit - 1));
          expect(result.done, false);
          time.elapse(const Duration(seconds: 1));
          expect(result.error, isA<TimeoutException>());
          expect(peer.requests.last.aborted, true);
          expect(manager.status().single['state'], 'ready');
          expect(peer.lifetime.isCancelled, false);
          peer.reply = _normal;
          final next = _Outcome(manager.callTool('mcp__peer__slow', {}, peer.lifetime));
          time.flushMicrotasks();
          expect(next.value, _complete);
        } finally { peer.dispose(time); }
      });
    });
  }

  test('an explicitly unbounded raw operation still obeys caller cancellation', () {
    fakeAsync((time) {
      final peer = _Peer();
      try {
        peer.connect(time);
        peer.reply = (_) => Completer<_Reply>().future;
        final caller = CancellationToken();
        final result = _Outcome(peer.connection.request('events/stream', {}, cancellation: caller, timeout: null));
        time.elapse(const Duration(minutes: 10));
        expect(result.done, false);
        caller.cancel(); time.flushMicrotasks();
        expect(result.error, isA<CancelledException>());
        expect(peer.requests.last.aborted, true);
        expect(peer.connection.lifetime.isCancelled, false);
      } finally { peer.dispose(time); }
    });
  });

  test('Codex retries and backoff consume one operation deadline', () {
    fakeAsync((time) {
      final peer = _Peer();
      try {
        peer.connect(time);
        peer.reply = (_) async {
          await Future<void>.delayed(const Duration(seconds: 2));
          return const _Reply(status: 503, error: {'code': -32000, 'message': 'unavailable'});
        };
        final result = _Outcome(peer.connection.request('tools/list', {}, cancellation: peer.lifetime,
          timeout: const Duration(seconds: 5)));
        time.elapse(const Duration(seconds: 5));
        expect(result.error, isA<TimeoutException>());
        expect(peer.methods, ['server/discover', 'tools/list', 'tools/list']);
        time.elapse(const Duration(seconds: 2));
        expect(peer.methods, ['server/discover', 'tools/list', 'tools/list']);
      } finally { peer.dispose(time); }
    });
  });

  for (final cancel in [false, true]) {
    test('Codex OAuth preparation precedes the MCP clock and remains cancellable: $cancel', () {
      fakeAsync((time) {
        var prepare = false;
        final peer = _Peer(authorization: (token) async {
          if (prepare) await cancellableDelay(const Duration(seconds: 2), token);
          return 'fixture';
        });
        try {
          peer.connect(time); prepare = true;
          final caller = CancellationToken();
          final result = _Outcome(peer.connection.requestWithInput('tools/call', {'name': 'slow'},
            cancellation: caller, timeout: const Duration(seconds: 1)));
          time.elapse(const Duration(seconds: 1));
          expect(result.done, false);
          if (cancel) caller.cancel();
          time.elapse(const Duration(seconds: 1));
          if (cancel) {
            expect(result.error, isA<CancelledException>());
            expect(peer.methods, ['server/discover']);
          } else {
            expect(result.error, isNull);
            expect(result.value, _complete);
            expect(peer.methods, ['server/discover', 'tools/call']);
          }
        } finally { peer.dispose(time); }
      });
    });
  }

  for (final paginated in [false, true]) {
    test('Codex inventory uses one thirty-second catalog deadline across ${paginated ? 'individually timely pages' : 'a stalled page'}', () {
      fakeAsync((time) {
        final peer = _Peer();
        try {
          final manager = peer.manager(time);
          peer.reply = (body) async {
            if (body['method'] != 'resources/list') return _normal(body);
            final page = (body['params']['cursor'] as String?) ?? '0';
            await Future<void>.delayed(Duration(seconds: paginated ? 12 : 31));
            return _Reply(result: {'resources': [{'name': 'memo$page', 'uri': 'memo:$page'}],
              if (paginated) 'nextCursor': '${int.parse(page) + 1}'});
          };
          final result = _Outcome(manager.inventory(peer.lifetime, verbose: true));
          time.elapse(const Duration(seconds: 29));
          expect(result.done, false);
          time.elapse(const Duration(seconds: 1));
          expect(result.error, isNull);
          expect(result.done, true);
          final row = result.value!['servers'][0];
          expect(row['resources'], isEmpty, reason: 'Do not publish a partial catalog.');
          expect(row['resources_error'], 'Unable to load resources');
          expect(row['resource_templates_error'], isNull);
          expect(peer.requests.where((request) => request.body['method'] == 'resources/list'), hasLength(paginated ? 3 : 1));
          expect(manager.status().single['state'], 'ready');
        } finally { peer.dispose(time); }
      });
    });
  }

  test('a recovered continuation retains the newly prepared OAuth credential', () {
    fakeAsync((time) {
      var generation = 0;
      final peer = _Peer(authorization: (_) async => 'grant$generation');
      try {
        peer.reply = (body) => switch (body['method']) {
          'server/discover' => const _Reply(error: {'code': -32601, 'message': 'method not found'}),
          'initialize' => _Reply(result: {'protocolVersion': '2025-06-18', 'capabilities': <String, Object?>{}},
            headers: {'mcp-session-id': 'session$generation'}),
          'tools/call' when generation == 0 => () { generation++; return const _Reply(status: 404); }(),
          'tools/call' when body['params']['inputResponses'] == null => const _Reply(result: {
            'resultType': 'input_required', 'requestState': 'recovered', 'inputRequests': {'confirm': {
              'method': 'elicitation/create', 'params': {'message': 'Continue?', 'requestedSchema': {'type': 'object'}},
            }},
          }),
          _ => _normal(body),
        };
        peer.connect(time);
        final result = _Outcome(peer.connection.requestWithInput('tools/call', {'name': 'slow'},
          cancellation: peer.lifetime, onInput: (_, _, _) async => {'action': 'decline'}));
        time.flushMicrotasks();
        expect(result.error, isNull); expect(result.value, _complete);
        expect(peer.requests.where((request) => request.body['method'] == 'tools/call')
          .map((request) => request.headers.value('Authorization')), ['Bearer grant0', 'Bearer grant1', 'Bearer grant1']);
      } finally { peer.dispose(time); }
    });
  });
}

const Json _complete = {'content': [{'type': 'text', 'text': 'done'}]};
_Reply _normal(Json body) => switch (body['method']) {
  'server/discover' => const _Reply(result: {'supportedVersions': ['2026-07-28'],
    'capabilities': {'tools': <String, Object?>{}, 'resources': <String, Object?>{}}}),
  'initialize' => const _Reply(result: {'protocolVersion': '2025-06-18', 'capabilities': <String, Object?>{}}),
  'notifications/initialized' => const _Reply(status: 202),
  'tools/list' => const _Reply(result: {'tools': [{'name': 'slow', 'inputSchema': {'type': 'object'}}]}),
  'resources/list' => const _Reply(result: {'resources': <Object?>[]}),
  'resources/templates/list' => const _Reply(result: {'resourceTemplates': <Object?>[]}),
  _ => const _Reply(result: _complete),
};

class _Outcome<T> {
  _Outcome(Future<T> future) {
    unawaited(future.then<void>((result) { value = result; done = true; },
      onError: (Object failure) { error = failure; done = true; }));
  }
  T? value;
  Object? error;
  bool done = false;
}

class _Peer implements HttpClient {
  _Peer({Future<String?> Function(CancellationToken)? authorization}) {
    connection = McpConnection({'url': 'http://fixture.test/mcp'}, this, (_) {}, authorization: authorization,
      clientCapabilities: mcpInputCapabilities);
  }
  final lifetime = CancellationToken();
  late final McpConnection connection;
  final requests = <_Request>[];
  FutureOr<_Reply> Function(Json) reply = _normal;
  McpManager? _manager;
  List<Object?> get methods => requests.map((request) => request.body['method'] as Object?).toList();

  void connect(FakeAsync time) {
    final result = _Outcome(connection.connect(lifetime)); time.flushMicrotasks();
    expect(result.error, isNull); expect(result.done, true);
  }
  McpManager manager(FakeAsync time) {
    final manager = _manager = McpManager(http: this, onEvent: (_, _) {});
    final result = _Outcome(manager.configure({'peer': {'url': 'http://fixture.test/mcp'}}, lifetime));
    time.flushMicrotasks(); expect(result.error, isNull); expect(result.done, true);
    return manager;
  }
  void dispose(FakeAsync time) {
    lifetime.cancel(); unawaited(connection.close());
    if (_manager case final manager?) unawaited(manager.close());
    time.flushMicrotasks();
  }
  @override Future<HttpClientRequest> openUrl(String method, Uri uri) async => _Request(this, uri);
  @override void close({bool force = false}) {}
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Reply {
  const _Reply({this.result = const {}, this.error, this.status = 200, this.headers = const {}});
  final Json result;
  final Json? error;
  final int status;
  final Map<String, String> headers;
}

class _Request implements HttpClientRequest {
  _Request(this.peer, this.uri);
  final _Peer peer;
  @override final Uri uri;
  final bytes = <int>[];
  late Json body;
  bool aborted = false;
  @override final headers = _Headers();
  @override bool followRedirects = true;
  @override int contentLength = -1;
  @override void add(List<int> data) => bytes.addAll(data);
  @override Future<HttpClientResponse> close() async {
    body = jsonObject(jsonDecode(utf8.decode(bytes))); peer.requests.add(this);
    return _Response(body, await peer.reply(body));
  }
  @override void abort([Object? exception, StackTrace? stackTrace]) { aborted = true; }
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends StreamView<List<int>> implements HttpClientResponse {
  _Response(Json request, this.reply) : super(_bytes(jsonEncode({'jsonrpc': '2.0', 'id': request['id'],
    if (reply.error != null) 'error': reply.error else 'result': reply.result})));
  final _Reply reply;
  @override int get statusCode => reply.status;
  @override HttpHeaders get headers => _Headers(reply.headers);
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Stream<List<int>> _bytes(String body) {
  final source = StreamController<List<int>>(onCancel: () => Future<void>.value());
  source.add(utf8.encode(body)); unawaited(source.close()); return source.stream;
}

class _Headers implements HttpHeaders {
  _Headers([Map<String, String> values = const {}]) : values = Map.of(values);
  final Map<String, String> values;
  @override void set(String name, Object value, {bool preserveHeaderCase = false}) { values[name.toLowerCase()] = value.toString(); }
  @override List<String>? operator [](String name) {
    final header = value(name); return header == null ? null : [header];
  }
  @override String? value(String name) => values[name.toLowerCase()];
  @override ContentType? contentType = ContentType.json;
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
