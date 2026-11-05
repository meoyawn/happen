// Applicable Codex 5112ce6edeb9 rmcp-client/tests/mcp_2026_{mrtr,stdio}.rs,
// mcp_2026_mrtr/native_verification_tests.rs, src/{tool_input_tests,
// user_verification_tests,user_verification_dispatch_tests,elicitation_client_service}.rs.
// Real HTTP/SSE and Dart stdio peers. UI callbacks provide answers, not routing,
// continuation state, validation, cancellation or retry behavior under test.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp/mcp.dart';
import 'package:mcp/src/transport.dart';
import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

const opaqueState = ' opaque/☃/=?base64?literal?=\n';
const proof = {'credentialId': 'test-credential', 'signature': 'BAUG'};
Json input(String mode) => switch (mode) {
  'form' || 'url' => {'method': 'elicitation/create', 'params': mode == 'form'
    ? {'mode': 'form', 'message': 'Confirm the MCP request.', 'requestedSchema': {'type': 'object', 'properties': {'confirmed': {'type': 'boolean'}}, 'required': ['confirmed']}, '_meta': {'inputContext': 'server-context'}}
    : {'mode': 'url', 'message': 'Approve the MCP request.', 'url': 'https://example.test/approve', 'elicitationId': 'approval-123', '_meta': {'inputContext': 'server-context'}}},
  'rich' || 'old-rich' => {'method': mode == 'rich' ? 'openai/elicitation/create' : 'openai/form', 'params': {
    if (mode == 'rich') 'mode': 'form', 'message': 'Select a template', 'requestedSchema': {'type': 'object', 'properties': {
      'template': {'type': 'openai/imagePicker', 'items': [{'id': 'monthly-review', 'title': 'Monthly review', 'image': 'data:image/svg+xml;base64,PHN2Zy8+'}]},
    }}, '_meta': {'inputContext': 'server-context'}}},
  _ => {'method': 'openai/elicitation/create', 'params': {'mode': 'openai/userVerification', 'title': 'Verify action',
    'description': 'Verify the requested operation', 'challenge': 'AQID', '_meta': {'example/display': {'label': 'Operation'}}}},
};
Json requiredInput([Json? request]) => {'resultType': 'input_required', 'requestState': opaqueState,
  if (request != null) 'inputRequests': {'confirmation': request}, '_meta': {'responseContext': 'preserved'}};
const complete = {'resultType': 'complete', 'content': [{'type': 'text', 'text': 'done'}]};

