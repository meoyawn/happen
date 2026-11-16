import 'dart:async';

import 'package:protocol/protocol.dart';
import 'package:server/src/client_tools.dart';
import 'package:test/test.dart';

// Codex app-server/tests/suite/v2/dynamic_tools.rs:
// dynamic_tool_call_round_trip_handles_content_items and remote media rejection.
void main() {
  test('client tool responses preserve inline content and turn malformed output into tool failures', () async {
    final bridge = ClientToolBridge(), outgoing = StreamController<Json>.broadcast();
    final cancellation = CancellationToken();
    addTearDown(() async { cancellation.cancel(); bridge.close(); await outgoing.close(); });
    bridge.register('thread', 'desktop', [{
      'name': 'capture', 'description': 'Capture a page',
      'inputSchema': {'type': 'object', 'properties': <String, Object>{}},
    }], outgoing.add);
    const inline = [
      {'type': 'inputText', 'text': 'caption'},
      {'type': 'inputImage', 'imageUrl': 'data:image/png;base64,AQID'},
      {'type': 'inputAudio', 'audioUrl': 'data:audio/wav;base64,AQID'},
    ];
    for (final (result, failure) in <(Json, String?)>[
      ({'success': true, 'contentItems': inline}, null),
      ({'success': false, 'contentItems': [inline.first]}, null),
      ({'success': true, 'contentItems': [{'type': 'inputImage', 'imageUrl': 'https://example.com/page.png'}]}, 'inline data URL'),
      ({'success': true, 'contentItems': [{'type': 'inputAudio', 'audioUrl': 'https://example.com/page.wav'}]}, 'inline data URL'),
      ({'success': true, 'contentItems': [{'type': 'inputText', 'text': 1}]}, 'invalid'),
      ({'contentItems': inline}, 'invalid'),
    ]) {
      final incoming = outgoing.stream.first;
      final pending = callIsolate(bridge.port, 'call', {'task_id': 'thread', 'name': 'capture', 'arguments': <String, Object>{}},
        cancellation: cancellation);
      final request = await incoming;
      bridge.complete('desktop', {'id': request['id'], 'result': result});
      final response = jsonObject(await pending);
      if (failure == null) { expect(response, result); }
      else {
        expect(response['success'], false);
        expect(response['contentItems'], [{'type': 'inputText', 'text': contains(failure)}]);
      }
    }
  });
}
