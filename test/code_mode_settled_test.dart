import 'dart:convert';

import 'package:code_mode/code_mode.dart';
import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

// Adapted from Codex 5112ce6edeb95f2296a5ffec47dbab4764e65853,
// codex-rs/code-mode-runtime/tests/settled.rs. Expectations are upstream values.
void main() {
  late CancellationToken cancellation;
  late CodeSession session;
  setUp(() { cancellation = CancellationToken(); session = CodeSession(cancellation); });
  tearDown(() async { await session.close(); cancellation.cancel(); });

  Future<Json> execute(String source) => session.execute(source, cancellation: cancellation,
    values: const {}, catalog: const [],
    tool: (_, _, {required cancellation}) async => fail('Unexpected host call'));

  final cases = <(String, String, Object)>[
    ('preserves settlement order before and during iteration', r'''
const resolve = [];
const results = as_settled(Array.from({length: 4}, (_, index) =>
    new Promise(done => { resolve[index] = done; })));
resolve[2]("two");
await Promise.resolve();
resolve[0]("zero");
await Promise.resolve();
const seen = [];
for await (const result of results) {
    seen.push(result);
    if (seen.length === 1) {
        resolve[3]("three");
        resolve[1]("one");
        await Promise.resolve();
    }
}
text(seen);
''', [
      {'index': 2, 'status': 'fulfilled', 'value': 'two'},
      {'index': 0, 'status': 'fulfilled', 'value': 'zero'},
      {'index': 3, 'status': 'fulfilled', 'value': 'three'},
      {'index': 1, 'status': 'fulfilled', 'value': 'one'},
    ]),
    ('accepts iterables, values, thenables, and duplicate promises', r'''
const shared = Promise.resolve("shared");
function* inputs() {
    yield 42;
    yield {then(resolve) { resolve("thenable"); }};
    yield shared;
    yield shared;
    yield Promise.reject({message: "failed"});
    yield {get then() { throw "getter failed"; }};
}
const seen = [];
for await (const result of as_settled(inputs())) seen.push(result);
text(seen.sort((a, b) => a.index - b.index));
''', [
      {'index': 0, 'status': 'fulfilled', 'value': 42},
      {'index': 1, 'status': 'fulfilled', 'value': 'thenable'},
      {'index': 2, 'status': 'fulfilled', 'value': 'shared'},
      {'index': 3, 'status': 'fulfilled', 'value': 'shared'},
      {'index': 4, 'status': 'rejected', 'reason': {'message': 'failed'}},
      {'index': 5, 'status': 'rejected', 'reason': 'getter failed'},
    ]),
    ('preserves Map keys and completes empty inputs', r'''
const seen = [];
await stream_settled([], result => seen.push(result));
for await (const result of as_settled(new Map())) seen.push(result);
await stream_settled(new Map([
    ["success", 7],
    ["failure", Promise.reject("failed")],
]), result => seen.push(result));
text(seen);
''', [
      {'index': 'success', 'status': 'fulfilled', 'value': 7},
      {'index': 'failure', 'status': 'rejected', 'reason': 'failed'},
    ]),
    ('awaits each callback including rejected inputs', r'''
const seen = [];
await stream_settled([Promise.reject("failed"), 2], async result => {
    seen.push(result);
    await new Promise(resolve => setTimeout(resolve, 1));
    seen.push(["callback finished", result.index]);
});
seen.push("stream finished");
text(seen);
''', [
      {'index': 0, 'status': 'rejected', 'reason': 'failed'},
      ['callback finished', 0],
      {'index': 1, 'status': 'fulfilled', 'value': 2},
      ['callback finished', 1],
      'stream finished',
    ]),
    ('propagates callback errors and closes early iterations', r'''
const seen = [];
const failure = new Error("callback failed");
try {
    await stream_settled([1, 2], async result => {
        seen.push(result);
        await new Promise(resolve => setTimeout(resolve, 1));
        throw failure;
    });
} catch (error) {
    seen.push(error === failure);
}
const results = as_settled([3, new Promise(() => {}), Promise.reject("unconsumed")]);
for await (const result of results) {
    seen.push(result);
    break;
}
seen.push(await results.next());
text(seen);
''', [
      {'index': 0, 'status': 'fulfilled', 'value': 1},
      true,
      {'index': 0, 'status': 'fulfilled', 'value': 3},
      {'done': true},
    ]),
    ('preserves identity of keys, values, and rejections', r'''
const key = {};
const value = {method() { return 7; }};
value.self = value;
const failure = new Error("failed");
const seen = [];
await stream_settled(new Map([
    [key, Promise.resolve(value)],
    [failure, Promise.reject(failure)],
]), result => {
    seen.push(result.status === "fulfilled"
        ? result.index === key && result.value === value && result.value.self === value
            && result.value.method() === 7
        : result.index === failure && result.reason === failure);
});
text(seen);
''', [true, true]),
  ];
  for (final (name, source, expected) in cases) {
    test('Codex settlement helper $name', () async {
      final result = await execute(source);
      expect(result['error'], isNull);
      expect(result['cell_id'], isNull);
      expect(jsonDecode((result['output'] as List).single as String), expected);
    });
  }

  test('Codex settlement helpers terminate while waiting for unsettled inputs', () async {
    for (final source in [
      'for await (const result of as_settled([new Promise(() => {})])) text(result);',
      'await stream_settled([new Promise(() => {})], text);',
    ]) {
      final running = await execute('// @exec: {"yield_time_ms": 0}\n$source');
      expect(running['error'], isNull);
      expect(running['cell_id'], isA<String>());
      final stopped = await session.wait({'cell_id': running['cell_id'], 'terminate': true},
        cancellation: cancellation);
      expect(stopped['terminated'], isTrue);
      expect(stopped['error'], isNull);
      expect(stopped['output'], isEmpty);
    }
  });
}
