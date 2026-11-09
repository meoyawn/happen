import 'package:desktop/conversation.dart';
import 'package:desktop/conversation_annotations.dart';
import 'package:desktop/conversation_markdown.dart';
import 'package:desktop/response_annotation.dart';
import 'package:desktop/response_annotation_reference.dart';
import 'package:desktop/session.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('selecting a formatted response adds its rendered text and source range', (tester) async {
    ResponseAnnotation? selected;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Align(alignment: Alignment.topLeft,
      child: SizedBox(width: 500, child: ConversationAnnotationSelection(onAdd: (annotation, _) => selected = annotation,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ConversationAnnotationTarget(messageId: 'response', child: ConversationMarkdown(
            text: 'Explain **this** `choice`.', directory: '')),
          const ConversationAnnotationTarget(messageId: 'another-response', child: Text('A separate response.')),
        ])))))));
    await tester.pumpAndSettle();
    final paragraph = tester.renderObject<RenderParagraph>(find.byWidgetPredicate((widget) =>
      widget is RichText && widget.text.toPlainText() == 'Explain this choice.'));
    final box = paragraph.getBoxesForSelection(const TextSelection(baseOffset: 8, extentOffset: 12)).first.toRect();
    for (var click = 0; click < 3; click++) {
      await tester.tapAt(paragraph.localToGlobal(box.center), kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 75));
    }
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add to chat'));
    await tester.pumpAndSettle();
    expect(selected?.text, 'Explain this choice.');
    expect(selected?.messageId, 'response');
    expect(selected?.startOffset, 0);
    expect(selected?.endOffset, 20);

    final region = tester.state<SelectableRegionState>(find.byType(SelectableRegion));
    region.selectAll(SelectionChangedCause.keyboard);
    await tester.pumpAndSettle();
    expect(find.text('Add to chat'), findsNothing, reason: 'A selection spanning responses has no single source');
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
    expect(find.text('Update both'), findsOneWidget);
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
