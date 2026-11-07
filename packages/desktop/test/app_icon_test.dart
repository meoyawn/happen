import 'dart:async';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:typed_data';

import 'package:desktop/app_icon.dart';
import 'package:desktop/appearance.dart';
import 'package:desktop/database.dart';
import 'package:desktop/session.dart';
import 'package:desktop/settings_screen.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late IsolateOwner database;
  final controllers = <AppIconController>[];

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('happen-app-icon-');
    database = await openDesktopDatabase(directory.path);
  });

  tearDown(() async {
    for (final controller in controllers) { await controller.close(); }
    controllers.clear();
    await database.close();
    await directory.delete(recursive: true);
  });

  Future<Object?> savedChoice() async =>
    jsonObject(await callIsolate(database.port, 'load', {}))['settings']?['app_icon'];

  test('choice is acknowledged after the effect and commit, then restored on reopen', () async {
    Completer<void>? gate;
    final applied = <AppIconChoice>[];
    Future<void> apply(AppIconChoice choice, CancellationToken cancellation) async {
      if (gate case final pending?) await pending.future.asCancellable(cancellation);
      cancellation.throwIfCancelled();
      applied.add(choice);
    }
    final controller = AppIconController(database, apply: apply, release: () {});
    controllers.add(controller);
    await controller.ready;
    gate = Completer<void>();
    final saving = controller.choose(AppIconChoice.toiletPaper);
    expect(controller.state, isA<AppIconSaving>());
    expect(controller.state.value, AppIconChoice.standard);
    expect(await savedChoice(), isNull);
    gate.complete();
    await saving;
    gate = null;
    expect(controller.state, isA<AppIconReady>());
    expect(controller.state.value, AppIconChoice.toiletPaper);
    expect(await savedChoice(), 'toilet-paper');
    await controller.close();
    final reopened = AppIconController(database, apply: apply, release: () {});
    controllers.add(reopened);
    await reopened.ready;
    expect(applied.last, AppIconChoice.toiletPaper);
    expect(reopened.state.value, AppIconChoice.toiletPaper);
    await reopened.choose(AppIconChoice.standard);
    expect(await savedChoice(), 'default');
    expect(applied.last, AppIconChoice.standard);
  });

  test('a failed SQLite commit restores the native icon and allows a retry', () async {
    var active = AppIconChoice.standard;
    final controller = AppIconController(database, apply: (choice, cancellation) async {
      cancellation.throwIfCancelled();
      active = choice;
    }, release: () {});
    controllers.add(controller);
    await controller.ready;
    final disk = sqlite3.open('${directory.path}/desktop.sqlite');
    try {
      disk.execute('''CREATE TRIGGER reject_icon BEFORE INSERT ON settings
        WHEN NEW.key = 'app_icon' BEGIN SELECT RAISE(FAIL, 'write rejected'); END''');
      await expectLater(controller.choose(AppIconChoice.toiletPaper), throwsA(anything));
      expect(active, AppIconChoice.standard);
      expect(controller.state, isA<AppIconFailed>());
      expect(controller.state.value, AppIconChoice.standard);
      expect(await savedChoice(), isNull);
      disk.execute('DROP TRIGGER reject_icon');
      await controller.choose(AppIconChoice.toiletPaper);
      expect(active, AppIconChoice.toiletPaper);
      expect(await savedChoice(), 'toilet-paper');
    } finally { disk.close(); }
  });

  test('a native failure leaves the saved choice intact', () async {
    final controller = AppIconController(database, apply: (choice, cancellation) async {
      if (choice == AppIconChoice.toiletPaper) throw StateError('Image unavailable');
    }, release: () {});
    controllers.add(controller);
    await controller.ready;
    await expectLater(controller.choose(AppIconChoice.toiletPaper), throwsStateError);
    expect(controller.state, isA<AppIconFailed>());
    expect(controller.state.value, AppIconChoice.standard);
    expect(await savedChoice(), isNull);
  });

  test('closing cancels pending work before releasing resources or acknowledging a choice', () async {
    final gate = Completer<void>();
    var released = false;
    final controller = AppIconController(database, apply: (choice, cancellation) async {
      if (choice == AppIconChoice.toiletPaper) await gate.future.asCancellable(cancellation);
      cancellation.throwIfCancelled();
    }, release: () { released = true; });
    controllers.add(controller);
    await controller.ready;
    final saving = controller.choose(AppIconChoice.toiletPaper);
    await controller.close();
    gate.complete();
    await saving;
    expect(released, isTrue);
    expect(controller.state, isA<AppIconClosed>());
    expect(await savedChoice(), isNull);
  });

  testWidgets('macOS Settings switches the native icon, saves the choice, and restores Default offscreen', (tester) async {
    final objc = DynamicLibrary.open('/usr/lib/libobjc.A.dylib');
    DynamicLibrary.open('/System/Library/Frameworks/AppKit.framework/AppKit');
    final type = objc.lookupFunction<Pointer<Void> Function(Pointer<Utf8>),
      Pointer<Void> Function(Pointer<Utf8>)>('objc_getClass');
    final register = objc.lookupFunction<Pointer<Void> Function(Pointer<Utf8>),
      Pointer<Void> Function(Pointer<Utf8>)>('sel_registerName');
    final send = objc.lookupFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Void>),
      Pointer<Void> Function(Pointer<Void>, Pointer<Void>)>('objc_msgSend');
    final policy = objc.lookupFunction<Void Function(Pointer<Void>, Pointer<Void>, IntPtr),
      void Function(Pointer<Void>, Pointer<Void>, int)>('objc_msgSend');
    final length = objc.lookupFunction<UintPtr Function(Pointer<Void>, Pointer<Void>),
      int Function(Pointer<Void>, Pointer<Void>)>('objc_msgSend');
    final arena = Arena();
    try {
      Pointer<Void> sel(String name) => register(name.toNativeUtf8(allocator: arena));
      final app = send(type('NSApplication'.toNativeUtf8(allocator: arena)), sel('sharedApplication'));
      // This is flutter_tester's own application, never the human's Happen process.
      policy(app, sel('setActivationPolicy:'), 2); // NSApplicationActivationPolicyProhibited.
      Uint8List snapshot() {
        final image = send(app, sel('applicationIconImage'));
        final data = send(image, sel('TIFFRepresentation'));
        if (data == nullptr) return Uint8List(0);
        return Uint8List.fromList(send(data, sel('bytes')).cast<Uint8>()
          .asTypedList(length(data, sel('length'))));
      }
      final original = snapshot();
      final session = DesktopSession(_Client(), database,
        attachmentDirectory: '${directory.path}/attachments');
      Future<void>? updating;
      addTearDown(session.close);
      await tester.runAsync(() => session.appIcon.ready);
      tester.view.physicalSize = const Size(1120, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(theme: desktopTheme(), home: DesktopSettingsScreen(
        session: session, accounts: const SizedBox.shrink(), archived: const SizedBox.shrink(),
        run: (operation) => updating = operation(), initialPage: 'appearance', windowControls: false)));
      await tester.pumpAndSettle();
      try {
        expect(find.byType(Image), findsNWidgets(2));
        await tester.runAsync(() async {
          await tester.tap(find.text('Toilet paper'));
          await updating!;
        });
        await tester.pumpAndSettle();
        expect(session.appIcon.state.value, AppIconChoice.toiletPaper);
        expect(await tester.runAsync(savedChoice), 'toilet-paper');
        expect(snapshot(), isNotEmpty);
        expect(snapshot(), isNot(orderedEquals(original)));
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          await tester.tap(find.text('Default'));
          await updating!;
        });
        await tester.pumpAndSettle();
        expect(await tester.runAsync(savedChoice), 'default');
        expect(snapshot(), orderedEquals(original));
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        await tester.runAsync(session.appIcon.close);
      }
    } finally { arena.releaseAll(); }
  }, skip: !Platform.isMacOS, timeout: const Timeout(Duration(seconds: 20)));
}

class _Client implements AgentClient {
  @override
  final events = StreamController<Json>.broadcast();
  @override
  Future<void> close() => events.close();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
