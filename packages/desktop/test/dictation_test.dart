import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:desktop/app.dart';
import 'package:desktop/composer_dictation.dart';
import 'package:desktop/composer_editor.dart';
import 'package:desktop/composer_text_controller.dart';
import 'package:desktop/conversation_annotations.dart';
import 'package:desktop/response_annotation.dart';
import 'package:desktop/database.dart';
import 'package:desktop/dictation.dart';
import 'package:desktop/dictation_state.dart';
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
  late Directory root;
  bool closed = false;
  final nativeCalls = <MethodCall>[];
  String? captureId;
  bool denyPermission = false;
  Completer<void>? startPending;
  HttpOverrides? previousHttp;

  setUp(() async {
    client = _Client();
    previousHttp = HttpOverrides.current;
    HttpOverrides.global = _TranscriptionHttp(client);
    root = await Directory.systemTemp.createTemp('desktop-dictation-');
    session = DesktopSession(client, await openDesktopDatabase(root.path));
    closed = false;
    session.dictationMode = 'on_stop';
    session.providers = [{'id': 'openai', 'name': 'ChatGPT', 'status': 'signed_in', 'models': [
      {'id': 'gpt-6.1-sol', 'reasoning_levels': ['low'], 'reasoning_updates': true},
    ]}];
    final task = DesktopTask('task', 'Example')..loaded = true..provider = 'openai'..model = 'gpt-6.1-sol'..reasoning = 'low';
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
    if (!closed) await session.close();
    await root.delete(recursive: true);
    HttpOverrides.global = previousHttp;
    messenger.setMockMethodCallHandler(DictationService.methods, null);
    messenger.setMockMethodCallHandler(const MethodChannel('happen/dictation/audio'), null);
  });

  TextEditingController editor(WidgetTester tester) =>
    tester.widget<ComposerEditor>(find.byType(ComposerEditor)).controller;

  Future<void> enterText(WidgetTester tester, String text) async {
    editor(tester).value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    await tester.pump();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(session.close);
    closed = true;
  }

  Future<void> open(WidgetTester tester) async {
    addTearDown(() async {
      if (!closed) {
        await tester.runAsync(session.close);
        closed = true;
      }
    });
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: DesktopView(session: session)));
    await tester.pumpAndSettle();
  }

  Future<void> record(WidgetTester tester, {Finder? within}) async {
    await tester.tap(within == null ? find.byTooltip('Dictate')
      : find.descendant(of: within, matching: find.byTooltip('Dictate')));
    await tester.pump();
    expect(session.dictation.state, isA<DictationRecording>());
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

  Future<void> stop(WidgetTester tester, {Finder? within}) async {
    // The trailing stop slot remains visible while the pill expands leftward.
    await tester.tapAt(tester.getTopRight(within == null ? find.byType(DictationButton)
      : find.descendant(of: within, matching: find.byType(DictationButton))) + const Offset(-14, 14));
    await tester.pump();
  }

  Future<void> respond(WidgetTester tester, {String? text, Object? error}) async {
    if (error != null) { client.reply.completeError(error); }
    else { client.reply.complete(text!); }
    await tester.pump();
    // Cross both event loops until the real HTTP stream's cleanup settles.
    for (var i = 0; i < 20 && session.dictation.state is DictationTranscribing; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 350));
    expect(session.dictation.state, error == null ? isA<DictationIdle>() : isA<DictationFailed>());
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

  QuestionDraft askQuestions() {
    final request = <String, dynamic>{'id': 'question', 'questions': [
      {'question': 'Describe your workout', 'options': <Json>[]},
      {'question': 'What will you do next?', 'options': <Json>[]},
    ]};
    session.task!.questions['question'] = request;
    return session.task!.questionDrafts['question'] = QuestionDraft.fromRequest(request);
  }

  testWidgets('annotation dictation inserts and saves its comment while preserving the main draft', (tester) async {
    session.dictationMode = 'live';
    await liveBackend(tester);
    await open(tester);
    await enterText(tester, 'Unsent main draft');
    final mainEditor = editor(tester);
    final composer = tester.element(find.byKey(const ValueKey('conversation-composer')));
    final scope = ConversationAnnotationScope.maybeOf(composer)!;
    scope.onAdd(const ResponseAnnotation(id: 'response-comment', text: 'Selected response',
      messageId: 'response', startOffset: 0, endOffset: 17), const Offset(400, 300));
    await tester.pumpAndSettle();
    final popover = find.byType(ResponseAnnotationEditor);
    final field = find.descendant(of: popover, matching: find.byType(TextField));
    expect(tester.getSize(popover), const Size(294, 44));
    await record(tester, within: popover);
    expect(tester.widget<TextField>(field).controller!.text, 'live words');
    expect(mainEditor.text, 'Unsent main draft');
    await stop(tester, within: popover);
    for (var i = 0; i < 100 && session.dictation.active; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, 'live words.');
    expect(popover, findsOneWidget, reason: 'Stopping dictation must retain the comment editor');
    expect(client.sent, isEmpty);
    await tester.tap(find.byTooltip('Save annotation'));
    await tester.pumpAndSettle();
    expect(popover, findsNothing);
    expect(session.annotationsFor('task').single.annotation, 'live words.');
    expect(mainEditor.text, 'Unsent main draft');
    expect(client.sent, isEmpty, reason: 'Saving an annotation must not submit a turn');

    scope.onEdit(session.annotationsFor('task').single);
    await tester.pumpAndSettle();
    await record(tester, within: popover);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(popover, findsNothing);
    expect(session.dictation.active, isFalse);
    expect(session.dictation.owner, isNull);
    expect(session.annotationsFor('task').single.annotation, contains('live words.'));
    expect(mainEditor.text, 'Unsent main draft');
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await close(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  test('annotation submission retains failures and edits made before acknowledgement', () async {
    const original = ResponseAnnotation(id: 'comment', text: 'Selected response', annotation: 'First comment',
      messageId: 'response', startOffset: 0, endOffset: 17);
    session.putAnnotation('task', original);
    client.turnReply = Completer<Object?>();
    final first = session.send('', annotations: session.annotationsFor('task'));
    await Future<void>.delayed(Duration.zero);
    expect(session.annotationsFor('task'), [original]);
    client.turnReply!.completeError(StateError('Offline'));
    expect(await first, isFalse);
    expect(session.annotationsFor('task'), [original]);

    client.turnReply = Completer<Object?>();
    final second = session.send('Fix this', annotations: session.annotationsFor('task'));
    await Future<void>.delayed(Duration.zero);
    final edited = original.withComment('Updated before acknowledgement');
    session.putAnnotation('task', edited);
    client.turnReply!.complete(<String, dynamic>{});
    expect(await second, isTrue);
    expect(session.annotationsFor('task'), [edited]);
    final input = (client.sent.last['input'] as List).single as Json;
    final projected = DesktopTask('projection', 'Projection')..loaded = true;
    projected.messages['user'] = {'id': 'user', 'type': 'userMessage', 'order': 0, 'content': [input]};
    final entry = conversation(projected).single;
    expect(entry.text, 'Fix this');
    expect(entry.annotations.single.annotation, 'First comment');
    expect(entry.annotations.single.messageId, 'response');

    session.task!.running = false;
    client.turnReply = null;
    expect(await session.send('Finish', annotations: session.annotationsFor('task')), isTrue);
    expect(session.annotationsFor('task'), isEmpty);

    session.putAnnotation('task', edited.withComment('Next request'));
    await session.close();
    closed = true;
    final reopened = await openDesktopDatabase(root.path);
    final cancellation = CancellationToken();
    try {
      final saved = jsonObject(await callIsolate(reopened.port, 'load', {}, cancellation: cancellation));
      final drafts = jsonObject(jsonDecode(jsonObject(saved['settings'])['session_drafts'] as String));
      expect(drafts['annotations'], {'task': [{
        'id': 'comment', 'text': 'Selected response', 'annotation': 'Next request',
        'source': {'messageId': 'response', 'startOffset': 0, 'endOffset': 17},
      }]});
    } finally { cancellation.cancel(); await reopened.close(); }
  });

  testWidgets('question dictation inserts into answers and finishes before advancing or submitting', (tester) async {
    final draft = askQuestions();
    session.drafts['task'] = 'Keep the message draft';
    await open(tester);
    await enterText(tester, 'Before after');
    editor(tester).selection = const TextSelection.collapsed(offset: 6);
    await record(tester);
    expect(find.text('Describe your workout'), findsOneWidget);
    await stop(tester);
    await respond(tester, text: 'spoken answer');
    expect(editor(tester).text, 'Before spoken answer after');
    expect(draft.answer(0), ['Before spoken answer after']);

    await record(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(draft.tab, 0, reason: 'The answer must finish transcribing before navigation');
    await respond(tester, text: 'more');
    expect(draft.tab, 1);
    expect(draft.answer(0), ['Before spoken answer more after']);
    expect(editor(tester).text, isEmpty);

    await record(tester);
    await tester.tap(find.text('Submit answers'));
    await tester.pump();
    expect(client.answers, isEmpty);
    await respond(tester, text: 'Train again tomorrow');
    expect(client.answers, [
      [['Before spoken answer more after'], ['Train again tomorrow']],
    ]);
    expect(client.sent, isEmpty, reason: 'Dictated answers use the question reply');
    expect(session.drafts['task'], 'Keep the message draft');
    expect(tester.takeException(), isNull);
    await close(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('changing questions cancels transcription and ignores a late answer', (tester) async {
    final draft = askQuestions()..tab = 1;
    draft.custom.setAll(0, ['First answer', 'Second answer']);
    await open(tester);
    await record(tester);
    await stop(tester);
    await tester.tap(find.text('Previous'));
    await tester.pumpAndSettle();
    client.reply.complete('late answer');
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(session.dictation.state, isA<DictationIdle>());
    expect(editor(tester).text, 'First answer');
    expect(draft.custom, ['First answer', 'Second answer']);
    expect(client.answers, isEmpty);
    expect(client.sent, isEmpty);
    expect(tester.takeException(), isNull);
    await close(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('leaving a dictated question restores its live answer before disposing the dock', (tester) async {
    final draft = askQuestions();
    draft.custom[0] = 'Keep this answer';
    session.dictationMode = 'live';
    await liveBackend(tester);
    await open(tester);
    await record(tester);
    expect(editor(tester).text, 'Keep this answer live words');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
    expect(draft.custom[0], 'Keep this answer');
    expect(session.dictation.state, isA<DictationIdle>());
    expect(client.answers, isEmpty);
    expect(client.sent, isEmpty);
    expect(tester.takeException(), isNull);
    await close(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

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
    await enterText(tester, 'Hello world');
    final controller = editor(tester);
    controller.selection = const TextSelection.collapsed(offset: 5);
    await record(tester);
    expect(controller.text, 'Hello live words world');
    expect(client.recordings, isEmpty, reason: 'Live audio never goes through the on-stop upload');
    expect(session.dictation.state, isA<DictationRecording>());
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
    expect(session.dictation.state, isA<DictationIdle>());
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(milliseconds: 350));
    expect(client.sent.single['input'], [{'type': 'text', 'text': 'Hello live words. world'}]);
    expect(client.recordings, isEmpty, reason: 'A recording keeps the mode it started with');
    expect(controller.text, isEmpty);
    expect(tester.takeException(), isNull);
    await close(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('a failed live connection retains audio and replaces partial text on stop', (tester) async {
    session.dictationMode = 'live';
    await liveBackend(tester, failStream: true);
    await open(tester);
    await record(tester);
    expect(editor(tester).text, 'live words');
    expect(session.dictation.liveTranscriptionHint, 'Text will appear when you stop');
    await stop(tester);
    expect(client.recordings, hasLength(1));
    expect(_recording(client.recordings.single).length, 16044);
    await respond(tester, text: 'Recovered complete sentence.');
    expect(editor(tester).text, 'Recovered complete sentence.');
    expect(client.sent, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 6));
    await close(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('leaving a live recording restores its draft before disposing the editor', (tester) async {
    session.dictationMode = 'live';
    await liveBackend(tester);
    await open(tester);
    await enterText(tester, 'Keep this');
    await record(tester);
    expect(editor(tester).text, 'Keep this live words');
    await tester.runAsync(() => session.select(session.project!));
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    expect(session.drafts['task'], 'Keep this');
    expect(session.dictation.state, isA<DictationIdle>());
    expect(editor(tester).text, isEmpty);
    expect(tester.takeException(), isNull);
    await close(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('Stop inserts into the selection; Enter transcribes and sends exactly once', (tester) async {
    await open(tester);
    await enterText(tester, 'Hello world');
    final controller = editor(tester);
    controller.selection = const TextSelection.collapsed(offset: 5);
    await record(tester);
    expect(find.byTooltip('Cancel dictation'), findsOneWidget);
    await stop(tester);
    expect(session.dictation.state, isA<DictationTranscribing>());
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
    expect(client.sent.single['input'], [{'type': 'text', 'text': 'Hello there world again'}]);
    expect(controller.text, isEmpty);
    expect(tester.takeException(), isNull);
    await close(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('Retry keeps the same audio; Escape cancels a pending response without changing the draft', (tester) async {
    await open(tester);
    await enterText(tester, 'Keep this draft');
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
    expect(session.dictation.state, isA<DictationIdle>());
    client.reply.complete('late text');
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(editor(tester).text, 'Keep this draft');
    expect(client.sent, isEmpty);
    expect(session.dictation.state, isA<DictationIdle>());
    await close(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('navigation cancels the old recording and a late result cannot enter another draft', (tester) async {
    await open(tester);
    await enterText(tester, 'Original draft');
    await record(tester);
    await stop(tester);
    await tester.runAsync(() => session.select(session.project!));
    await tester.pumpAndSettle();
    client.reply.complete('wrong chat');
    await tester.pumpAndSettle();
    expect(session.drafts['task'], 'Original draft');
    expect(editor(tester).text, isEmpty);
    expect(client.sent, isEmpty);
    expect(tester.takeException(), isNull);
    await close(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('startup can be cancelled and permission denial links to microphone settings', (tester) async {
    await open(tester);
    await enterText(tester, 'typing');
    final controller = editor(tester);
    controller.value = controller.value.copyWith(composing: const TextRange(start: 0, end: 6));
    startPending = Completer<void>();
    await tester.tap(find.byTooltip('Dictate'));
    await tester.pump();
    expect(session.dictation.state, isA<DictationStarting>());
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(session.dictation.state, isA<DictationStarting>(), reason: 'Escape belongs to the active IME composition');
    controller.clearComposing();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    startPending!.complete();
    await tester.pumpAndSettle();
    expect(session.dictation.state, isA<DictationIdle>());
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
    await close(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('recordings shorter than 250 ms make no transcription request', (tester) async {
    await open(tester);
    await tester.tap(find.byTooltip('Dictate'));
    await tester.pump();
    await stop(tester);
    await tester.pumpAndSettle();
    expect(session.dictation.state, isA<DictationIdle>());
    expect(client.recordings, isEmpty);
    expect(client.sent, isEmpty);
    await close(tester);
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
  final answers = <List<List<String>>?>[];
  final recordings = <Uint8List>[];
  late Completer<String> reply;
  int? streamPort;
  Completer<Object?>? turnReply;
  @override Future<Json> desktopAuthorization({bool refresh = false, required CancellationToken cancellation}) async =>
    {'access_token': 'fixture', 'account_id': 'account'};
  @override Future<void> answerQuestion(String sessionID, String requestID, List<List<String>>? answers, {
    required CancellationToken cancellation,
  }) async {
    cancellation.throwIfCancelled();
    this.answers.add(answers);
  }
  @override Future<Object?> request(String method, [Json params = const {}]) async {
    if (method == 'turn/start') { sent.add(params); return turnReply == null ? <String, dynamic>{} : await turnReply!.future; }
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
  @override Duration idleTimeout = const Duration(seconds: 15);
  @override Future<HttpClientRequest> openUrl(String method, Uri url) {
    if (url.path == '/backend-api/transcribe') return postUrl(url);
    if (client.streamPort == null) throw StateError('Unexpected live connection');
    return http.openUrl(method, url.replace(scheme: 'http', host: '127.0.0.1', port: client.streamPort));
  }
  @override Future<HttpClientRequest> postUrl(Uri url) async {
    expect(url.toString(), 'https://chatgpt.com/backend-api/transcribe');
    final request = _Request(client);
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
  @override void add(List<int> data) => bytes.add(data);
  @override Future<HttpClientResponse> close() async {
    client.recordings.add(bytes.takeBytes());
    client.reply = Completer<String>();
    return _Response(client.reply.future);
  }
  @override void abort([Object? exception, StackTrace? stackTrace]) {}
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.text);
  final Future<String> text;
  @override final statusCode = 200;
  @override final reasonPhrase = 'OK';
  @override final headers = _Headers();
  @override StreamSubscription<List<int>> listen(void Function(List<int>)? onData,
    {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
    Stream<List<int>>.fromFuture(text.then((value) => utf8.encode(jsonEncode({'text': value})))).listen(
      onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Headers implements HttpHeaders {
  @override void forEach(void Function(String, List<String>) action) {}
  @override void set(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override List<String>? operator [](String name) => null;
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
