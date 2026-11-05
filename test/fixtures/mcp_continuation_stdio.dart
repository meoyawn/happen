import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';

// Independent real child for modern continuations and legacy reverse requests.
// The parent supplies user answers; this peer never implements client routing.
Future<void> main(List<String> args) async {
  final mode = args[0], journal = File(args[1]);
  final legacy = mode.startsWith('legacy');
  Timer(const Duration(seconds: 30), () => exit(0));
  Json? pending;
  void send(Json message) => stdout.writeln(jsonEncode({'jsonrpc': '2.0', ...message}));
  void result(Object? id, Json value) => send({'id': id, 'result': value});
  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    final request = jsonObject(jsonDecode(line));
    journal.writeAsStringSync('$line\n', mode: FileMode.append);
    if (!request.containsKey('method')) {
      if (mode == 'legacy-native-duplicate' && request['error'] != null) {
        send({'method': 'notifications/cancelled', 'params': {'requestId': 0}}); return;
      }
      result(pending!['id'], {'content': [{'type': 'text', 'text': 'legacy completed'}], 'structuredContent': request});
      return;
    }
    final params = jsonObject(request['params'] ?? {});
    switch (request['method']) {
      case 'server/discover':
        if (legacy) send({'id': request['id'], 'error': {'code': -32601, 'message': 'Method not found'}});
        else result(request['id'], {'supportedVersions': ['2026-07-28'], '_meta': {
          'io.modelcontextprotocol/serverInfo': {'name': 'input-peer', 'version': '1'}}, 'capabilities': {'tools': <String, Object?>{}}});
      case 'initialize': result(request['id'], {'protocolVersion': '2025-06-18', 'serverInfo': {'name': 'input-peer', 'version': '1'}, 'capabilities': {'tools': <String, Object?>{}}});
      case 'notifications/initialized': break;
      case 'tools/list': result(request['id'], {'tools': [{'name': 'confirm', 'inputSchema': {'type': 'object'}}]});
      case 'tools/call':
        if (mode.startsWith('legacy-early')) {
          final count = mode == 'legacy-early-saturated' || mode == 'legacy-early-duplicates' ? 1025 : 1;
          for (var i = 0; i < count; i++) { send({'method': 'notifications/cancelled', 'params': {
            'requestId': mode == 'legacy-early-huge' ? 'x' * 1025 : mode == 'legacy-early-duplicates' ? 0 : i,
          }}); }
        }
        if (legacy) {
          pending = request;
          final native = mode.startsWith('legacy-early') || mode.startsWith('legacy-native');
          send({'id': native ? mode == 'legacy-early-saturated' || mode == 'legacy-early-huge' ? 5000 : 0 : 'approval',
            'method': native ? 'openai/elicitation/create' : 'elicitation/create',
            'params': mode == 'legacy-native-invalid' ? jsonObject(jsonDecode(args[2])) : native ? {'mode': 'openai/userVerification', 'title': 'Approve', 'description': 'Review operation', 'challenge': 'AQID',
              '_meta': {'progressToken': 7, 'example/display': {'label': 'Operation'}}} : {
              'message': 'Confirm the defaults', 'requestedSchema': {'type': 'object', 'properties': {
                'name': {'type': 'string', 'default': 'John Doe'}, 'age': {'type': 'integer', 'default': 30},
                'score': {'type': 'number', 'default': 95.5}, 'status': {'type': 'string', 'enum': ['active', 'inactive'], 'default': 'active'},
                'verified': {'type': 'boolean', 'default': true},
              }, 'required': <String>[]}},
          });
          if (mode == 'legacy-native-duplicate') send({'id': 0, 'method': 'openai/elicitation/create',
            'params': {'mode': 'openai/userVerification', 'title': 'Approve', 'description': '', 'challenge': 'AQID'}});
        } else if (params['inputResponses'] == null) {
          final native = args.length > 2 && args[2] == 'native';
          result(request['id'], {'resultType': 'input_required', 'requestState': 'stdio opaque/☃\n', 'inputRequests': {'approval': {
            'method': native ? 'openai/elicitation/create' : 'elicitation/create', 'params': native
              ? {'mode': 'openai/userVerification', 'title': 'Approve', 'description': '', 'challenge': 'AQID'}
              : {'mode': 'form', 'message': 'Approve?', 'requestedSchema': {'type': 'object', 'properties': {'approved': {'type': 'boolean'}}}},
          }}});
        } else result(request['id'], {'resultType': 'complete', 'content': [{'type': 'text', 'text': 'modern completed'}], 'structuredContent': params});
      case 'ping': result(request['id'], {});
      case 'notifications/cancelled': break;
    }
  }, onDone: () => exit(0));
}
