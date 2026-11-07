import 'dart:io';
import 'dart:ui' as ui;

import 'package:desktop/appearance.dart';
import 'package:desktop/appearance_preferences.dart';
import 'package:desktop/appearance_settings.dart';
import 'package:desktop/conversation_markdown.dart';
import 'package:desktop/database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await (FontLoader('Inter')..addFont(rootBundle.load('assets/fonts/Inter.ttf'))).load();
    await (FontLoader('IBM Plex Mono')..addFont(rootBundle.load('assets/fonts/IBMPlexMono-Text.ttf'))).load();
  });

  testWidgets('selection uses the accent while action buttons stay black', (tester) async {
    tester.view.physicalSize = const Size(900, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundary = GlobalKey();
    for (final accent in [const Color(0xff339cff), const Color(0xffd65c38)]) {
      await tester.pumpWidget(MaterialApp(theme: desktopTheme(accent: accent), home: RepaintBoundary(
        key: boundary, child: Scaffold(body: Padding(padding: const EdgeInsets.all(32),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const ConversationMarkdown(directory: '', text:
              'Плюс исследования надёжности и участие в архитектуре. Поэтому я читаю эту роль как '
              '**разработку софта для SRE**, с заметной потребностью понимать Linux, Kubernetes и '
              'поведение распределённых систем. Это моя интерпретация перечисленных задач. '
              '[Задачи позиции](https://example.com) и `inline code`.'),
            const SizedBox(height: 24),
            FilledButton(onPressed: () {}, child: const Text('Continue')),
          ]))))));
      await tester.pumpAndSettle();
      tester.state<SelectableRegionState>(find.byType(SelectableRegion)).selectAll(SelectionChangedCause.keyboard);
      await tester.pumpAndSettle();
      final box = tester.renderObject<RenderRepaintBoundary>(find.byKey(boundary));
      final image = (await tester.runAsync(() => box.toImage()))!;
      final data = (await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
      final pixels = data.buffer.asUint8List();
      var tinted = 0;
      final blue = accent == const Color(0xff339cff);
      for (var i = 0; i < pixels.length; i += 4) {
        final red = pixels[i], green = pixels[i + 1], b = pixels[i + 2];
        if (blue ? b > red + 30 && red > 180 && green > 200
            : red > b + 25 && b > 170 && green > 170) {
          tinted++;
        }
      }
      expect(tinted, greaterThan(4000), reason: 'Selected prose must have a soft accent fill, including bold text and links');
      final button = tester.getRect(find.widgetWithText(FilledButton, 'Continue'));
      final point = box.globalToLocal(button.centerLeft + const Offset(8, 0));
      final offset = (point.dy.floor() * image.width + point.dx.floor()) * 4;
      expect(pixels.sublist(offset, offset + 3), everyElement(lessThan(40)),
        reason: 'An accent change must not recolor action buttons');
      if (Platform.environment['HAPPEN_TEST_REPORT_ROOT'] case final root?) {
        final png = await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png));
        await tester.runAsync(() async {
          final file = File('$root/.local/reports/selection-${blue ? 'blue' : 'custom'}.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(png!.buffer.asUint8List());
        });
      }
      image.dispose();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('custom accent is committed from settings and restored on reopening', (tester) async {
    late Directory directory;
    late IsolateOwner database;
    late AppearanceController controller;
    Future<void>? operation;
    Future<void> run(Future<void> Function() action) => operation = action();
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('happen-appearance-');
      database = await openDesktopDatabase(directory.path);
      controller = AppearanceController(database);
      await controller.ready;
    });
    addTearDown(() async {
      await controller.close();
      await database.close();
      await directory.delete(recursive: true);
    });
    await tester.pumpWidget(MaterialApp(theme: desktopTheme(), home: Scaffold(body:
      DesktopAccentSettings(controller: controller, run: run))));
    await tester.enterText(find.byType(TextField), '#c05a40');
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.text('Apply'));
      await operation;
      final saved = jsonObject(await callIsolate(database.port, 'load', {}));
      expect(saved['settings']['accent_color'], '#c05a40');
    });
    await tester.pumpAndSettle();
    expect(controller.state.value, const Color(0xffc05a40));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await controller.close();
      await database.close();
      database = await openDesktopDatabase(directory.path);
      controller = AppearanceController(database);
      await controller.ready;
    });
    expect(controller.state.value, const Color(0xffc05a40));
    await tester.pumpWidget(MaterialApp(theme: desktopTheme(accent: controller.state.value), home: Scaffold(body:
      DesktopAccentSettings(controller: controller, run: run))));
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '#c05a40');
    await tester.enterText(find.byType(TextField), '#invalid');
    await tester.pump();
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Apply')).onPressed, isNull);
    await tester.runAsync(() async {
      await tester.tap(find.text('Reset'));
      await operation;
      final saved = jsonObject(await callIsolate(database.port, 'load', {}));
      expect(saved['settings']['accent_color'], '#339cff');
    });
    await tester.pumpAndSettle();
    expect(controller.state.value, const Color(0xff339cff));
    await tester.enterText(find.byType(TextField), '#abcdef');
    await tester.pump();
    await tester.tap(find.byTooltip('Blue'));
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '#339cff');
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Apply')).onPressed, isNull,
      reason: 'Rechoosing the active preset must discard the edited hex value');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
