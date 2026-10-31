import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:desktop/app.dart';
import 'package:desktop/composer_dictation.dart';
import 'package:desktop/composer_text_controller.dart';
import 'package:desktop/dictation.dart';
import 'package:desktop/dictation_controls.dart';
import 'package:desktop/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _Client client;
  late DesktopSession session;
  final nativeCalls = <MethodCall>[];
  String? captureId;
  bool denyPermission = false;
  Completer<void>? startPending;
  HttpOverrides? previousHttp;

  setUp(() {
    client = _Client();
    previousHttp = HttpOverrides.current;
    HttpOverrides.global = _TranscriptionHttp(client);
    session = DesktopSession(client, _Database());
    session.dictationMode = 'on_stop';
    session.providers = [{'id': 'gpt', 'name': 'ChatGPT', 'status': 'signed_in', 'models': [
      {'id': 'gpt-6.1-sol', 'reasoning_levels': ['low'], 'reasoning_updates': true},
    ]}];
    final task = DesktopTask('task', 'Example')..loaded = true..provider = 'gpt'..model = 'gpt-6.1-sol'..reasoning = 'low';
    session.project = Project('checkout', '/project', '/project', [task]);
    session.projects.add(session.project!);
    session.task = task;
    nativeCalls.clear();
    captureId = null;
    denyPermission = false;
    startPending = null;
    messenger.setMockMethodCallHandler(DictationService.methods, (call) async {
      nativeCalls.add(call);
      if (call.method == 'start') {
        captureId = (call.arguments as Map)['id'] as String;
        await startPending?.future;
        if (denyPermission) throw PlatformException(code: 'microphone_permission');
        return {'sampleRate': 16000};
      }
      return null;
    });
    messenger.setMockMethodCallHandler(const MethodChannel('happen/dictation/audio'), (_) async => null);
  });
  tearDown(() async {
    await session.close();
    HttpOverrides.global = previousHttp;
    messenger.setMockMethodCallHandler(DictationService.methods, null);
    messenger.setMockMethodCallHandler(const MethodChannel('happen/dictation/audio'), null);
  });

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: DesktopView(session: session)));
    await tester.pumpAndSettle();
  }

  Future<void> record(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Dictate'));
    await tester.pump();
    expect(session.dictation.phase, DictationPhase.recording);
    await tester.runAsync(() async {
      await messenger.handlePlatformMessage('happen/dictation/audio', const StandardMethodCodec().encodeSuccessEnvelope({
        'type': 'audio', 'id': captureId, 'pcm': Uint8List.fromList(List.filled(16000, 0)), 'rms': .08,
      }), (_) {});
      await Future<void>.delayed(const Duration(milliseconds: 260));
    });
    await tester.pump();
    if (client.streamPort != null) {
      for (var i = 0; i < 100 && session.dictation.transcript.isEmpty; i++) {
        await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 10)); });
        await tester.pump();
      }
    }
    expect(find.byType(DictationLevelWaveform), findsOneWidget);
  }

  Future<void> stop(WidgetTester tester) async {
    // The trailing stop slot remains visible while the pill expands leftward.
    await tester.tapAt(tester.getTopRight(find.byType(DictationButton)) + const Offset(-14, 14));
    await tester.pump();
  }

  Future<void> respond(WidgetTester tester, {String? text, Object? error}) async {
    if (error != null) { client.reply.completeError(error); }
    else { client.reply.complete(text!); }
    await tester.pump();
    // StreamIterator cleanup also uses completed futures from the real zone.
    await tester.runAsync(() async {});
    await tester.pump(const Duration(milliseconds: 350));
    expect(session.dictation.phase, error == null ? DictationPhase.idle : DictationPhase.failed);
  }

  Future<void> liveBackend(WidgetTester tester, {bool failStream = false}) async {
    await tester.runAsync(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      client.streamPort = server.port;
      final sockets = <WebSocket>[];
      addTearDown(() async {
        for (final socket in sockets) { await socket.close(); }
        await server.close(force: true);
      });
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((raw) {
          final type = jsonObject(jsonDecode(raw as String))['type'];
          if (type == 'session.start') socket.add('{"type":"session.started"}');
          if (type == 'audio.append') {
            socket.add('{"type":"transcript.segment","utterance_id":"a","revision":1,"text":"live words"}');
            if (failStream) socket.add('{"type":"session.error","fatal":true}');
          }
          if (type == 'session.close') {
            socket.add('{"type":"transcript.final","utterance_id":"a","revision":0,"text":"live words."}');
            socket.add('{"type":"session.updated","session":{"status":"closed"}}');
          }
        });
      });
    });
  }

  test('cancelled dictation restores a selected file chip and its path', () {
    final controller = ComposerTextController(text: 'Use @file afterwards');
    addTearDown(controller.dispose);
    controller.insertFile(const TextRange(start: 4, end: 9), 'lib/main.dart');
    controller.selection = const TextSelection(baseOffset: 4, extentOffset: 5);
    final insertion = ComposerDictationSession(controller, (range, text) {
      controller.value = TextEditingValue(text: controller.text.replaceRange(range.start, range.end, text),
        selection: TextSelection.collapsed(offset: range.start + text.length));
    });
    insertion.update('live words');
    expect(controller.files, isEmpty);
    insertion.dispose(cancel: true);
    expect(controller.serializePrompt(), 'Use [main.dart](lib/main.dart) afterwards');
    expect(controller.files.single.path, 'lib/main.dart');
    expect(client.sent, isEmpty);
  });

  testWidgets('live text appears while recording, cancels cleanly and finalizes once on Enter', (tester) async {
    session.dictationMode = 'live';
    await liveBackend(tester);
    await open(tester);
    await tester.enterText(find.byType(TextField), 'Hello world');
    final controller = tester.widget<TextField>(find.byType(TextField)).controller!;
    controller.selection = const TextSelection.collapsed(offset: 5);
    await record(tester);
    expect(controller.text, 'Hello live words world');
    expect(client.recordings, isEmpty, reason: 'Live audio never goes through the on-stop upload');
    expect(session.dictation.phase, DictationPhase.recording);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(controller.text, 'Hello world');
    controller.selection = const TextSelection.collapsed(offset: 5);
    await record(tester);
    session.dictationMode = 'on_stop';
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    for (var i = 0; i < 100 && session.dictation.active; i++) {
      await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 10)); });
      await tester.pump();
    }
    expect(session.dictation.phase, DictationPhase.idle);
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(milliseconds: 350));
    expect(client.sent.single['prompt'], 'Hello live words. world');
    expect(client.recordings, isEmpty, reason: 'A recording keeps the mode it started with');
    expect(controller.text, isEmpty);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('a failed live connection retains audio and replaces partial text on stop', (tester) async {
    session.dictationMode = 'live';
    await liveBackend(tester, failStream: true);
    await open(tester);
    await record(tester);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'live words');
    expect(find.text('Text will appear when you stop'), findsOneWidget);
    await stop(tester);
    expect(client.recordings, hasLength(1));
    expect(_recording(client.recordings.single).length, 16044);
    await respond(tester, text: 'Recovered complete sentence.');
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Recovered complete sentence.');
    expect(client.sent, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 6));
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('leaving a live recording restores its draft before disposing the editor', (tester) async {
    session.dictationMode = 'live';
    await liveBackend(tester);
    await open(tester);
    await tester.enterText(find.byType(TextField), 'Keep this');
    await record(tester);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Keep this live words');
    await tester.runAsync(() => session.select(session.project!));
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    expect(session.drafts['task'], 'Keep this');
    expect(session.dictation.phase, DictationPhase.idle);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('Stop inserts into the selection; Enter transcribes and sends exactly once', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'Hello world');
    final controller = tester.widget<TextField>(find.byType(TextField)).controller!;
    controller.selection = const TextSelection.collapsed(offset: 5);
    await record(tester);
    expect(find.byTooltip('Cancel dictation'), findsOneWidget);
    await stop(tester);
    expect(session.dictation.phase, DictationPhase.transcribing);
    expect(client.recordings, hasLength(1));
    final wav = _recording(client.recordings.single);
    expect(ByteData.sublistView(wav).getUint32(24, Endian.little), 16000);
    await respond(tester, text: ' there ');
    expect(controller.text, 'Hello there world');
    expect(controller.selection.baseOffset, 11);
    expect(session.drafts['task'], 'Hello there world');
    expect(client.sent, isEmpty);

    controller.selection = TextSelection.collapsed(offset: controller.text.length);
    await record(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(client.recordings, hasLength(2));
    await respond(tester, text: 'again');
    expect(client.sent.single['prompt'], 'Hello there world again');
    expect(controller.text, isEmpty);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('Retry keeps the same audio; Escape cancels a pending response without changing the draft', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'Keep this draft');
    await record(tester);
    await stop(tester);
    await respond(tester, error: StateError('Unable to transcribe audio'));
    expect(find.text('Dictation stopped'), findsOneWidget);
    await tester.tap(find.byTooltip('Retry dictation'));
    await tester.pump();
    expect(client.recordings, hasLength(2));
    expect(_recording(client.recordings[0]), _recording(client.recordings[1]));
    expect(nativeCalls.where((call) => call.method == 'start'), hasLength(1));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(client.requests.last.aborted, isTrue);
    client.reply.complete('late text');
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Keep this draft');
    expect(client.sent, isEmpty);
    expect(session.dictation.phase, DictationPhase.idle);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('navigation cancels the old recording and a late result cannot enter another draft', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'Original draft');
    await record(tester);
    await stop(tester);
    await tester.runAsync(() => session.select(session.project!));
    await tester.pumpAndSettle();
    client.reply.complete('wrong chat');
    await tester.pumpAndSettle();
    expect(session.drafts['task'], 'Original draft');
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    expect(client.sent, isEmpty);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('startup can be cancelled and permission denial links to microphone settings', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'typing');
    final controller = tester.widget<TextField>(find.byType(TextField)).controller!;
    controller.value = controller.value.copyWith(composing: const TextRange(start: 0, end: 6));
    startPending = Completer<void>();
    await tester.tap(find.byTooltip('Dictate'));
    await tester.pump();
    expect(session.dictation.phase, DictationPhase.starting);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(session.dictation.phase, DictationPhase.starting, reason: 'Escape belongs to the active IME composition');
    controller.clearComposing();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    startPending!.complete();
    await tester.pumpAndSettle();
    expect(session.dictation.phase, DictationPhase.idle);
    expect(client.recordings, isEmpty);
    startPending = null;
    denyPermission = true;
    await tester.tap(find.byTooltip('Dictate'));
    await tester.pumpAndSettle();
    expect(find.text('Enable mic access to dictate'), findsOneWidget);
    await tester.tap(find.text('Open microphone settings'));
    await tester.pump();
    expect(nativeCalls.last.method, 'openMicrophoneSettings');
    expect(find.text('Dictation stopped'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('recordings shorter than 250 ms make no transcription request', (tester) async {
    await open(tester);
    await tester.tap(find.byTooltip('Dictate'));
    await tester.pump();
    await stop(tester);
    await tester.pumpAndSettle();
    expect(session.dictation.phase, DictationPhase.idle);
    expect(client.recordings, isEmpty);
    expect(client.sent, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  test('final insertion waits for IME and cancellation releases the editor', () async {
    final controller = TextEditingController.fromValue(const TextEditingValue(text: '(',
      selection: TextSelection.collapsed(offset: 1), composing: TextRange(start: 0, end: 1)));
    void replace(TextSelection range, String text) => controller.value = TextEditingValue(
      text: controller.text.replaceRange(range.start, range.end, text),
      selection: TextSelection.collapsed(offset: range.start + text.length));
    final insertion = ComposerDictationSession(controller, replace);
    final pending = insertion.finish('words');
    expect(controller.text, '(');
    controller.value = const TextEditingValue(text: '()', selection: TextSelection.collapsed(offset: 1));
    expect(await pending, isTrue);
    expect(controller.text, '(words)');
    insertion.dispose();
    controller.value = const TextEditingValue(text: 'typing', selection: TextSelection.collapsed(offset: 6), composing: TextRange(start: 0, end: 6));
    final cancelled = ComposerDictationSession(controller, replace);
    final stopped = cancelled.finish('discarded');
    cancelled.dispose();
    expect(await stopped, isFalse);
    expect(controller.text, 'typing');
    controller.dispose();
  });

  test('live revisions preserve manual edits and cancel restores only untouched dictated ranges', () async {
    final controller = TextEditingController.fromValue(const TextEditingValue(text: 'Before after', selection: TextSelection.collapsed(offset: 6)));
    void replace(TextSelection range, String text) => controller.value = TextEditingValue(
      text: controller.text.replaceRange(range.start, range.end, text),
      selection: TextSelection.collapsed(offset: range.start + text.length));
    final insertion = ComposerDictationSession(controller, replace);
    insertion.update('one');
    expect(controller.text, 'Before one after');
    insertion.update('one two');
    expect(controller.text, 'Before one two after');
    replace(const TextSelection(baseOffset: 7, extentOffset: 10), 'edited');
    controller.selection = TextSelection.collapsed(offset: controller.text.length);
    insertion.update('One two three');
    expect(controller.text, 'Before edited two after three');
    insertion.dispose(cancel: true);
    expect(controller.text, 'Before edited two after');
    controller.dispose();
  });
}

class _Client implements AgentClient {
  @override bool get sharedFilesystem => true;
  @override final events = StreamController<Json>.broadcast();
  final sent = <Json>[];
  final recordings = <Uint8List>[];
  final requests = <_Request>[];
  late Completer<String> reply;
  int? streamPort;
  @override Future<Json> desktopAuthorization({bool refresh = false, required CancellationToken cancellation}) async =>
    {'access_token': 'fixture', 'account_id': 'account'};
  @override Future<Object?> request(String method, [Json params = const {}]) async {
    if (method == 'task.send') { sent.add(params); return {'task_id': 'task'}; }
    throw StateError('Unexpected request: $method');
  }
  @override Future<void> close() => events.close();
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected client operation');
}

Uint8List _recording(Uint8List multipart) {
  final start = latin1.decode(multipart).indexOf('\r\n\r\n') + 4;
  expect(String.fromCharCodes(multipart.sublist(start, start + 4)), 'RIFF');
  final length = ByteData.sublistView(multipart).getUint32(start + 40, Endian.little);
  return Uint8List.sublistView(multipart, start, start + 44 + length);
}

// The widget tests control only the external response. HTTP wire, credential
// ownership, refusals and cancellation are exercised with real sockets in the
// repository's dictation_test.dart.
class _TranscriptionHttp extends HttpOverrides {
  _TranscriptionHttp(this.client);
  final _Client client;
  @override HttpClient createHttpClient(SecurityContext? context) => _Http(client, super.createHttpClient(context));
}

class _Http implements HttpClient {
  _Http(this.client, this.http);
  final _Client client;
  final HttpClient http;
  @override Duration? connectionTimeout;
  @override Future<HttpClientRequest> openUrl(String method, Uri url) {
    if (client.streamPort == null) throw StateError('Unexpected live connection');
    return http.openUrl(method, url.replace(scheme: 'http', host: '127.0.0.1', port: client.streamPort));
  }
  @override Future<HttpClientRequest> postUrl(Uri url) async {
    expect(url.toString(), 'https://chatgpt.com/backend-api/transcribe');
    final request = _Request(client);
    client.requests.add(request);
    return request;
  }
  @override void close({bool force = false}) => http.close(force: force);
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.client);
  final _Client client;
  final bytes = BytesBuilder(copy: false);
  @override final headers = _Headers();
  @override bool followRedirects = true;
  @override int contentLength = -1;
  bool aborted = false;
  @override void add(List<int> data) => bytes.add(data);
  @override Future<HttpClientResponse> close() async {
    client.recordings.add(bytes.takeBytes());
    client.reply = Completer<String>();
    return _Response(client.reply.future);
  }
  @override void abort([Object? exception, StackTrace? stackTrace]) { aborted = true; }
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.text);
  final Future<String> text;
  @override final statusCode = 200;
  @override final headers = _Headers();
  @override StreamSubscription<List<int>> listen(void Function(List<int>)? onData,
    {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
    Stream<List<int>>.fromFuture(text.then((value) => utf8.encode(jsonEncode({'text': value})))).listen(
      onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Headers implements HttpHeaders {
  @override void set(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override List<String>? operator [](String name) => null;
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Database implements IsolateOwner {
  @override Future<void> close() async {}
  @override dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected database operation');
}
