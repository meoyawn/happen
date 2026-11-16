import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop/browser_ports.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';

void main() {
  testWidgets('empty browser lists live web listeners, opens a selection, and removes stopped servers', (tester) async {
    late Process process;
    late Directory root;
    late StreamIterator<String> lines;
    late Json ports;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('browser-ports-');
      final config = await File('${root.path}/packages.json').writeAsString('{"configVersion":2,"packages":[]}');
      process = await Process.start('dart', ['--packages=${config.path}',
        File('test/fixtures/browser_servers.dart').absolute.path], workingDirectory: root.path);
      unawaited(process.stderr.drain<void>());
      lines = StreamIterator(process.stdout.transform(utf8.decoder).transform(const LineSplitter()));
      expect(await lines.moveNext().timeout(const Duration(seconds: 10)), true);
      ports = jsonObject(jsonDecode(lines.current));
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await process.stdin.close();
        try { await process.exitCode.timeout(const Duration(seconds: 5)); }
        on TimeoutException { process.kill(ProcessSignal.sigkill); await process.exitCode; }
        await lines.cancel();
        await root.delete(recursive: true);
      });
    });
    Uri? opened;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: BrowserPorts(active: true, onOpen: (uri) => opened = uri))));
    Finder port(String name) => find.byKey(ValueKey('browser-port:${ports[name]}'));
    Future<void> waitFor(bool Function() condition) async {
      for (var attempt = 0; !condition() && attempt < 200; attempt++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump();
      }
      expect(condition(), true);
    }
    await waitFor(() => port('html').evaluate().isNotEmpty && port('redirect').evaluate().isNotEmpty);
    expect(port('api'), findsNothing);
    expect(port('empty'), findsNothing);
    await tester.tap(port('html'));
    expect(opened, Uri.parse('http://127.0.0.1:${ports['html']}'));
    await tester.runAsync(() async {
      process.stdin.writeln('stop-html');
      await process.stdin.flush();
      expect(await lines.moveNext(), true);
      expect(lines.current, 'stopped');
    });
    await tester.tap(find.byTooltip('Refresh local servers'));
    await waitFor(() => port('html').evaluate().isEmpty);
    expect(port('redirect'), findsOneWidget, reason: 'Discovery recognizes redirects without following them');
    expect(tester.takeException(), isNull);
  });
}
