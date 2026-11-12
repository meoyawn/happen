import 'dart:convert';
import 'dart:io';

import 'package:mcp/mcp.dart';
import 'package:protocol/protocol.dart';
import 'package:server/src/mcp_executables.dart';
import 'package:tool_runtime/tool_runtime.dart';

// A GUI-style process has its own immutable, system-only inherited PATH.
// Exercise login capture, executable tracking and the real MCP owner together.
Future<void> main(List<String> arguments) async {
  final token = TimeoutCancellationToken(const Duration(seconds: 60));
  final http = HttpClient();
  final hostPath = await loginShellPath(Directory.current.path, token);
  final manager = McpManager(http: http, hostPath: hostPath, onEvent: (_, _) {});
  try {
    final servers = jsonObject(jsonDecode(arguments[0]));
    final executables = await readMcpExecutables(servers, token, hostPath: hostPath);
    await manager.configure(servers, token, executableRevisions: {
      for (final entry in executables.entries) entry.key: entry.value.revision,
    });
    final inventory = await manager.inventory(token, verbose: true);
    stdout.writeln(jsonEncode({
      'inventory': inventory,
      'revision': executables['probe']?.revision,
      'host_path': hostPath,
      'explicit_path': mcpEnvironment({'env': {'PATH': '/usr/bin:/bin'}}, hostPath: hostPath)['PATH'],
    }));
  } finally {
    token.cancel();
    await manager.close();
    http.close(force: true);
  }
}