void main() {
  late _Peer peer;
  setUp(() async { peer = await _Peer.start(); });
  tearDown(() => peer.close());

  test('raw SSE input_required preserves opaque state and all response metadata', () async {
    final expected = requiredInput(); peer.reply = (_) => _Reply(expected, sse: true);
    final c = McpConnection({'url': peer.url}, peer.http, (_) {}); peer.raw.add(c); await c.connect(peer.lifetime);
    expect(await c.request('tools/call', {'name': 'confirm'}, cancellation: peer.lifetime), expected);
  });

  for (final mode in ['form', 'url', 'rich', 'old-rich', 'native']) {
    for (final sse in [false, true]) {
      test('$mode concurrent MRTR inputs route to each caller and preserve state/meta, SSE=$sse', () async {
        peer.sseDiscovery = sse;
        peer.reply = (body) => _Reply(body['params']['inputResponses'] == null ? requiredInput(input(mode)) : complete, sse: sse);
        final a = await peer.client(), b = await peer.client(); final ids = <String>[];
        await Future.wait([for (final (manager, caller) in [(a, 'first'), (a, 'second'), (b, 'other connection')])
          peer.call(manager, meta: {'requestContext': caller}, onInput: (id, request, token) async {
            ids.add(id); expect(request['method'], input(mode)['method']);
            expect(request['params'], input(mode)['params']);
            return {'action': 'accept', 'content': mode == 'native' ? proof : {'confirmed': true, 'caller': caller}, '_meta': {'clientContext': 'preserved'}};
          }).then((result) => expect(result, complete))]);
        expect(ids.toSet(), hasLength(3)); expect(peer.tools, hasLength(6));
        for (final body in peer.tools.where((b) => b['params']['inputResponses'] != null)) {
          final params = jsonObject(body['params']), response = jsonObject(params['inputResponses']['confirmation']);
          expect(params['requestState'], opaqueState); expect(params['_meta']['requestContext'], isNotNull);
          expect(params['arguments'], {'resource': 'example'});
          if (mode == 'native') expect(response, {'action': 'accept', 'content': proof});
          else expect(response, {'action': 'accept', 'content': {'confirmed': true, 'caller': params['_meta']['requestContext']}, '_meta': {'clientContext': 'preserved'}});
        }
        expect(peer.tools.map((b) => b['id']).toSet(), hasLength(6));
      });
    }
  }

  test('resource reads drive MRTR with fresh request IDs and opaque state', () async {
    peer.reply = (body) => _Reply(body['params']['inputResponses'] == null ? requiredInput(input('form')) : {
      'resultType': 'complete', 'contents': [{'uri': 'memo://requires-confirmation', 'mimeType': 'text/plain', 'text': 'approved resource'}]});
    final manager = await peer.client();
    final result = await manager.resources('resources/read', {'server': 'peer', 'uri': 'memo://requires-confirmation'}, peer.lifetime,
      onInput: (_, request, _) async { expect(request['params']['_meta']['inputContext'], 'server-context'); return {'action': 'accept', 'content': {'confirmed': true}, '_meta': {'clientContext': 'preserved'}}; });
    expect(result['resultType'], 'complete');
    expect(result['contents'].single['text'], 'approved resource');
    final calls = peer.calls.where((b) => b['method'] == 'resources/read').toList();
    expect(calls, hasLength(2)); expect(calls[0]['id'], isNot(calls[1]['id'])); expect(calls[1]['params']['requestState'], opaqueState);
    expect(calls[1]['params']['inputResponses']['confirmation']['_meta'], {'clientContext': 'preserved'});
  });

  test('state-only rounds need no input capability and replace, not normalize, opaque state', () async {
    peer.reply = (body) => _Reply(switch (body['params']['requestState']) {
      null => {...requiredInput(), 'requestState': 'state-1'}, 'state-1' => {...requiredInput(), 'requestState': 'state-2'}, _ => complete,
    });
    expect(await peer.call(await peer.client(caps: {})), complete);
    expect(peer.tools.map((b) => b['params']['requestState']), [null, 'state-1', 'state-2']);
    expect(peer.tools.skip(1).every((b) => b['params']['inputResponses'] == null), true);
  });

  test('legacy session expiry can negotiate modern before inputs, retaining host policy and caller metadata', () async {
    peer.upgrade = true;
    peer.reply = (body) => peer.tools.length == 1 ? const _Reply({}, status: 404)
      : _Reply(body['params']['inputResponses'] == null ? requiredInput(input('form')) : complete);
    final manager = await peer.client();
    expect(await peer.call(manager, readOnly: true, meta: {'requestContext': 'caller-context', 'openai/readOnly': false},
      onInput: (_, _, _) async => {'action': 'accept', 'content': {'confirmed': true}, '_meta': {'clientContext': 'preserved'}}), complete);
    expect(peer.tools, hasLength(3)); expect(peer.initializations, 1); expect(peer.discoveries, 2);
    for (final (index, request) in peer.tools.indexed) {
      expect(request['params']['_meta']['openai/readOnly'], true);
      expect(request['params']['_meta']['requestContext'], 'caller-context');
      expect(request['params']['_meta']['io.modelcontextprotocol/protocolVersion'], index == 0 ? null : '2026-07-28');
    }
    expect(peer.tools.last['params']['requestState'], opaqueState);
  });

  for (final action in ['accept', 'cancel', 'decline']) {
    test('native verification $action strips proof/metadata exactly as Codex requires', () async {
      peer.reply = (body) => _Reply(body['params']['inputResponses'] == null ? {
        ...requiredInput(input('native')), 'inputRequests': {'verification': input('native'), 'confirmation': input('form'), 'richConfirmation': input('rich')},
      } : complete);
      expect(await peer.call(await peer.client(), onInput: (_, request, _) async => {
        'action': request['params']['mode'] == 'openai/userVerification' ? action : 'accept',
        'content': request['params']['mode'] == 'openai/userVerification' ? proof : {'confirmed': true}, '_meta': {'discard': true},
      }), complete);
      final responses = peer.tools.last['params']['inputResponses'];
      expect(responses['verification'], {'action': action, if (action == 'accept') 'content': proof});
      expect(responses['confirmation']['content'], {'confirmed': true}); expect(responses['richConfirmation']['content'], {'confirmed': true});
    });
  }

  for (final (index, content) in <Object?>[null, {}, {'credentialId': 'AQID', 'signature': ''}, {'credentialId': 'AQID', 'signature': 'BAUG='},
    {'credentialId': 'é' * 513, 'signature': 'BAUG'}, {'credentialId': '', 'signature': 'BAUG'},
    {'credentialId': 'AQID', 'signature': base64Url.encode(List.filled(129, 0)).replaceAll('=', '')}, {'credentialId': 'AQID', 'signature': 'BAUG', 'extra': true}].indexed) {
    test('invalid bounded native proof $index becomes cancellation, never proof material', () async {
      peer.reply = (body) => _Reply(body['params']['inputResponses'] == null ? requiredInput(input('native')) : complete);
      expect(await peer.call(await peer.client(), onInput: (_, _, _) async => {'action': 'accept', if (content != null) 'content': content,
        '_meta': {'openai/userVerificationReason': 'userCancelled', 'secret': 'must-not-escape'}}), complete);
      expect(peer.tools.last['params']['inputResponses']['confirmation'], {'action': 'cancel', '_meta': {'openai/userVerificationReason': 'invalidProof'}});
    });
  }
  for (final action in ['cancel', 'decline']) {
    test('native $action retains only a known bounded reason, never supplied proof', () async {
      peer.reply = (body) => _Reply(body['params']['inputResponses'] == null ? requiredInput(input('native')) : complete);
      await peer.call(await peer.client(), onInput: (_, _, _) async => {'action': action, 'content': proof,
        '_meta': {'openai/userVerificationReason': 'timeout', 'secret': 'discarded'}});
      expect(peer.tools.last['params']['inputResponses']['confirmation'], {'action': action, '_meta': {'openai/userVerificationReason': 'timeout'}});
    });
  }

  for (final (index, change) in <Json>[
    {'mode': 'unknown'}, {'title': ''}, {'title': 'x' * 257}, {'description': 'x' * 4097}, {'challenge': ''},
    {'challenge': 'not base64url!'}, {'challenge': base64Url.encode(List.filled(4097, 0)).replaceAll('=', '')}, {'unexpected': 'secret'},
  ].indexed) {
    test('native request rejection vector $index does not prompt or echo untrusted values', () async {
      final malformed = input('native'); malformed['params'] = {...jsonObject(malformed['params']), ...change};
      peer.reply = (_) => _Reply(requiredInput(malformed)); var prompts = 0;
      await expectLater(peer.call(await peer.client(), onInput: (_, _, _) async { prompts++; return {}; }),
        throwsA(isA<McpFailure>().having((e) => e.message, 'redacted failure', isNot(contains('secret')))));
      expect(prompts, 0); expect(peer.tools, hasLength(1));
    });
  }
  for (final (index, meta) in <Object?>[null, {}, {'example/display': {'label': 'Operation', 'details': [1, true, null]}}, true, 7, 'scalar', <Object?>[]].indexed) {
    test('native metadata vector $index follows the standard elicitation object boundary', () async {
      final request = input('native'); request['params'] = {...jsonObject(request['params']), '_meta': meta};
      peer.reply = (body) => _Reply(body['params']['inputResponses'] == null ? requiredInput(request) : complete); var prompts = 0;
      final work = peer.call(await peer.client(), onInput: (_, request, _) async { prompts++; expect(request['params']['_meta'] ?? <String, Object?>{}, meta ?? <String, Object?>{}); return {'action': 'cancel'}; });
      if (meta == null || meta is Map) { expect(await work, complete); expect(prompts, 1); }
      else { await expectLater(work, throwsA(isA<McpFailure>())); expect(prompts, 0); }
    });
  }

  for (final (index, request, caps) in <(int, Json, Json)>[
    (0, input('native'), {'elicitation': {'form': <String, Object?>{}}}),
    (1, input('rich'), {'elicitation': {'form': <String, Object?>{}}, 'extensions': {'openai/elicitation': {'userVerification': <String, Object?>{}}}}),
    (2, {'method': 'arbitrary/custom', 'params': <String, Object?>{}}, mcpInputCapabilities),
  ]) {
    test('unadvertised/unsupported input vector $index rejects the whole round before any prompt', () async {
      peer.reply = (_) => _Reply({...requiredInput(), 'inputRequests': {'a_valid': input('form'), 'z_invalid': request}}); var prompts = 0;
      await expectLater(peer.call(await peer.client(caps: caps), onInput: (_, _, _) async { prompts++; return {}; }), throwsA(isA<McpFailure>()));
      expect(prompts, 0); expect(peer.tools, hasLength(1));
    });
  }
  for (final (index, mode) in <Object?>[null, 0, 'url', 'missing'].indexed) {
    test('unsupported OpenAI mode $index fails as invalid request without prompting', () async {
      final request = input('native'), params = jsonObject(request['params']); if (mode == 'missing') params.remove('mode'); else params['mode'] = mode;
      request['params'] = params;
      peer.reply = (_) => _Reply(requiredInput(request));
      await expectLater(peer.call(await peer.client(), onInput: (_, _, _) async => fail('Unsupported mode must not prompt')),
        throwsA(isA<McpFailure>().having((e) => e.code, 'invalid request', -32600)));
    });
  }

  test('MRTR round budget is ten wire requests, not an unbounded input loop', () async {
    peer.reply = (_) => _Reply(requiredInput(input('native')));
    await expectLater(peer.call(await peer.client(), onInput: (_, _, _) async => {'action': 'accept', 'content': proof}),
      throwsA(isA<McpFailure>().having((e) => e.message, 'bounded continuation', contains('MRTR'))));
    expect(peer.tools, hasLength(10));
  });

  test('modern standard elicitation rejects non-object response metadata before sending a continuation', () async {
    peer.reply = (_) => _Reply(requiredInput(input('form')));
    await expectLater(peer.call(await peer.client(), onInput: (_, _, _) async => {'action': 'accept', '_meta': ['invalid']}),
      throwsA(isA<McpFailure>().having((e) => e.code, 'invalid params', -32602)));
    expect(peer.tools, hasLength(1));
  });

  test('native proof identifiers preserve Unicode and signed bytes without normalization', () async {
    peer.reply = (body) => _Reply(body['params']['inputResponses'] == null ? requiredInput(input('native')) : complete);
    const value = {'credentialId': 'credential:用户/1=', 'signature': 'BAUG'};
    await peer.call(await peer.client(), onInput: (_, request, _) async {
      expect(request['params']['challenge'], 'AQID'); expect(request['params']['title'], 'Verify action');
      expect(request['params']['description'], 'Verify the requested operation');
      return {'action': 'accept', 'content': value, '_meta': {'untrusted': 'discard'}};
    });
    expect(peer.tools.last['params']['inputResponses']['confirmation'], {'action': 'accept', 'content': value});
  });

  for (final action in ['cancel', 'decline']) {
    for (final meta in <Object?>[null, {'openai/userVerificationReason': 'not-a-known-reason', 'secret': 'discard'}]) {
      test('native $action drops absent/unknown reason metadata: $meta', () async {
        peer.reply = (body) => _Reply(body['params']['inputResponses'] == null ? requiredInput(input('native')) : complete);
        await peer.call(await peer.client(), onInput: (_, _, _) async => {'action': action, 'content': proof, if (meta != null) '_meta': meta});
        expect(peer.tools.last['params']['inputResponses']['confirmation'], {'action': action});
      });
    }
  }

  for (final mode in ['form', 'rich', 'native']) {
    for (final action in ['accept', if (mode == 'native') ...['cancel', 'decline']]) {
      test('$mode/$action continuation retains authentication challenge and is not replayed', () async {
        peer.reply = (body) => body['params']['inputResponses'] == null ? _Reply(requiredInput(input(mode)))
          : const _Reply({}, status: 401, headers: {'www-authenticate': 'Bearer error="invalid_token"'});
        final result = await peer.call(await peer.client(), onInput: (_, _, _) async => {'action': action, 'content': mode == 'native' ? proof : {'confirmed': true}});
        expect(result['isError'], true); expect(result['_meta']['mcp/www_authenticate'], ['Bearer error="invalid_token"']); expect(peer.tools, hasLength(2));
      });
    }
  }
  for (final stateOnly in [false, true]) {
    test('answered operation is not restarted after continuation expiry${stateOnly ? ' followed by a state-only round' : ''}', () async {
      peer.reply = (body) => peer.tools.length == 1 ? _Reply(requiredInput(input('native')))
        : stateOnly && peer.tools.length == 2 ? _Reply({...requiredInput(), 'requestState': 'after-proof'}) : const _Reply({}, status: 404);
      await expectLater(peer.call(await peer.client(), onInput: (_, _, _) async => {'action': 'accept', 'content': proof}),
        throwsA(isA<McpFailure>().having((e) => e.message, 'non-replay failure', contains('operation was not restarted'))));
      expect(peer.tools, hasLength(stateOnly ? 3 : 2)); expect(peer.discoveries, 1);
    });
  }

  for (final method in ['tools/call', 'resources/read', 'prompts/get']) {
    for (final failure in ['503', 'dropped response']) {
      for (final stateOnly in [false, true]) {
        test('$method answered continuation forbids $failure replay, state-only=$stateOnly', () async {
          var requests = 0;
          peer.reply = (_) {
            requests++;
            if (requests == 1) return _Reply(requiredInput(input('native')));
            if (stateOnly && requests == 2) return _Reply({...requiredInput(), 'requestState': 'after-proof'});
            return _Reply({}, status: 503, drop: failure == 'dropped response');
          };
          final manager = await peer.client();
          Future<Json> answer(String id, Json request, CancellationToken token) async => {'action': 'accept', 'content': proof};
          final work = method == 'tools/call' ? peer.call(manager, onInput: answer)
            : manager.request('peer', method, method == 'resources/read' ? {'uri': 'memo://confirmed'} : {'name': 'confirmed'}, peer.lifetime, onInput: answer);
          await expectLater(work, throwsA(anyOf(isA<McpFailure>(), isA<HttpException>())));
          final calls = peer.calls.where((c) => c['method'] == method).toList();
          expect(calls, hasLength(stateOnly ? 3 : 2), reason: 'Neither read-only annotations nor safe-read defaults authorize replay after an answer.');
          expect(calls.last['params']['requestState'], stateOnly ? 'after-proof' : opaqueState);
          expect(peer.discoveries, 1);
        });
      }
    }
  }

  test('shared calls isolate pending inputs, caller cancellation, active timeouts and surviving replies', () async {
    peer.reply = (body) => body['params']['name'] == 'slow' ? const _Reply(complete, delay: Duration(milliseconds: 350))
      : _Reply(body['params']['inputResponses'] == null ? requiredInput(input('native')) : complete);
    final manager = await peer.client(), first = CancellationToken(), inputs = StreamController<(String, CancellationToken, Completer<Json>)>();
    final inputEvents = StreamIterator(inputs.stream); addTearDown(() async { await inputEvents.cancel(); await inputs.close(); });
    Future<Json> sender(String id, Json request, CancellationToken token) { final answer = Completer<Json>(); inputs.add((id, token, answer)); return answer.future.asCancellable(token); }
    final a = peer.call(manager, onInput: sender, cancellation: first); unawaited(a.then<void>((_) {}, onError: (Object _) {}));
    final one = await peer.next(inputEvents, a);
    final b = peer.call(manager, onInput: sender); unawaited(b.then<void>((_) {}, onError: (Object _) {}));
    final two = await peer.next(inputEvents, b); expect(one.$1, isNot(two.$1));
    await expectLater(peer.call(manager, name: 'slow', onInput: (_, _, _) async => fail('Slow call must not prompt'), timeout: const Duration(milliseconds: 80)), throwsA(isA<TimeoutException>()));
    first.cancel(); await expectLater(a, throwsA(isA<CancelledException>())); expect(one.$2.isCancelled, true); expect(two.$2.isCancelled, false);
    two.$3.complete({'action': 'cancel'}); expect(await b, complete);
  });

  test('human input pauses only its call clock; later wire rounds share the remaining active budget', () async {
    peer.reply = (body) => _Reply(body['params']['inputResponses'] == null ? requiredInput(input('form')) : complete, delay: const Duration(milliseconds: 60));
    final manager = await peer.client(); var prompts = 0;
    await expectLater(peer.call(manager, timeout: const Duration(milliseconds: 100), onInput: (_, _, token) async {
      prompts++; await cancellableDelay(const Duration(milliseconds: 180), token); return {'action': 'accept', 'content': {'confirmed': true}};
    }), throwsA(isA<TimeoutException>()));
    expect(prompts, 1); expect(peer.tools, hasLength(2));
  });

  test('an input wait exceeding the active timeout can still complete with active budget remaining', () async {
    peer.reply = (body) => _Reply(body['params']['inputResponses'] == null ? requiredInput(input('form')) : complete);
    expect(await peer.call(await peer.client(), timeout: const Duration(milliseconds: 100), onInput: (_, _, token) async {
      await cancellableDelay(const Duration(milliseconds: 180), token); return {'action': 'accept', 'content': {'confirmed': true}};
    }), complete);
  });

  for (final mode in ['form', 'native']) {
    for (final disposal in ['close', 'transport EOF']) {
      test('$mode pending input is released on $disposal without waiting for a user reply', () async {
        final root = await Directory.systemTemp.createTemp('mrtr-close-'); addTearDown(() => root.delete(recursive: true));
        final connection = McpConnection({'command': Platform.resolvedExecutable, 'args': [File('test/fixtures/mcp_continuation_stdio.dart').absolute.path,
          'modern', '${root.path}/wire', mode]}, peer.http, (_) {}, clientCapabilities: mcpInputCapabilities); peer.raw.add(connection);
        await connection.connect(peer.lifetime);
        final entered = Completer<CancellationToken>();
        final work = connection.request('tools/call', {'name': 'confirm'}, cancellation: peer.lifetime, onInput: (_, _, token) {
          entered.complete(token); return Completer<Json>().future.asCancellable(token);
        }); unawaited(work.then<void>((_) {}, onError: (Object _) {}));
        final token = await Future.any([entered.future, work.then<CancellationToken>((_) => throw TestFailure('Call completed before input'))]);
        if (disposal == 'close') await connection.close(); else Process.killPid(connection.processId!, ProcessSignal.sigkill);
        await expectLater(work, throwsA(isA<McpFailure>())); expect(token.isCancelled, true);
      });
    }
  }

  for (final mode in ['modern', 'legacy', 'legacy-native-meta', 'legacy-early', 'legacy-early-saturated', 'legacy-early-huge', 'legacy-early-duplicates']) {
    test('real stdio input contract: $mode', () async {
      final root = await Directory.systemTemp.createTemp('mrtr-stdio-'); addTearDown(() => root.delete(recursive: true));
      final manager = await peer.client(stdio: {'command': Platform.resolvedExecutable, 'args': [File('test/fixtures/mcp_continuation_stdio.dart').absolute.path, mode, '${root.path}/wire']});
      var prompts = 0;
      final result = await peer.call(manager, onInput: (_, request, _) async {
        prompts++;
        if (mode == 'legacy-native-meta') { expect(request['params']['_meta'], {'example/display': {'label': 'Operation'}}); return {'action': 'cancel'}; }
        if (mode == 'legacy') {
          final properties = request['params']['requestedSchema']['properties'];
          expect(properties, {'name': {'type': 'string', 'default': 'John Doe'}, 'age': {'type': 'integer', 'default': 30},
            'score': {'type': 'number', 'default': 95.5}, 'status': {'type': 'string', 'enum': ['active', 'inactive'], 'default': 'active'},
            'verified': {'type': 'boolean', 'default': true}});
          return {'action': 'accept', 'content': {'name': 'John Doe', 'age': 30, 'score': 95.5, 'status': 'active', 'verified': true}, '_meta': {'persist': 'always'}};
        }
        if (mode.startsWith('legacy-early')) fail('Early cancelled inputs must not prompt');
        return {'action': 'accept', 'content': {'approved': true}};
      });
      expect(prompts, mode.startsWith('legacy-early') ? 0 : 1);
      if (mode.startsWith('legacy-early')) {
        expect(result['structuredContent']['result'], {'action': 'cancel', '_meta': {'openai/userVerificationReason': mode.endsWith('saturated') || mode.endsWith('huge') ? 'approvalUnavailable' : 'interrupted'}});
      } else if (mode == 'modern') {
        expect(result['structuredContent']['requestState'], 'stdio opaque/☃\n'); expect(result['structuredContent']['inputResponses']['approval']['content'], {'approved': true});
      } else if (mode == 'legacy') expect(result['structuredContent']['result']['_meta'], {'persist': 'always'});
      expect((await manager.request('peer', 'ping', {}, peer.lifetime)), isEmpty, reason: 'Cancellation saturation must not poison ordinary requests.');
    });
  }

  for (final params in <Json>[{}, {'mode': 7}, {'mode': 'unknown'}]) {
    test('legacy native dispatch rejects malformed mode $params without a prompt', () async {
      final root = await Directory.systemTemp.createTemp('mrtr-legacy-invalid-'); addTearDown(() => root.delete(recursive: true));
      final manager = await peer.client(stdio: {'command': Platform.resolvedExecutable, 'args': [File('test/fixtures/mcp_continuation_stdio.dart').absolute.path,
        'legacy-native-invalid', '${root.path}/wire', jsonEncode(params)]});
      final result = await peer.call(manager, onInput: (_, _, _) async => fail('Malformed legacy mode must not prompt'));
      expect(result['structuredContent']['error']['code'], -32602);
    });
  }

  test('shared modern stdio aliases keep continuation input/state with the original caller', () async {
    final root = await Directory.systemTemp.createTemp('mrtr-stdio-shared-'); addTearDown(() => root.delete(recursive: true));
    final spec = {'command': Platform.resolvedExecutable, 'args': [File('test/fixtures/mcp_continuation_stdio.dart').absolute.path, 'modern', '${root.path}/wire']};
    final manager = McpManager(http: peer.http, onEvent: (_, _) {}, clientCapabilities: mcpInputCapabilities); peer.managers.add(manager);
    await manager.configure({'peer': spec, 'alias': spec}, peer.lifetime);
    expect(manager.status().map((s) => s['pid']).toSet(), hasLength(1));
    await Future.wait([for (final caller in ['peer', 'alias']) manager.callTool('mcp__${caller}__confirm', {'caller': caller}, peer.lifetime,
      meta: {'caller': caller}, onInput: (_, _, _) async => {'action': 'accept', 'content': {'approved': true, 'caller': caller}}).then((result) {
        expect(result['structuredContent']['_meta']['caller'], caller);
        expect(result['structuredContent']['arguments'], {'caller': caller});
        expect(result['structuredContent']['inputResponses']['approval']['content']['caller'], caller);
      })]);
  });

  test('a duplicate reverse-request ID cannot erase the first pending input cancellation', () async {
    final root = await Directory.systemTemp.createTemp('mrtr-duplicate-input-'); addTearDown(() => root.delete(recursive: true));
    final manager = await peer.client(stdio: {'command': Platform.resolvedExecutable, 'args': [File('test/fixtures/mcp_continuation_stdio.dart').absolute.path,
      'legacy-native-duplicate', '${root.path}/wire']});
    var prompts = 0;
    final result = await peer.call(manager, onInput: (_, _, token) { prompts++; return Completer<Json>().future.asCancellable(token); });
    expect(prompts, 1);
    expect(result['structuredContent']['result'], {'action': 'cancel', '_meta': {'openai/userVerificationReason': 'interrupted'}});
    final responses = File('${root.path}/wire').readAsLinesSync().map((line) => jsonObject(jsonDecode(line)))
      .where((message) => message['id'] == 0 && !message.containsKey('method')).toList();
    expect(responses, hasLength(2)); expect(responses.first['error']['code'], -32600); expect(responses.last['result']['action'], 'cancel');
  });
}

