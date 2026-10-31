import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import 'code_highlight.dart';

const conversationInk = Color(0xff242b29);
const conversationMuted = Color(0xff737c77);
const conversationBorder = Color(0xffe2e6df);

class ConversationMarkdown extends StatelessWidget {
  const ConversationMarkdown({super.key, required this.text, required this.directory, this.fitContent = false});
  final String text, directory;
  final bool fitContent;

  @override
  Widget build(BuildContext context) {
    const body = TextStyle(fontSize: 15, height: 1.65, color: conversationInk);
    return SelectionArea(
      child: MarkdownBody(
        data: text,
        extensionSet: md.ExtensionSet.gitHubFlavored,
        fitContent: fitContent,
        softLineBreak: fitContent,
        styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
          p: body,
          a: body.copyWith(color: const Color(0xff16796c), decoration: TextDecoration.underline),
          h1: body.copyWith(fontSize: 26, height: 1.3, fontWeight: FontWeight.w600),
          h2: body.copyWith(fontSize: 22, height: 1.35, fontWeight: FontWeight.w600),
          h3: body.copyWith(fontSize: 18, height: 1.4, fontWeight: FontWeight.w600),
          h4: body.copyWith(fontWeight: FontWeight.w600),
          h5: body.copyWith(fontWeight: FontWeight.w600),
          h6: body.copyWith(fontWeight: FontWeight.w600, color: conversationMuted),
          h1Padding: const EdgeInsets.only(top: 8, bottom: 8),
          h2Padding: const EdgeInsets.only(top: 8, bottom: 4),
          h3Padding: const EdgeInsets.only(top: 6),
          code: const TextStyle(fontFamily: 'monospace', fontSize: 13,
            color: conversationInk, backgroundColor: Color(0xffeef0eb)),
          blockSpacing: 14,
          listBullet: body,
          listIndent: 24,
          blockquote: body.copyWith(color: conversationMuted),
          blockquotePadding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
          blockquoteDecoration: const BoxDecoration(
            border: Border(left: BorderSide(color: Color(0xffa5b9aa), width: 3)),
          ),
          tableHead: body.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
          tableBody: body.copyWith(fontSize: 13),
          tableHeadAlign: TextAlign.left,
          tableColumnWidth: const IntrinsicColumnWidth(),
          tableBorder: TableBorder.all(color: conversationBorder),
          tableCellsPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          tableHeadCellsDecoration: const BoxDecoration(color: Color(0xffeff2ec)),
          tableCellsDecoration: const BoxDecoration(color: Color(0xfff8f9f6)),
          codeblockDecoration: const BoxDecoration(),
          horizontalRuleDecoration: const BoxDecoration(
            border: Border(top: BorderSide(color: conversationBorder)),
          ),
        ),
        builders: {'pre': _CodeBuilder()},
        imageBuilder: (uri, title, alt) => ConversationImage(
          key: ValueKey(uri.toString()), source: uri.toString(),
          label: alt?.isNotEmpty == true ? alt! : title ?? 'Image', directory: directory,
        ),
        checkboxBuilder: (checked) => Padding(
          padding: const EdgeInsets.only(top: 4, right: 4),
          child: Icon(checked ? Icons.check_box_outlined : Icons.check_box_outline_blank,
            size: 17, color: checked ? const Color(0xff16796c) : conversationMuted),
        ),
        onTapLink: (_, href, _) {
          if (href != null) unawaited(_openLink(context, href, directory));
        },
      ),
    );
  }
}

class _CodeBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;

  @override
  Widget visitElementAfterWithContext(BuildContext context, md.Element element,
      TextStyle? preferredStyle, TextStyle? parentStyle) {
    final code = element.children?.whereType<md.Element>().firstOrNull;
    final language = code?.attributes['class']?.replaceFirst('language-', '').split(' ').first ?? '';
    return ConversationCode(source: element.textContent, language: language);
  }
}

class ConversationCode extends StatefulWidget {
  const ConversationCode({super.key, required this.source, this.language = '', this.output});
  final String source, language;
  final String? output;

  @override
  State<ConversationCode> createState() => _ConversationCodeState();
}

class _ConversationCodeState extends State<ConversationCode> {
  final _scroll = ScrollController(keepScrollOffset: false);
  bool _wrap = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.source + (widget.output == null ? '' : '\n\n${widget.output}');
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xfff5f6f2),
        border: Border.all(color: conversationBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.only(left: 14, right: 4),
          child: Row(children: [
            Expanded(child: Text(widget.language.isEmpty ? 'text' : widget.language,
              style: const TextStyle(fontSize: 11, color: conversationMuted))),
            IconButton(
              tooltip: _wrap ? 'Scroll long lines' : 'Wrap long lines',
              isSelected: _wrap,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.wrap_text, size: 16),
              onPressed: () => setState(() => _wrap = !_wrap),
            ),
            ConversationCopyButton(text: text, label: 'Copy code'),
          ]),
        ),
        const Divider(height: 1, color: conversationBorder),
        LayoutBuilder(builder: (context, constraints) {
          final code = SelectableText.rich(
            TextSpan(children: [
              highlightedCode(widget.source, language: widget.language),
              if (widget.output case final output?) TextSpan(text: '\n\n$output'),
            ]),
            // ExpansionTile saves a bool; this text saves its own scroll offset.
            key: const PageStorageKey('code-selection'),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5,
              height: 1.6, color: conversationInk),
          );
          return Scrollbar(
            controller: _scroll,
            child: SingleChildScrollView(
              key: const PageStorageKey('code-scroll'),
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(14),
              child: _wrap
                  ? SizedBox(width: (constraints.maxWidth - 28).clamp(0, double.infinity), child: code)
                  : code,
            ),
          );
        }),
      ]),
    );
  }
}

