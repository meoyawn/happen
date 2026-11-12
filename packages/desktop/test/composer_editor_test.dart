import 'dart:async';

import 'package:desktop/composer_editor.dart';
import 'package:desktop/composer_text_controller.dart';
import 'package:desktop/file_autocomplete.dart';
import 'package:desktop/file_icon.dart';
import 'package:desktop/session.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:re_editor/re_editor.dart';
import 'package:server/server.dart';

class _Client extends Fake implements AgentClient {
  List<String> paths = ['lib/main.dart', 'src/index.ts', 'tools/build.py'];
  List<Json> skills = [];
  Json inventory = {'servers': <Object?>[]};
  Json messages = {'data': <Object?>[]};
  Future<Json> Function(String, CancellationToken)? readFiles;
  final searches = <({String query, CancellationToken token})>[];

  @override
  final events = StreamController<Json>.broadcast();

  @override
  Future<Json> searchFiles(String cwd, String query, {required CancellationToken cancellation}) async {
    searches.add((query: query, token: cancellation));
    return readFiles != null ? readFiles!(query, cancellation) : {'paths': paths, 'truncated': false};
  }

  @override
  Future<Json> searchSkills(String cwd, String query, {String? provider, required CancellationToken cancellation}) async =>
    {'skills': skills, 'truncated': false};

  @override
  Future<Json> mcpInventory({bool verbose = false, String? server, String? cwd, required CancellationToken cancellation}) async => inventory;

  @override
  Future<Json> sessionRead(String method, Json params, {required CancellationToken cancellation}) async => messages;
}

class _Session extends Fake implements DesktopSession {
  List<Json> choices = [];
  String? selectedModel, selectedReasoning;
  @override
  DesktopTask? task;
  @override
  Project? project;
  @override
  final projects = <Project>[];
  @override
  List<Json> get models => choices;
  @override
  Json? get modelInfo => choices.firstOrNull;
  @override
  Json? modelFor(DesktopTask? target) => modelInfo;
  @override
  void chooseModel(String id) => selectedModel = id;
  @override
  void chooseReasoning(String level, {DesktopTask? target}) => selectedReasoning = level;
}

typedef _Composer = ({ComposerTextController text, FocusNode focus, CodeLineEditingController code,
  GlobalKey<ComposerAutocompleteState> autocomplete, ValueNotifier<int> submissions, _Client client});

Future<_Composer> _open(WidgetTester tester, {_Client? client, DesktopSession? session, String text = '', bool enabled = true}) async {
  final backend = client ?? _Client(), controller = ComposerTextController(text: text);
  controller.selection = TextSelection.collapsed(offset: text.length);
  final focus = FocusNode(), autocomplete = GlobalKey<ComposerAutocompleteState>(), submissions = ValueNotifier(0);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: Align(alignment: Alignment.bottomCenter,
    child: Padding(padding: const EdgeInsets.all(24), child: SizedBox(width: 600,
      child: CallbackShortcuts(bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): () => submissions.value++,
      }, child: ComposerAutocomplete(key: autocomplete, controller: controller, focusNode: focus,
        client: backend, cwd: '/project', enabled: enabled, session: session,
        child: ComposerEditor(controller: controller, focusNode: focus, enabled: enabled,
          paste: (_) async {}, copy: ({bool cut = false}) async {}),
      )),
    )),
  ))));
  await tester.pump();
  focus.requestFocus();
  await tester.pump();
  final code = tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!;
  addTearDown(() async {
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    focus.dispose();
    submissions.dispose();
    await backend.events.close();
  });
  return (text: controller, focus: focus, code: code, autocomplete: autocomplete, submissions: submissions, client: backend);
}

Future<void> _type(WidgetTester tester, _Composer composer, String text) async {
  composer.code.edit(TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length)));
  await tester.pump(const Duration(milliseconds: 220));
  await tester.pump();
  await tester.pump();
}

String _selected(WidgetTester tester) {
  final row = find.byWidgetPredicate((widget) => widget is Semantics && widget.properties.selected == true && widget.properties.button == true);
  return tester.widget<Text>(find.descendant(of: row, matching: find.byWidgetPredicate((widget) => widget is Text && widget.textSpan != null)).first).textSpan!.toPlainText();
}

void _testComposer(String description, WidgetTesterCallback body, {TargetPlatformVariant? variant}) {
  testWidgets(description, (tester) async {
    try { await body(tester); }
    finally {
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 150));
    }
  }, variant: variant ?? TargetPlatformVariant.desktop());
}

