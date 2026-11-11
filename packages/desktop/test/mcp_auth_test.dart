import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop/file_autocomplete.dart';
import 'package:desktop/mcp_conversation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

void main() {
  testWidgets('/mcp shows the current project servers and switches inventory with the composer', (tester) async {
    Directory? root;
    HttpServer? upstream;
    AgentServer? server;
    AgentClient? client;
    final controller = TextEditingController(), focus = FocusNode();
    try {
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('mcp-project-menu-');
        upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        upstream!.listen((request) async {
          final body = jsonObject(jsonDecode(await utf8.decoder.bind(request).join()));
          final result = switch (body['method']) {
            'server/discover' => {'supportedVersions': ['2026-07-28'], 'capabilities': {
              'tools': <String, Object?>{}, 'resources': <String, Object?>{},
            }},
            'tools/list' => {'tools': [{'name': 'project_probe', 'inputSchema': {'type': 'object'}}]},
            'resources/list' => {'resources': <Object?>[]},
            'resources/templates/list' => {'resourceTemplates': <Object?>[]},
            _ => throw StateError('Unexpected MCP method ${body['method']}'),
          };
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': result}));
          await request.response.close();
        });
        await File('${root!.path}/config.yaml').writeAsString('{}');
        for (final (project, name) in [('first', 'github_events'), ('second', 'other_events')]) {
          await Directory('${root!.path}/$project/.git').create(recursive: true);
          final config = File('${root!.path}/$project/.happen/config.yaml');
          await config.parent.create();
          await config.writeAsString(jsonEncode({'mcp_servers': {
            name: {'url': 'http://127.0.0.1:${upstream!.port}/mcp', 'oauth': false, 'legacy_fallback': false},
          }}));
        }
        server = await AgentServer.startLocal(directory: '${root!.path}/data',
          configPath: '${root!.path}/config.yaml', skillsHome: root!.path);
        client = AgentClient.local(server!);
      });
      Future<void> show(String project, String command) async {
        await tester.pumpWidget(MaterialApp(home: Scaffold(body: Align(alignment: Alignment.bottomCenter,
          child: ComposerAutocomplete(controller: controller, focusNode: focus, client: client!,
            cwd: '${root!.path}/$project', enabled: true, child: TextField(controller: controller, focusNode: focus)),
        ))));
        await tester.enterText(find.byType(TextField), command);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        for (var attempt = 0; attempt < 300 && find.textContaining('Loading MCP ').evaluate().isNotEmpty; attempt++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump();
        }
        expect(find.textContaining('Loading MCP '), findsNothing);
      }
      await show('first', '/mcp');
      expect(find.text('github_events'), findsOneWidget);
      expect(find.text('other_events'), findsNothing);
      expect(controller.text, isEmpty);
      await show('second', '/mcp verbose');
      expect(find.text('other_events'), findsOneWidget);
      expect(find.text('github_events'), findsNothing);
      expect(find.text('Tools: project_probe'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await client?.close(); await server?.close(); await upstream?.close(force: true);
        await root?.delete(recursive: true);
      });
      controller.dispose(); focus.dispose();
    }
  });

  testWidgets('the conversation keeps MCP auth optional and completes it inline without changing the draft', (tester) async {
    final client = _Client();
    final draft = TextEditingController(text: 'my yesterdays workout?');
    final opened = <String>[];
    const channel = MethodChannel('happen/desktop');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'openMcpLoginUrl') { opened.add(call.arguments as String); return true; }
      return null;
    });
    addTearDown(() async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      draft.dispose();
      await client.events.close();
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Column(children: [
      const Expanded(child: Text('Existing conversation')),
      McpConversationAuth(client: client, cwd: '/project'),
      TextField(controller: draft),
    ]))));
    await tester.pumpAndSettle();
    expect(find.text('Sign in'), findsNothing);
    final connections = find.text('MCP connections · 1 awaiting sign-in');
    expect(connections, findsOneWidget);
    await tester.tap(connections);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(client.loginCwd, '/project');
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Preparing sign-in…'), findsOneWidget);
    await tester.tap(connections);
    await tester.pumpAndSettle();
    expect(find.text('Preparing sign-in…'), findsNothing);
    expect(client.loginCancellation!.isCancelled, false);
    await tester.tap(connections);
    await tester.pumpAndSettle();
    expect(find.text('Preparing sign-in…'), findsOneWidget);
    const url = 'https://strengthmcp.com/authorize?state=fixture';
    client.events.add({'type': 'mcp.auth.login', 'server': 'strength', 'login_id': client.loginId, 'url': url});
    await tester.pumpAndSettle();
    expect(opened, [url]);
    expect(find.text('Complete sign-in in your default browser.'), findsOneWidget);
    expect(draft.text, 'my yesterdays workout?');
    await tester.tap(find.byTooltip('Dismiss MCP sign-in requests'));
    await tester.pumpAndSettle();
    expect(connections, findsNothing);
    expect(client.loginCancellation!.isCancelled, false);
    client.events.add({'type': 'mcp.auth.changed', 'server': 'strength'});
    await tester.pumpAndSettle();
    expect(connections, findsNothing);
    client.completion!.complete({'state': 'ready', 'tool_count': 1});
    await tester.pumpAndSettle();
    expect(client.connected, true);
    expect(connections, findsNothing);
    expect(draft.text, 'my yesterdays workout?');
    expect(find.text('Existing conversation'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('/mcp opens the native default browser for its own login and preserves the composer', (tester) async {
    final client = _Client();
    final controller = TextEditingController();
    final focus = FocusNode();
    final opened = <String>[], activated = <String>[];
    const channel = MethodChannel('happen/desktop');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'openMcpLoginUrl') { opened.add(call.arguments as String); return true; }
      if (call.method == 'activate') activated.add(call.method);
      return null;
    });
    addTearDown(() async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      controller.dispose();
      focus.dispose();
      await client.events.close();
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Align(alignment: Alignment.bottomCenter, child: ComposerAutocomplete(
      controller: controller, focusNode: focus, client: client, cwd: '/project', enabled: true,
      child: TextField(controller: controller, focusNode: focus),
    )))));
    await tester.enterText(find.byType(TextField), '/mcp');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Not authenticated'), findsOneWidget);
    expect(controller.text, isEmpty);
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Preparing sign-in…'), findsOneWidget);
    client.events.add({'type': 'mcp.auth.login', 'server': 'other', 'login_id': client.loginId, 'url': 'https://unrelated.example/authorize'});
    await tester.pump();
    expect(opened, isEmpty);
    const authorization = 'https://strengthmcp.com/authorize?state=fixture';
    client.events.add({'type': 'mcp.auth.login', 'server': 'strength', 'login_id': client.loginId, 'url': authorization});
    await tester.pumpAndSettle();
    expect(opened, [authorization]);
    expect(find.text('Complete sign-in in your default browser.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(client.loginCancellation!.isCancelled, true);
    expect(find.byType(AlertDialog), findsNothing);
    expect(controller.text, isEmpty);
    focus.requestFocus();
    await tester.enterText(find.byType(TextField), '/mcp');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    client.completion!.complete({'state': 'ready', 'tool_count': 1});
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(activated, ['activate']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _Client implements AgentClient {
  @override
  final events = StreamController<Json>.broadcast();
  String? loginId;
  String? loginCwd;
  CancellationToken? loginCancellation;
  CancellableCompleter<Json>? completion;
  bool connected = false;
  @override
  Future<Json> mcpInventory({bool verbose = false, String? server, String? cwd, required CancellationToken cancellation}) async => {
    'servers': [{'name': 'strength', 'enabled': true, 'state': 'authentication_required',
      'auth_status': connected ? 'oauth' : 'not_authenticated', 'oauth_supported': true, 'tool_count': connected ? 1 : 0}],
  };
  @override
  Future<Json> mcpLogin(String server, String id, {String? cwd, required CancellationToken cancellation}) {
    loginId = id;
    loginCwd = cwd;
    loginCancellation = cancellation;
    return (completion = CancellableCompleter<Json>(cancellation)).future.then((result) {
      connected = true;
      events.add({'type': 'mcp.auth.changed', 'server': server});
      return result;
    });
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected client operation: ${invocation.memberName}');
}
