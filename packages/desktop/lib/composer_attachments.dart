import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:protocol/protocol.dart';

import 'conversation_markdown.dart';

class ComposerAttachment {
  ComposerAttachment({required this.name, required this.path, required this.image, this.ownedDirectory}) : id = newId();
  final String id, name, path;
  final bool image;
  final String? ownedDirectory;
  Json toJson() => {'type': image ? 'image' : 'file', 'name': name, 'path': path};

  Future<void> discard() async {
    if (ownedDirectory case final directory?) {
      try { await Directory(directory).delete(recursive: true); } on FileSystemException { /* Already released. */ }
    }
  }
}

String _name(String name) {
  final safe = name.split(RegExp(r'[/\\]')).last.replaceAll(RegExp(r'[\x00-\x1f]'), '').trim();
  return safe.isEmpty || safe == '.' || safe == '..' ? 'Attachment' : safe;
}

bool _isImage(String name, [String? mime]) => mime?.startsWith('image/') == true && mime != 'image/svg+xml' ||
    {'png', 'jpg', 'jpeg', 'gif', 'webp', 'tiff', 'tif', 'bmp', 'ico', 'heic', 'heif'}.contains(name.split('.').last.toLowerCase());

class ComposerClipboardSnapshot {
  const ComposerClipboardSnapshot(this.text, this.attachments);
  final String? text;
  final List<ComposerAttachment> attachments;
}

const composerClipboardChannel = MethodChannel('happen/clipboard');

Future<ComposerClipboardSnapshot> readComposerClipboard(String directory, CancellationToken cancellation) async {
  cancellation.throwIfCancelled();
  // Start both snapshot reads immediately, before a transient pasteboard owner
  // (for example dictation) has time to restore its previous content.
  final fallback = Clipboard.getData(Clipboard.kTextPlain);
  if (!Platform.isMacOS) return ComposerClipboardSnapshot((await fallback)?.text, []);
  final id = newId(), destination = '$directory/${newId()}';
  final hook = CancellationHook(cancellation, () {
    unawaited(composerClipboardChannel.invokeMethod<void>('cancel', {'id': id}).catchError((Object _) {}));
  });
  var retained = false;
  try {
    final raw = await composerClipboardChannel.invokeMapMethod<String, dynamic>('read', {'id': id, 'directory': destination});
    cancellation.throwIfCancelled();
    final text = (await fallback)?.text;
    if (raw == null || text != null && raw.containsKey('text') && text != raw['text']) {
      return ComposerClipboardSnapshot(text, []);
    }
    final attachments = <ComposerAttachment>[
      for (final image in raw['images'] as List? ?? [])
        ComposerAttachment(name: _name(image['name'] as String), path: image['path'] as String, image: true,
          ownedDirectory: File(image['path'] as String).parent.path),
      for (final path in (raw['files'] as List? ?? []).cast<String>())
        ComposerAttachment(name: _name(path), path: path, image: _isImage(path)),
    ];
    retained = attachments.any((attachment) => attachment.ownedDirectory != null);
    return ComposerClipboardSnapshot(text ?? raw['text'] as String?, attachments);
  } on MissingPluginException {
    return ComposerClipboardSnapshot((await fallback)?.text, []);
  } on PlatformException {
    cancellation.throwIfCancelled();
    rethrow;
  } finally {
    hook.dispose();
    if (!retained) {
      try { await Directory(destination).delete(recursive: true); } on FileSystemException { /* No images were written. */ }
    }
  }
}

