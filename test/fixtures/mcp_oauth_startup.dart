import 'dart:convert';
import 'dart:io';

import 'package:mcp/mcp.dart';
import 'package:protocol/protocol.dart';

Future<void> main(List<String> arguments) async {
  final http = HttpClient();
  final token = TimeoutCancellationToken(const Duration(seconds: 15));
  final manager = McpManager(http: http, directory: arguments[0], onEvent: (_, _) {});
  try {
    await manager.configure({'test': jsonObject(jsonDecode(arguments[1]))}, token);
    while (!['ready', 'failed'].contains(manager.status().single['state'])) {
      await cancellableDelay(const Duration(milliseconds: 10), token);
    }
    stdout.writeln(jsonEncode((await manager.inventory(token))['servers'][0]));
  } finally { token.cancel(); await manager.close(); http.close(force: true); }
}
