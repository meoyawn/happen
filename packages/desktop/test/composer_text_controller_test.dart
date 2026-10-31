import 'package:desktop/composer_text_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('references serialize their paths, survive edits and disappear on deletion', () {
    final controller = ComposerTextController(text: 'Check @file afterwards');
    addTearDown(controller.dispose);
    controller.insertFile(const TextRange(start: 6, end: 11), 'notes/my [file](v2).md');
    expect(controller.text, 'Check \uFFFC afterwards');
    expect(controller.selection.extentOffset, 8);
    expect(controller.serializePrompt(), r'Check [my \[file\]\(v2).md](notes/my [file](v2\).md) afterwards');
    controller.value = TextEditingValue(text: 'Please ${controller.text}', selection: const TextSelection.collapsed(offset: 7));
    expect(controller.files.single.offset, 13);
    controller.value = TextEditingValue(text: controller.text.replaceRange(13, 14, ''),
      selection: const TextSelection.collapsed(offset: 13));
    expect(controller.files, isEmpty);
    expect(controller.serializePrompt(), 'Please Check  afterwards');
  });

  test('deleting either of two adjacent references preserves the other identity', () {
    for (final selection in [
      const TextSelection(baseOffset: 0, extentOffset: 1),
      const TextSelection.collapsed(offset: 1),
      const TextSelection.collapsed(offset: 0),
    ]) {
      final controller = ComposerTextController(text: '\uFFFC\uFFFC', files: const [
        ComposerFileReference(0, 'first.dart'), ComposerFileReference(1, 'second.dart'),
      ])..selection = selection;
      controller.value = const TextEditingValue(text: '\uFFFC', selection: TextSelection.collapsed(offset: 0));
      expect(controller.serializePrompt(), '[second.dart](second.dart)');
      controller.dispose();
    }
    for (final selection in [
      const TextSelection(baseOffset: 1, extentOffset: 2),
      const TextSelection.collapsed(offset: 2),
      const TextSelection.collapsed(offset: 1),
    ]) {
      final controller = ComposerTextController(text: '\uFFFC\uFFFC', files: const [
        ComposerFileReference(0, 'first.dart'), ComposerFileReference(1, 'second.dart'),
      ])..selection = selection;
      controller.value = const TextEditingValue(text: '\uFFFC', selection: TextSelection.collapsed(offset: 1));
      expect(controller.serializePrompt(), '[first.dart](first.dart)');
      controller.dispose();
    }
  });

  test('restored drafts keep reference identity and full replacement clears it', () {
    final original = ComposerTextController(text: 'Use @folder');
    addTearDown(original.dispose);
    original.insertFile(const TextRange(start: 4, end: 11), 'packages/desktop/');
    final restored = ComposerTextController(text: original.text, files: original.files);
    addTearDown(restored.dispose);
    expect(restored.files.single.folder, true);
    expect(restored.files.single.label, 'desktop');
    expect(restored.serializePrompt(), 'Use [desktop](packages/desktop/) ');
    expect(restored.serializeRange(4, 5), '[desktop](packages/desktop/)');
    restored.text = 'Replacement';
    expect(restored.files, isEmpty);
    expect(restored.serializePrompt(), 'Replacement');
  });
}
