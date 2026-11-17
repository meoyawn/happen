import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:server/src/workspaces.dart';
import 'package:test/test.dart';

void main() {
  test('workspace inspection transfers configured icons as bounded JSON data', () async {
    final root = await Directory.systemTemp.createTemp('workspace-icon-');
    final cancellation = CancellationToken();
    addTearDown(() async { cancellation.cancel(); await root.delete(recursive: true); });
    await Directory('${root.path}/.happen').create();
    const svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><circle cx="8" cy="8" r="8"/></svg>';
    await File('${root.path}/brand.svg').writeAsString(svg);
    await File('${root.path}/.happen/config.yaml').writeAsString('icon: brand.svg\n');
    final plain = await inspectWorkspace(root.path, cancellation);
    expect(plain.containsKey('icon_data'), isFalse);
    final appearance = await inspectWorkspace(root.path, cancellation, includeIcon: true);
    expect(appearance['available'], true);
    expect(appearance['icon'], 'brand.svg');
    expect(appearance['icon_svg'], true);
    expect(utf8.decode(base64Decode(appearance['icon_data'] as String)), svg);
    expect(() => jsonEncode(appearance), returnsNormally);
    final again = await inspectWorkspace(root.path, cancellation, includeIcon: true);
    expect(again['icon_revision'], appearance['icon_revision']);
    await File('${root.path}/brand.svg').writeAsString(svg.replaceFirst('r="8"', 'r="7"'));
    final changed = await inspectWorkspace(root.path, cancellation, includeIcon: true);
    expect(changed['icon_revision'], isNot(appearance['icon_revision']));
  });

  test('an unavailable icon does not prevent opening its workspace', () async {
    final root = await Directory.systemTemp.createTemp('workspace-icon-missing-');
    final cancellation = CancellationToken();
    addTearDown(() async { cancellation.cancel(); await root.delete(recursive: true); });
    await Directory('${root.path}/.happen').create();
    await File('${root.path}/.happen/config.yaml').writeAsString('icon: missing.svg\n');
    final result = await inspectWorkspace(root.path, cancellation, includeIcon: true);
    expect(result['available'], true);
    expect(result['icon_error'], isA<String>());
    expect(result['icon_revision'], isA<String>());
  });
}