/// Consume promised/provider files before onDrop returns and the OS releases them.
Future<List<ComposerAttachment>> receiveComposerDrop(DropDetails details, String directory, CancellationToken cancellation) async {
  final result = <ComposerAttachment>[];
  try {
    for (final item in details.items) {
      cancellation.throwIfCancelled();
      if (item is DropDirectoryItem) {
        if (item.localPath == null || item.isPromised) throw StateError('Save this folder locally before attaching it');
        result.add(ComposerAttachment(name: _name(item.name), path: item.localPath!, image: false));
      } else if (item is DropFileItem) {
        final name = _name(item.name);
        var path = item.localPath;
        String? owned;
        final bookmark = item.appleBookmark;
        var accessing = false;
        try {
          if (bookmark != null) accessing = await DesktopDrop.instance.startAccessingSecurityScopedResource(bookmark: bookmark);
          cancellation.throwIfCancelled();
          if (path == null || item.isPromised || accessing || path.startsWith(Directory.systemTemp.path)) {
            owned = '$directory/${newId()}';
            await Directory(owned).create(recursive: true);
            path = '$owned/$name';
            final output = File(path).openWrite();
            final input = ownStream(item.file.openRead(), cancellation);
            try {
              await output.addStream(input.stream);
              cancellation.throwIfCancelled();
            } finally {
              await input.close();
              await output.close();
            }
          }
          cancellation.throwIfCancelled();
          result.add(ComposerAttachment(name: name, path: path, image: _isImage(name, item.mimeType), ownedDirectory: owned));
        } catch (_) {
          if (owned != null) {
            try { await Directory(owned).delete(recursive: true); } on FileSystemException { /* Partial copy. */ }
          }
          rethrow;
        } finally {
          if (accessing) await DesktopDrop.instance.stopAccessingSecurityScopedResource(bookmark: bookmark!);
        }
      }
    }
    return result;
  } catch (_) {
    for (final attachment in result) { await attachment.discard(); }
    rethrow;
  }
}

class ComposerPasteAction extends Action<PasteTextIntent> {
  ComposerPasteAction({required this.enabled, required this.paste});
  final bool enabled;
  final Future<void> Function(SelectionChangedCause) paste;
  @override bool isEnabled(PasteTextIntent intent) => enabled;
  @override void invoke(PasteTextIntent intent) { if (enabled) unawaited(paste(intent.cause)); }
}

Widget composerContextMenu(EditableTextState state, Future<void> Function(SelectionChangedCause) paste) =>
    AdaptiveTextSelectionToolbar.buttonItems(anchors: state.contextMenuAnchors, buttonItems: [
      for (final item in state.contextMenuButtonItems)
        if (item.type != ContextMenuButtonType.paste) item,
      ContextMenuButtonItem(type: ContextMenuButtonType.paste, onPressed: () {
        state.hideToolbar();
        unawaited(paste(SelectionChangedCause.toolbar));
      }),
    ]);

class AttachmentRail extends StatelessWidget {
  const AttachmentRail({super.key, required this.attachments, this.onRemove, this.directory = ''});
  final List<Json> attachments;
  final void Function(int index)? onRemove;
  final String directory;

  @override
  Widget build(BuildContext context) => Wrap(spacing: 8, runSpacing: 8, children: [
    for (var index = 0; index < attachments.length; index++)
      _AttachmentTile(attachment: attachments[index], directory: directory,
        onRemove: onRemove == null ? null : () => onRemove!(index)),
  ]);
}

class _AttachmentTile extends StatelessWidget {
  const _AttachmentTile({required this.attachment, required this.directory, this.onRemove});
  final Json attachment;
  final String directory;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final name = attachment['name'] as String? ?? 'Image';
    final isImage = attachment['type'] == 'image';
    return Tooltip(message: attachment['path'] as String? ?? name, child: Container(
      width: isImage ? 120 : null,
      constraints: const BoxConstraints(maxWidth: 240),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(color: const Color(0xfff4f5f0), borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xffdaddd5))),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (isImage) SizedBox(height: 78, width: 106, child: ConversationImage(
          source: attachment['data'] is String ? attachmentDataUrl(attachment) : attachment['path'] as String,
          label: name, directory: directory, thumbnail: true)),
        Row(mainAxisSize: MainAxisSize.min, children: [
          if (!isImage) const Padding(padding: EdgeInsets.only(right: 6), child: Icon(Icons.insert_drive_file_outlined, size: 16)),
          Flexible(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))),
          if (onRemove != null) IconButton(tooltip: 'Remove $name', onPressed: onRemove,
            constraints: const BoxConstraints.tightFor(width: 24, height: 24), padding: EdgeInsets.zero,
            icon: const Icon(Icons.close, size: 14)),
        ]),
      ]),
    ));
  }
}
