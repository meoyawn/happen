import 'package:desktop/conversation.dart';
import 'package:desktop/conversation_annotations.dart';
import 'package:desktop/conversation_markdown.dart';
import 'package:desktop/response_annotation.dart';
import 'package:desktop/response_annotation_reference.dart';
import 'package:desktop/session.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final (gesture, text, start, end) in [
    ('drag', 'Explain this choice.', 0, 20),
    ('double click', 'this', 8, 12),
    ('triple click', 'Explain this choice.', 0, 20),
  ]) {
    testWidgets('$gesture shows response actions on the next frame with the rendered text and source range', (tester) async {
      ResponseAnnotation? selected;
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Align(alignment: Alignment.topLeft,
        child: SizedBox(width: 500, child: ConversationAnnotationSelection(onAdd: (annotation, _) => selected = annotation,
          child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
            ConversationAnnotationTarget(messageId: 'response', child: ConversationMarkdown(
              text: 'Explain **this** `choice`.', directory: '')),
            const ConversationAnnotationTarget(messageId: 'another-response', child: Text('A separate response.')),
          ]))))))));
      await tester.pumpAndSettle();
      final paragraph = tester.renderObject<RenderParagraph>(find.byWidgetPredicate((widget) =>
        widget is RichText && widget.text.toPlainText() == 'Explain this choice.'));
      final box = paragraph.getBoxesForSelection(const TextSelection(baseOffset: 8, extentOffset: 12)).first.toRect();
      if (gesture == 'drag') {
        final boxes = paragraph.getBoxesForSelection(const TextSelection(baseOffset: 0, extentOffset: 20));
        final pointer = await tester.startGesture(paragraph.localToGlobal(boxes.first.toRect().centerLeft), kind: PointerDeviceKind.mouse);
        await pointer.moveTo(paragraph.localToGlobal(boxes.last.toRect().centerRight));
        await tester.pump();
        expect(find.text('Copy'), findsNothing, reason: 'Actions wait until the selection gesture finishes');
        await pointer.up();
      } else {
        final clicks = gesture == 'double click' ? 2 : 3;
        for (var click = 0; click < clicks; click++) {
          await tester.tapAt(paragraph.localToGlobal(box.center), kind: PointerDeviceKind.mouse);
          if (click < clicks - 1) await tester.pump(const Duration(milliseconds: 75));
        }
      }
      await tester.pump();
      expect(find.text('Add to chat'), findsOneWidget, reason: 'A finished selection must render actions on the next frame');
      expect(find.text('Copy'), findsOneWidget);
      await tester.tap(find.text('Add to chat'));
      await tester.pumpAndSettle();
      expect(selected?.text, text);
      expect(selected?.messageId, 'response');
      expect(selected?.startOffset, start);
      expect(selected?.endOffset, end);

      final region = tester.state<SelectableRegionState>(find.byType(SelectableRegion));
      region.selectAll(SelectionChangedCause.keyboard);
      await tester.pumpAndSettle();
      expect(find.text('Add to chat'), findsNothing, reason: 'A selection spanning responses has no single source');
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  }

  testWidgets('triple click selects a paragraph while a scrolled-away message is kept alive', (tester) async {
    final task = DesktopTask('selection-scroll', 'Selection')..loaded = true;
    addTearDown(task.liveText.dispose);
    for (var index = 0; index < 40; index++) {
      task.messages['question-$index'] = {'id': 'question-$index', 'type': 'userMessage', 'order': index * 2,
        'content': [{'type': 'text', 'text': 'Question $index'}]};
      task.messages['answer-$index'] = {'id': 'answer-$index', 'type': 'agentMessage', 'order': index * 2 + 1,
        'phase': 'final_answer', 'text': 'Paragraph $index has **formatted text** and `inline code` to select.'};
    }
    ResponseAnnotation? selected;
    final changes = ChangeNotifier();
    addTearDown(changes.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ConversationAnnotationScope(
      onAdd: (annotation, _) => selected = annotation, onEdit: (_) {},
      readAnnotations: () => const [], changes: changes, enabled: true,
      child: ConversationTranscript(task: task, directory: '', onRetry: () {})))));
    await tester.pumpAndSettle();
    final viewport = tester.getRect(find.byType(ConversationTranscript));
    await tester.sendEventToBinding(PointerScrollEvent(position: viewport.center, scrollDelta: const Offset(0, -2400)));
    await tester.pumpAndSettle();
    final paragraphs = find.byWidgetPredicate((widget) => widget is RichText && widget.text.toPlainText().startsWith('Paragraph '));
    final first = tester.renderObjectList<RenderParagraph>(paragraphs)
      .firstWhere((paragraph) => viewport.deflate(30).contains(paragraph.localToGlobal(const Offset(20, 10))));
    final firstText = first.text.toPlainText();
    Offset point(RenderParagraph paragraph) => paragraph.localToGlobal(paragraph.getBoxesForSelection(
      const TextSelection(baseOffset: 0, extentOffset: 9)).first.toRect().center);
    for (var click = 0; click < 3; click++) {
      await tester.tapAt(point(first), kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 75));
    }
    expect(find.text('Add to chat'), findsOneWidget);
    // Active message controls can keep their row mounted outside the cache.
    final retention = KeepAliveHandle();
    addTearDown(retention.dispose);
    KeepAliveNotification(retention).dispatch(tester.element(find.byWidgetPredicate((widget) =>
      widget is RichText && widget.text.toPlainText() == firstText)));
    await tester.pump();
    await tester.sendEventToBinding(PointerScrollEvent(position: tester.getCenter(find.byType(CustomScrollView)),
      scrollDelta: const Offset(0, 2400)));
    await tester.pumpAndSettle();
    expect(first.localToGlobal(Offset.zero).isFinite, isTrue,
      reason: 'Retained text stays registered for selection and must have valid screen coordinates');
    final next = tester.renderObjectList<RenderParagraph>(paragraphs)
      .lastWhere((paragraph) => viewport.deflate(30).contains(paragraph.localToGlobal(const Offset(20, 10))));
    final text = next.text.toPlainText();
    expect(text, isNot(firstText));
    for (var click = 0; click < 3; click++) {
      await tester.tapAt(point(next), kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 75));
    }
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Add to chat'));
    await tester.pumpAndSettle();
    expect(selected?.text, text);
    expect(selected?.messageId, startsWith('answer-'));
    expect(selected?.startOffset, 0);
    expect(selected?.endOffset, text.length);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('sent browser and response comments stay readable and resolve inline references', (tester) async {
    const response = ResponseAnnotation(id: 'draft-response', text: 'Original response', annotation: 'Explain the choice',
      messageId: 'assistant', startOffset: 0, endOffset: 17);
    final browser = ResponseAnnotation(id: 'draft-browser', text: 'Submit', annotation: 'Use a clearer label',
      browser: BrowserAnnotation({'kind': 'element', 'pageUrl': 'http://localhost:3000', 'selector': '#submit',
        'name': 'Submit', 'selectionSerial': 12}));
    final task = DesktopTask('annotations', 'Annotations')..loaded = true;
    task.messages.addAll({
      'user': {'id': 'user', 'type': 'userMessage', 'order': 0, 'content': [
        {'type': 'text', 'text': promptWithResponseAnnotations('Update both', [response, browser])},
      ]},
      'assistant': {'id': 'assistant', 'type': 'agentMessage', 'order': 1,
        'text': 'Here is the explanation :codex-annotation{index="1"}. Updated the button :codex-annotation{index="2"}.'},
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ConversationTranscript(task: task, directory: '', onRetry: () {}))));
    await tester.pumpAndSettle();
    expect(find.text('Update both', findRichText: true), findsOneWidget);
    expect(find.text('Original response'), findsOneWidget);
    expect(find.text('Use a clearer label'), findsOneWidget);
    expect(find.text('Annotation 1'), findsOneWidget);
    expect(find.text('Annotation 2'), findsOneWidget);
    expect(find.textContaining('<response-annotations>'), findsNothing);
    await tester.tap(find.text('Annotation 2'));
    await tester.pumpAndSettle();
    final reference = find.byType(ResponseAnnotationReference).last;
    expect(tester.widget<ResponseAnnotationReference>(reference).annotation.browser!.target['selector'], '#submit');
    expect(tester.widget<ResponseAnnotationReference>(reference).annotation.browser!.target.containsKey('selectionSerial'), isFalse);
    expect(find.text('Use a clearer label'), findsNWidgets(2), reason: 'The inline reference previews its own submitted comment');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
