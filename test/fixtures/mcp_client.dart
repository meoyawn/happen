import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp/src/transport.dart';
import 'package:protocol/protocol.dart';

// A real client process gives inheritance tests their own immutable Dart
// environment and cwd. It speaks to the independent peer over actual pipes.
Future<void> main(List<String> arguments) async {
  final http = HttpClient();
  final token = TimeoutCancellationToken(const Duration(seconds: 15));
  final connection = McpConnection(jsonObject(jsonDecode(arguments[0])), http, (_) {});
  try {
    await connection.connect(token);
    final results = <Json>[];
    for (final operation in jsonDecode(arguments[1]) as List) {
      try {
        results.add(await connection.request(operation['method'] as String,
          jsonObject(operation['params']), cancellation: token));
      } on McpFailure catch (error) {
        results.add({'error': {'code': error.code, 'message': error.message, 'data': error.data}});
      }
    }
    stdout.writeln(jsonEncode({'discovery': connection.discovery, 'results': results}));
  } finally { token.cancel(); await connection.close(); http.close(force: true); }
}
