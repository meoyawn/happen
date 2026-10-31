import 'dart:async';

import 'package:desktop/file_autocomplete.dart';
import 'package:desktop/mcp_conversation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

void main() {
  testWidgets('the conversation surfaces required MCP auth and completes it inline without changing the draft', (tester) async {
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
      McpConversationAuth(client: client),
      TextField(controller: draft),
    ]))));
    await tester.pumpAndSettle();
    expect(find.text('MCP sign-in required'), findsOneWidget);
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Preparing sign-in…'), findsOneWidget);
    const url = 'https://strengthmcp.com/authorize?state=fixture';
    client.events.add({'type': 'mcp.auth.login', 'server': 'strength', 'login_id': client.loginId, 'url': url});
    await tester.pumpAndSettle();
    expect(opened, [url]);
    expect(find.text('Complete sign-in in your default browser.'), findsOneWidget);
    expect(draft.text, 'my yesterdays workout?');
    client.completion!.complete({'state': 'ready', 'tool_count': 1});
    await tester.pumpAndSettle();
    expect(find.text('MCP sign-in required'), findsNothing);
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
  CancellationToken? loginCancellation;
  CancellableCompleter<Json>? completion;
  bool connected = false;
  @override
  Future<Json> mcpInventory({bool verbose = false, String? server, required CancellationToken cancellation}) async => {
    'servers': [{'name': 'strength', 'enabled': true, 'state': 'authentication_required',
      'auth_status': connected ? 'oauth' : 'not_authenticated', 'oauth_supported': true, 'tool_count': connected ? 1 : 0}],
  };
  @override
  Future<Json> mcpLogin(String server, String id, {required CancellationToken cancellation}) {
    loginId = id;
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