class ConversationCopyButton extends StatefulWidget {
  const ConversationCopyButton({super.key, required this.text, required this.label});
  final String text, label;

  @override
  State<ConversationCopyButton> createState() => _ConversationCopyButtonState();
}

class _ConversationCopyButtonState extends State<ConversationCopyButton> {
  Timer? _reset;
  bool _copied = false;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.text));
      if (!mounted) return;
      _reset?.cancel();
      setState(() => _copied = true);
      _reset = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _copied = false);
      });
    } on PlatformException {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('Could not copy to the clipboard.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: _copied ? 'Copied' : widget.label,
    visualDensity: VisualDensity.compact,
    icon: Icon(_copied ? Icons.check_rounded : Icons.content_copy_rounded,
      size: 15, color: conversationMuted),
    onPressed: _copy,
  );
}

Uri? _contentUri(String source, String directory) {
  final uri = Uri.tryParse(source);
  if (uri == null) return null;
  if (uri.scheme.isEmpty) return Uri.directory(directory).resolveUri(uri);
  if (uri.scheme == 'file' && uri.host.isNotEmpty && uri.host != 'localhost') return null;
  return uri;
}

Future<void> _openLink(BuildContext context, String href, String directory) async {
  try {
    // File references commonly include :line[:column]. The OS opens the file.
    final uri = _contentUri(href, directory);
    if (uri == null || !{'http', 'https', 'mailto', 'file'}.contains(uri.scheme)) {
      throw const FormatException('Unsupported link');
    }
    final target = uri.scheme == 'file'
        ? uri.replace(fragment: '', query: '').toFilePath().replaceFirst(RegExp(r':\d+(?::\d+)?$'), '')
        : uri.toString();
    if (Platform.isMacOS) {
      await Process.start('/usr/bin/open', [target], mode: ProcessStartMode.detached);
    } else if (Platform.isLinux) {
      await Process.start('xdg-open', [target], mode: ProcessStartMode.detached);
    } else {
      throw const FormatException('Unsupported platform');
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('This link could not be opened.')),
      );
    }
  }
}

class ConversationImage extends StatefulWidget {
  const ConversationImage({super.key, required this.source, required this.label, required this.directory});
  final String source, label, directory;

  @override
  State<ConversationImage> createState() => _ConversationImageState();
}

class _ConversationImageState extends State<ConversationImage> {
  ImageProvider? _provider;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(ConversationImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source || oldWidget.directory != widget.directory) _resolve();
  }

  void _resolve() {
    _provider = null;
    try {
      final uri = _contentUri(widget.source, widget.directory);
      if (uri == null) return;
      if (uri.scheme == 'data') {
        // Bound inline decoding; invalid content remains a readable placeholder.
        if (widget.source.length > 24 * 1024 * 1024) return;
        final data = uri.data;
        if (data != null && data.mimeType.startsWith('image/')) _provider = MemoryImage(data.contentAsBytes());
      } else if (uri.scheme == 'http' || uri.scheme == 'https') {
        if (uri.host.isNotEmpty) _provider = NetworkImage(uri.toString());
      } else if (uri.scheme == 'file') {
        _provider = FileImage(File(uri.toFilePath()));
      }
    } on FormatException {
      // Malformed image URLs must not prevent the rest of a message rendering.
    } on ArgumentError {
      // A malformed local file URI is handled like a missing image.
    }
  }

  Widget _placeholder({bool failed = false}) => Container(
    height: 150,
    alignment: Alignment.center,
    color: const Color(0xfff0f2ed),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(failed ? Icons.broken_image_outlined : Icons.image_outlined,
        color: conversationMuted, size: 28),
      const SizedBox(height: 8),
      Text(failed ? 'Could not load image' : 'Loading image…',
        style: const TextStyle(fontSize: 12, color: conversationMuted)),
      if (failed && widget.label != 'Image')
        Padding(padding: const EdgeInsets.all(8), child: Text(widget.label,
          maxLines: 2, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, color: conversationMuted))),
    ]),
  );

  Widget _image() {
    final provider = _provider;
    if (provider == null) return _placeholder(failed: true);
    return Image(
      image: provider,
      fit: BoxFit.contain,
      semanticLabel: widget.label,
      frameBuilder: (_, child, frame, synchronous) =>
          synchronous || frame != null ? child : _placeholder(),
      errorBuilder: (_, _, _) => _placeholder(failed: true),
    );
  }

  void _preview() {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (context) => Dialog(
        backgroundColor: const Color(0xfffcfcfa),
        insetPadding: const EdgeInsets.all(32),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(children: [
            Row(children: [
              Expanded(child: Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis)),
              IconButton(tooltip: 'Close image', onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded)),
            ]),
            Expanded(child: InteractiveViewer(minScale: .5, maxScale: 5,
              child: Center(child: _image()))),
            const Padding(padding: EdgeInsets.only(top: 8, bottom: 4),
              child: Text('Pinch or scroll to zoom', style: TextStyle(fontSize: 11, color: conversationMuted))),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Material(
        color: const Color(0xfff5f6f2),
        clipBehavior: Clip.antiAlias,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: _provider == null ? null : _preview,
          child: Tooltip(message: 'Open image', child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360), child: _image(),
          )),
        ),
      ),
      if (widget.label.isNotEmpty && widget.label != 'Image')
        Padding(padding: const EdgeInsets.only(top: 6), child: Text(widget.label,
          style: const TextStyle(fontSize: 12, color: conversationMuted))),
    ]),
  );
}
