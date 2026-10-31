import 'dart:async';

import 'package:desktop/file_autocomplete.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

void main() {
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
  @override
  Future<Json> mcpInventory({bool verbose = false, String? server, required CancellationToken cancellation}) async => {
    'servers': [{'name': 'strength', 'enabled': true, 'state': 'authentication_required',
      'auth_status': 'not_authenticated', 'oauth_supported': true, 'tool_count': 0}],
  };
  @override
  Future<Json> mcpLogin(String server, String id, {required CancellationToken cancellation}) {
    loginId = id;
    loginCancellation = cancellation;
    return (completion = CancellableCompleter<Json>(cancellation)).future;
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected client operation: ${invocation.memberName}');
}
