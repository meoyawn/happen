import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:protocol/protocol.dart';

import 'appearance.dart';
import 'conversation_activity.dart';
import 'conversation_data.dart';
import 'conversation_markdown.dart';
import 'conversation_tools.dart' show ConversationWorkIcon;
import 'generated_image_loading.dart';
import 'inspected_image.dart';
import 'session.dart';

/// Match Harness: prefer the saved original and keep binary output out of JSON.
String? generatedImageSource(Json item) {
  final saved = item['savedPath'];
  final raw = saved is String && saved.trim().isNotEmpty ? saved : item['result'];
  if (raw is! String || raw.trim().isEmpty) return null;
  final source = raw.trim();
  if (source.startsWith('/@fs/')) return source.substring(4);
  if (source.startsWith('/') || RegExp(r'^[A-Za-z]:[/\\]').hasMatch(source) ||
      RegExp(r'^(?:file:|data:image/|https?://|app://)', caseSensitive: false).hasMatch(source)) {
    return source;
  }
  return 'data:image/png;base64,$source';
}

String? toolImageSource(Json part) => switch (part) {
  {'type': 'inputImage', 'imageUrl': final String url} => url,
  {'type': 'input_image', 'image_url': final String url} => url,
  {'type': 'image', 'data': final String data, 'mimeType': final String mime} ||
  {'type': 'image', 'data': final String data, 'mime_type': final String mime} => 'data:$mime;base64,$data',
  _ => null,
};

class ConversationGeneratedImages extends StatefulWidget {
  const ConversationGeneratedImages({super.key, required this.items, required this.conversationImages,
    required this.directory, required this.onExpand});
  final List<ChatEntry> items, conversationImages;
  final String directory;
  final VoidCallback onExpand;
  @override
  State<ConversationGeneratedImages> createState() => _ConversationGeneratedImagesState();
}

class _ConversationGeneratedImagesState extends State<ConversationGeneratedImages> {
  String? _selected;
  final _ratios = <String, double>{};

  @override
  Widget build(BuildContext context) {
    final images = [for (final entry in widget.items)
      if (generatedImageSource(entry.image!) case final String source) (id: entry.id, source: source)];
    final pending = widget.items.where((entry) => entry.streaming && generatedImageSource(entry.image!) == null).length;
    final failed = widget.items.where((entry) => entry.image!['status'] == 'failed');
    final selected = images.where((image) => image.id == _selected).firstOrNull ?? images.firstOrNull;
    final previews = [for (final entry in widget.conversationImages)
      if (generatedImageSource(entry.image!) case final String source) (id: entry.id, source: source)];
    return SelectionContainer.disabled(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (selected != null || pending > 0) LayoutBuilder(builder: (context, constraints) {
        final available = constraints.maxWidth.isFinite ? constraints.maxWidth : 480.0;
        if (selected == null) {
          final side = math.min(400.0, math.max(0.0, (available - 24) / 4));
          return Wrap(spacing: 8, runSpacing: 8, children: [for (var i = 0; i < pending; i++)
            SizedBox.square(dimension: side, child: const GeneratedImageLoading())]);
        }
        final ratio = _ratios[selected.id] ?? 1;
        final thumbnails = images.length + pending > 1;
        final maximum = ratio >= 2 ? available : ratio >= 1 ? 480.0 : 400.0;
        final width = math.min(maximum, math.max(0.0, available - (thumbnails ? 72 : 0)));
        if (width == 0) return const SizedBox.shrink();
        final height = width / ratio;
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: width, height: height, child: ConversationImage(
            key: ValueKey(selected.id), source: selected.source, label: 'Generated image', directory: widget.directory,
            borderRadius: 16, maxHeight: height, previewImages: previews, previewID: selected.id,
            onPreview: widget.onExpand,
            onPreviewChanged: (id) {
              final image = images.where((image) => image.id == id).firstOrNull;
              if (mounted && image != null) setState(() => _selected = image.id);
            },
            onAspectRatio: (ratio) {
              if (mounted && _ratios[selected.id] != ratio) setState(() => _ratios[selected.id] = ratio);
            })),
          if (thumbnails) ...[
            const SizedBox(width: 8),
            ConstrainedBox(constraints: BoxConstraints(maxHeight: height), child: SingleChildScrollView(
              child: Padding(padding: const EdgeInsets.all(2), child: Column(mainAxisSize: MainAxisSize.min, children: [
                for (final image in images) Padding(padding: const EdgeInsets.only(bottom: 8),
                  child: Semantics(label: 'Show generated image ${images.indexOf(image) + 1}', selected: image.id == selected.id,
                    child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () {
                      widget.onExpand();
                      setState(() => _selected = image.id);
                    }, child: DecoratedBox(position: DecorationPosition.foreground,
                      decoration: BoxDecoration(borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: image.id == selected.id ? desktopForeground : desktopBorder,
                          width: image.id == selected.id ? 2 : 1)),
                      child: SizedBox.square(dimension: 56, child: ClipRRect(borderRadius: BorderRadius.circular(8),
                        child: IgnorePointer(child: ConversationImage(source: image.source, label: 'Generated image thumbnail',
                          directory: widget.directory, thumbnail: true)))))))),
                for (var i = 0; i < pending; i++) const Padding(padding: EdgeInsets.only(bottom: 8),
                  child: SizedBox.square(dimension: 56, child: GeneratedImageLoading(animate: false, thumbnail: true))),
              ])),
            )),
          ],
        ]);
      }),
      for (final entry in failed) Padding(padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(switch (entry.image!['failure']) {
          final String message => message,
          {'message': final String message} => message,
          _ => 'Image generation failed',
        },
          style: const TextStyle(fontSize: 14, color: desktopError))),
    ]));
  }
}

class ConversationInspectedImages extends StatelessWidget {
  const ConversationInspectedImages({super.key, required this.tools, required this.directory, required this.onExpand});
  final List<ToolActivity> tools;
  final String directory;
  final VoidCallback onExpand;
  @override
  Widget build(BuildContext context) {
    final images = [for (final tool in tools)
      if (tool.rawInput case {'path': final String path} when path.isNotEmpty) (tool: tool, path: path)];
    final client = context.dependOnInheritedWidgetOfExactType<ConversationDataScope>()?.client;
    final label = tools.length == 1 ? 'Viewed an image' : 'Viewed ${tools.length} images';
    return ConversationDisclosure(key: PageStorageKey('image-view:${tools.first.id}'), label: label,
      icon: const ConversationWorkIcon(kind: 'image'), onExpand: onExpand,
      builder: (context) => Padding(padding: const EdgeInsets.only(left: 30, top: 8, bottom: 4),
        child: ConversationImageGroup(child: SingleChildScrollView(scrollDirection: Axis.horizontal,
          child: Row(spacing: 8, children: [for (final image in images)
            ConversationImage(source: image.path, label: 'Inspected image', directory: directory, thumbnail: true,
              provider: client != null && image.tool.threadId != null
                ? InspectedImage(client, image.tool.threadId!, image.tool.id) : null)])))));
  }
}