class _Reply {
  const _Reply(this.result, {this.status = 200, this.sse = false, this.drop = false, this.headers = const {}, this.delay = Duration.zero});
  final Json result;
  final int status;
  final bool sse, drop;
  final Map<String, String> headers;
  final Duration delay;
}

class _Peer {
  _Peer(this.server) {
    server.listen((request) async {
      try { await serve(request); } on IOException { /* A controlled caller closed this socket. */ }
      on CancelledException { if (!lifetime.isCancelled) rethrow; }
      on TimeoutException { if (!lifetime.isCancelled) rethrow; }
    });
  }
  final HttpServer server;
  final http = HttpClient();
  final lifetime = TimeoutCancellationToken(const Duration(seconds: 20));
  final managers = <McpManager>[], raw = <McpConnection>[], calls = <Json>[];
  _Reply Function(Json) reply = (_) => const _Reply(complete);
  bool sseDiscovery = false, upgrade = false;
  int discoveries = 0, initializations = 0;
  String get url => 'http://127.0.0.1:${server.port}/mcp';
  List<Json> get tools => calls.where((b) => b['method'] == 'tools/call').toList();
  static Future<_Peer> start() async => _Peer(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
  Future<McpManager> client({Json caps = mcpInputCapabilities, Json? stdio}) async {
    final manager = McpManager(http: http, onEvent: (_, _) {}, clientCapabilities: caps); managers.add(manager);
    await manager.configure({'peer': stdio ?? {'url': url, 'oauth': false}}, lifetime); return manager;
  }
  Future<Json> call(McpManager manager, {String name = 'confirm', McpInputHandler? onInput, Json? meta, bool readOnly = false,
      CancellationToken? cancellation, Duration? timeout = const Duration(seconds: 5)}) => manager.callTool('mcp__peer__$name', {'resource': 'example'},
        cancellation ?? lifetime, onInput: onInput, meta: meta, timeout: timeout, readOnly: readOnly);
  Future<(String, CancellationToken, Completer<Json>)> next(StreamIterator<(String, CancellationToken, Completer<Json>)> input, Future<Json> work) async {
    final advanced = await Future.any([input.moveNext(), work.then<bool>((_) => throw TestFailure('Call completed before requesting input'))]);
    if (!advanced) throw TestFailure('Input channel closed'); return input.current;
  }
  Future<void> serve(HttpRequest request) async {
    final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join())); calls.add(body);
    _Reply response;
    switch (body['method']) {
      case 'server/discover':
        discoveries++;
        if (upgrade && initializations == 0) {
          request.response.headers.contentType = ContentType.json; request.response.write(jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'error': {'code': -32601, 'message': 'Method not found'}}));
          await request.response.close(); return;
        }
        response = _Reply({'supportedVersions': ['2026-07-28'], 'capabilities': {'tools': <String, Object?>{}, 'resources': <String, Object?>{}},
          '_meta': {'io.modelcontextprotocol/serverInfo': {'name': 'input-peer', 'version': '1'}}}, sse: sseDiscovery);
      case 'initialize':
        initializations++; request.response.headers.set('mcp-session-id', 'legacy-session');
        response = const _Reply({'protocolVersion': '2025-06-18', 'serverInfo': {'name': 'input-peer', 'version': '1'}, 'capabilities': {'tools': <String, Object?>{}}});
      case 'notifications/initialized': request.response.statusCode = 202; await request.response.close(); return;
      case 'tools/list': response = _Reply({'tools': [for (final name in ['confirm', 'slow']) {'name': name, 'inputSchema': {'type': 'object'}, 'annotations': {'readOnlyHint': true}}]});
      case 'ping': response = const _Reply({});
      default: response = reply(body);
    }
    if (response.delay != Duration.zero) await cancellableDelay(response.delay, lifetime);
    if (response.drop) { (await request.response.detachSocket(writeHeaders: false)).destroy(); return; }
    request.response.statusCode = response.status; response.headers.forEach(request.response.headers.set);
    final message = {'jsonrpc': '2.0', 'id': body['id'], 'result': response.result};
    request.response.headers.contentType = response.sse ? ContentType('text', 'event-stream', charset: 'utf-8') : ContentType.json;
    request.response.write(response.sse ? 'event: message\ndata: ${jsonEncode(message)}\n\n' : jsonEncode(message)); await request.response.close();
  }
  Future<void> close() async {
    lifetime.cancel(); await Future.wait(managers.map((m) => m.close())); await Future.wait(raw.map((c) => c.close()));
    http.close(force: true); await server.close(force: true);
  }
}