void main() {
  _testComposer('macOS triple-click selects a wrapped paragraph including its newline', (tester) async {
    const paragraph = 'Triple clicks should select this whole paragraph even when it wraps onto several visual lines. '
      'More text keeps it longer than the editor width.';
    final composer = await _open(tester, text: 'Before.\n$paragraph\nAfter.');
    final position = tester.getTopLeft(find.byType(CodeEditor)) + const Offset(90, 50);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    var timestamp = Duration.zero;
    Future<void> click() async {
      await mouse.down(position, timeStamp: timestamp);
      await mouse.up(timeStamp: timestamp + const Duration(milliseconds: 10));
      await tester.pump(const Duration(milliseconds: 20));
      timestamp += const Duration(milliseconds: 200);
    }
    await click();
    expect(composer.text.selection.isCollapsed, isTrue);
    await click();
    expect(composer.text.selection.isCollapsed, isFalse);
    expect(composer.code.selectedText.length, lessThan(paragraph.length));
    await click();
    final selection = TextSelection(baseOffset: 8, extentOffset: 8 + paragraph.length + 1);
    expect(composer.text.selection, selection);
    expect(composer.code.selectedText, '$paragraph\n');
    await click();
    expect(composer.text.selection, selection);
    timestamp += const Duration(seconds: 1);
    await click();
    expect(composer.text.selection, isNot(selection));
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  _testComposer('word shortcuts use Unicode boundaries for deletion, movement, and selection', (tester) async {
    final composer = await _open(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    try {
      for (final (prefix, word) in [
        ('первое второе ', 'слово'),
        ('first ', 'word'),
        ('πρώτη ', 'λέξη'),
        ('أول ', 'كلمة'),
        ('ראשון ', 'מילה'),
        ('पहला ', 'शब्द'),
        ('প্রথম ', 'শব্দ'),
        ('你好世', '界'),
        ('日本', '語'),
        ('첫째 ', '단어'),
        ('แรก ', 'ภาษา'),
        ('first ', 'cafe\u0301'),
        ('first ', '👩🏽‍💻'),
      ]) {
        final text = '$prefix$word tail', end = prefix.length + word.length;
        composer.text.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: end));
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
        expect(composer.text.text, '${prefix} tail', reason: 'Backward deletion: $word');
        composer.code.undo();
        expect(composer.text.text, text, reason: 'Undo: $word');

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        expect(composer.text.selection, TextSelection.collapsed(offset: prefix.length), reason: 'Move left: $word');
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        expect(composer.text.selection, TextSelection(baseOffset: prefix.length, extentOffset: end), reason: 'Select right: $word');
        await tester.sendKeyEvent(LogicalKeyboardKey.delete);
        expect(composer.text.text, '${prefix} tail', reason: 'Selected deletion: $word');
        composer.code.undo();

        composer.text.selection = TextSelection.collapsed(offset: prefix.length);
        await tester.sendKeyEvent(LogicalKeyboardKey.delete);
        expect(composer.text.text, '${prefix} tail', reason: 'Forward deletion: $word');
        composer.code.undo();
        composer.text.selection = TextSelection.collapsed(offset: prefix.length);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        expect(composer.text.selection, TextSelection.collapsed(offset: end), reason: 'Move right: $word');
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        expect(composer.text.selection, TextSelection(baseOffset: end, extentOffset: prefix.length), reason: 'Select left: $word');
      }
    } finally { await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft); }
    expect(tester.takeException(), isNull);
  });

  _testComposer('Up/Down wraps suggestions, scrolls their highlight, and leaves the caret in place', (tester) async {
    final client = _Client()..paths = [for (var i = 0; i < 24; i++) 'lib/file$i.dart'];
    final composer = await _open(tester, client: client);
    await _type(tester, composer, '@');
    final caret = composer.text.selection;
    expect(_selected(tester), 'file0.dart');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(_selected(tester), 'file23.dart');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(_selected(tester), 'file0.dart');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(_selected(tester), 'file1.dart');
    expect(composer.text.selection, caret);
    expect(composer.submissions.value, 0);
    expect(tester.takeException(), isNull);
  });

  _testComposer('Enter and Tab complete references, and the same trigger works again after completion', (tester) async {
    final composer = await _open(tester);
    for (final key in [LogicalKeyboardKey.enter, LogicalKeyboardKey.tab, LogicalKeyboardKey.enter]) {
      await _type(tester, composer, '@');
      expect(find.text('Add context'), findsOneWidget);
      await tester.sendKeyEvent(key);
      await tester.pump();
      expect(composer.submissions.value, 0, reason: 'Completion must consume $key');
      expect(composer.text.files, hasLength(1), reason: 'Completion must insert a reference for $key; draft=${composer.text.text} focus=${composer.focus.hasFocus}');
      expect(composer.text.files.single.path, 'lib/main.dart');
      expect(composer.text.serializePrompt(), '[main.dart](lib/main.dart) ');
      expect(find.text('Add context'), findsNothing);
      expect(composer.submissions.value, 0);
      await _type(tester, composer, '');
    }
    expect(tester.takeException(), isNull);
  });

  _testComposer('Tab browses directories while Enter inserts them as references', (tester) async {
    final client = _Client();
    final composer = await _open(tester, client: client);
    for (final (input, directory, quoted) in [
      ('li', 'lib/', false),
      ('docs', 'My Docs/', true),
      ('"My D"', 'My Docs/', true),
    ]) {
      client.readFiles = (query, _) async => {
        'paths': [query == directory ? '${directory}src/' :
          query == '${directory}src/' ? '${directory}src/main.dart' : directory],
        'truncated': false,
      };
      Future<void> start() async {
        composer.text.value = TextEditingValue(text: 'See @$input after',
          selection: TextSelection.collapsed(offset: 5 + input.length - (input.endsWith('"') ? 1 : 0)));
        await tester.pump(const Duration(milliseconds: 220));
        await tester.pump();
        await tester.pump();
      }
      await start();
      for (final path in [directory, '${directory}src/']) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump(const Duration(milliseconds: 220));
        await tester.pump();
        await tester.pump();
        expect(composer.text.text, 'See @${quoted ? '"$path"' : path} after');
        expect(composer.text.selection, TextSelection.collapsed(offset: 5 + path.length + (quoted ? 1 : 0)));
        expect(composer.text.files, isEmpty);
        expect(find.text('Add context'), findsOneWidget);
        expect(_selected(tester), path == directory ? 'src' : 'main.dart');
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(composer.text.files.single.path, '${directory}src/main.dart');
      expect(composer.text.serializePrompt(), 'See [main.dart](${directory}src/main.dart) after');
      expect(find.text('Add context'), findsNothing);

      await start();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(composer.text.files.single.path, directory);
      expect(find.text('Add context'), findsNothing);
      expect(composer.submissions.value, 0);
    }
    expect(tester.takeException(), isNull);
  });

  _testComposer('reference navigation and deletion are atomic and undo/redo retain their paths', (tester) async {
    final composer = await _open(tester);
    await _type(tester, composer, '@');
    composer.code.clearHistory();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    composer.code.undo();
    expect(composer.text.text, '@');
    expect(composer.text.files, isEmpty);
    composer.code.redo();
    await tester.pump();
    expect(composer.text.files.single.path, 'lib/main.dart');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    expect(composer.text.selection.extentOffset, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    expect(composer.text.selection.extentOffset, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(composer.text.selection.extentOffset, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    expect(composer.text.text, ' ');
    expect(composer.text.files, isEmpty);
    composer.code.undo();
    expect(composer.text.serializePrompt(), '[main.dart](lib/main.dart) ');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    try {
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      expect(composer.text.text, ' ');
      expect(composer.text.files, isEmpty);
      composer.code.undo();
      expect(composer.text.serializePrompt(), '[main.dart](lib/main.dart) ');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(composer.text.selection.extentOffset, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(composer.text.selection.extentOffset, 1);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(composer.text.selection, const TextSelection(baseOffset: 1, extentOffset: 0));
    } finally { await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft); }
    expect(tester.takeException(), isNull);
  });

  _testComposer('Escape closes completion and arrows resume normal multiline editing', (tester) async {
    final composer = await _open(tester);
    await _type(tester, composer, '@');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('Add context'), findsNothing);
    composer.text.value = const TextEditingValue(text: 'first\nsecond', selection: TextSelection.collapsed(offset: 2));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(composer.code.selection.extentIndex, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(composer.code.selection.extentIndex, 0);
    expect(composer.submissions.value, 0);
    expect(tester.takeException(), isNull);
  });

  _testComposer('new queries and dismissal cancel searches and reject late results', (tester) async {
    final first = Completer<Json>(), second = Completer<Json>();
    final client = _Client()..readFiles = (query, _) => query == 'old' ? first.future : second.future;
    final composer = await _open(tester, client: client);
    await _type(tester, composer, '@old');
    await _type(tester, composer, '@new');
    expect(client.searches.first.token.isCancelled, isTrue);
    second.complete({'paths': ['new.dart']});
    await tester.pump();
    first.complete({'paths': ['old.dart']});
    await tester.pump();
    expect(_selected(tester), 'new.dart');
    final pending = Completer<Json>();
    client.readFiles = (_, _) => pending.future;
    await _type(tester, composer, '@pending');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(client.searches.last.token.isCancelled, isTrue);
    pending.complete({'paths': ['late.dart']});
    await tester.pump();
    expect(find.text('Add context'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  _testComposer('skill completion and language icons use real suggestions and preserve metadata', (tester) async {
    final client = _Client()..skills = [{'name': 'dart', 'path': '/skills/dart/SKILL.md', 'description': 'Dart and Flutter', 'scope': 'global'}];
    final composer = await _open(tester, client: client);
    await _type(tester, composer, r'$dart');
    expect(_selected(tester), r'$dart');
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(composer.text.files.single.skillName, 'dart');
    expect(composer.text.serializePrompt(), r'[$dart](/skills/dart/SKILL.md) ');
    await _type(tester, composer, '');
    await _type(tester, composer, '@');
    expect(find.byType(FileIcon), findsNWidgets(3));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  });

  _testComposer('MCP tool and resource context completion serialize usable references', (tester) async {
    final client = _Client()..paths = []..inventory = {'servers': [{
      'name': 'docs', 'tools': ['search_docs'], 'resources': [{'uri': 'docs://guide', 'name': 'Guide'}],
    }]};
    final composer = await _open(tester, client: client);
    await _type(tester, composer, '@search_docs');
    expect(_selected(tester), 'search_docs');
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(composer.text.serializePrompt(), '`search_docs` ');
    await _type(tester, composer, '');
    await _type(tester, composer, '@Guide');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(composer.text.files.single.path, 'docs://guide');
    expect(composer.text.serializePrompt(), '[docs:Guide](docs://guide) ');
    expect(composer.submissions.value, 0);
  });

  _testComposer('session context includes user and assistant text from the current message schema', (tester) async {
    final current = DesktopTask('current', 'Current'), other = DesktopTask('other', 'Planning');
    final session = _Session()..task = current..project = Project('project', 'project', '/project', [current, other]);
    final client = _Client()..paths = []..messages = {'data': [
      {'type': 'user', 'text': 'Plan the release'},
      {'type': 'assistant', 'content': [{'type': 'text', 'text': 'Ship on Monday'}]},
      {'type': 'system', 'text': 'Private instructions'},
    ]};
    final composer = await _open(tester, client: client, session: session);
    await _type(tester, composer, '@Planning');
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(composer.text.files.single.path, 'session:other');
    final prompt = composer.text.serializePrompt();
    expect(prompt, contains('User:\nPlan the release'));
    expect(prompt, contains('Assistant:\nShip on Monday'));
    expect(prompt, isNot(contains('Private instructions')));
    composer.code.undo();
    composer.code.redo();
    expect(composer.text.serializePrompt(), prompt);
    expect(composer.text.files.single.title, 'Planning');
  });

  _testComposer('Shift+Up selects text and prompt history remains available explicitly', (tester) async {
    final task = DesktopTask('current', 'Current')..messages.addAll({
      'one': {'type': 'userMessage', 'content': [{'type': 'text', 'text': 'First prompt'}]},
      'two': {'type': 'userMessage', 'content': [{'type': 'text', 'text': 'Second prompt'}]},
    });
    final composer = await _open(tester, session: _Session()..task = task, text: 'Unsent draft');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    await tester.pump();
    expect(find.text('Prompt history'), findsNothing);
    expect(composer.text.selection, const TextSelection(baseOffset: 12, extentOffset: 0));
    expect(composer.text.text, 'Unsent draft');
    composer.autocomplete.currentState!.openHistory();
    await tester.pump();
    await tester.pump();
    expect(find.text('Prompt history'), findsOneWidget);
    expect(_selected(tester), 'Second prompt');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(_selected(tester), 'First prompt');
    expect(composer.text.text, 'Unsent draft');
    await tester.enterText(find.byType(TextField), 'First');
    await tester.pump();
    expect(_selected(tester), 'First prompt');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(composer.text.text, 'First prompt');
    expect(composer.focus.hasFocus, isTrue);
    expect(composer.submissions.value, 0);
  });

  _testComposer('large drafts keep a bounded viewport and retain text across editing and undo', (tester) async {
    final draft = List.filled(20000, 'A long draft keeps every line available for editing.').join('\n');
    final composer = await _open(tester, text: draft);
    final elapsed = Stopwatch()..start();
    await tester.pump();
    composer.code.clearHistory();
    composer.code.replaceSelection(' Last edit.');
    await tester.pump();
    expect(composer.text.text, '$draft Last edit.');
    expect(tester.getSize(find.byType(CodeEditor)).height, lessThanOrEqualTo(180));
    composer.code.undo();
    await tester.pump();
    expect(composer.text.text, draft);
    expect(composer.code.codeLines.length, 20000);
    expect(tester.takeException(), isNull);
    debugPrint('Offscreen ${draft.length}-character draft edit + undo: ${elapsed.elapsedMilliseconds}ms');
  });

  _testComposer('an empty result set consumes arrows and Enter without moving the caret or sending', (tester) async {
    final composer = await _open(tester, client: _Client()..paths = []);
    await _type(tester, composer, '@missing');
    final selection = composer.text.selection;
    expect(find.text('No matching items'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(composer.text.selection, selection);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(composer.submissions.value, 0);
    expect(composer.text.text, '@missing');
    expect(find.text('Add context'), findsNothing);
  });

  _testComposer('slash model and reasoning completion executes locally and preserves the surrounding draft', (tester) async {
    final session = _Session()..choices = [{
      'id': 'gpt-6', 'provider': 'openai', 'reasoning_levels': ['low', 'high'],
    }];
    final composer = await _open(tester, session: session);
    await _type(tester, composer, 'Use /model gpt');
    expect(_selected(tester), '/model gpt-6');
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(session.selectedModel, 'gpt-6');
    expect(composer.text.text, 'Use ');
    await _type(tester, composer, '/reasoning high');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(session.selectedReasoning, 'high');
    expect(composer.submissions.value, 0);
  });

  _testComposer('quoted paths complete by mouse without losing focus and replacement actions reach the editor', (tester) async {
    final composer = await _open(tester, client: _Client()..paths = ['notes/my file.md']);
    await _type(tester, composer, '@"my file');
    expect(composer.client.searches.last.query, 'my file');
    await tester.tap(find.text('my file.md', findRichText: true));
    await tester.pump();
    expect(composer.focus.hasFocus, isTrue);
    expect(composer.text.files.single.path, 'notes/my file.md');
    final before = composer.text.value;
    Actions.invoke(composer.focus.context!, ReplaceTextIntent(before, 'pasted or dictated',
      before.selection, SelectionChangedCause.keyboard));
    await tester.pump();
    expect(composer.text.serializePrompt(), '[my file.md](notes/my file.md) pasted or dictated');
    expect(composer.code.text, '@my file.md pasted or dictated');
  });

  _testComposer('long Unicode paragraphs stay editable without truncating the draft', (tester) async {
    final draft = List.filled(20000, 'words 🌍 ').join();
    final composer = await _open(tester, text: draft);
    composer.code.clearHistory();
    composer.code.replaceSelection('Ending');
    await tester.pump();
    expect(composer.text.text, '${draft}Ending');
    expect(composer.code.codeLines.length, 1);
    expect(tester.getSize(find.byType(CodeEditor)).height, lessThanOrEqualTo(180));
    composer.code.undo();
    await tester.pump();
    expect(composer.text.text, draft);
    expect(tester.takeException(), isNull);
  });

  _testComposer('IME composition owns arrow keys and completion stays closed until text is committed', (tester) async {
    final composer = await _open(tester);
    composer.code.edit(const TextEditingValue(text: '@日本', selection: TextSelection.collapsed(offset: 3),
      composing: TextRange(start: 1, end: 3)));
    await tester.pump();
    final before = composer.text.value;
    expect(composer.code.isComposing, isTrue);
    expect(find.text('Add context'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    expect(composer.text.value, before);
    composer.code.composing = TextRange.empty;
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pump();
    await tester.pump();
    expect(find.text('Add context'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  _testComposer('disabled editors retain their draft when deletion and indent shortcuts are pressed', (tester) async {
    final composer = await _open(tester, text: 'Keep this draft', enabled: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    expect(composer.text.text, 'Keep this draft');
    expect(tester.takeException(), isNull);
  });

  test('file icons cover languages, special files, compound extensions, and named folders', () {
    expect(fileIconName('lib/main.dart'), 'dart');
    expect(fileIconName('index.tsx'), 'react_ts');
    expect(fileIconName('Dockerfile'), 'docker');
    expect(fileIconName('package.json'), 'nodejs');
    expect(fileIconName('src/'), 'folder-src');
    expect(fileIconName('src/', expanded: true), 'folder-src-open');
    expect(fileIconName('unknown.custom'), 'document');
  });
}
