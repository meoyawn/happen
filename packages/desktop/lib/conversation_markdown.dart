import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:protocol/protocol.dart' show maxClientFrameBytes;

import 'code_highlight.dart';
import 'appearance.dart';
import 'inline_reference.dart';

const conversationInk = Color(0xff1a1c1f);
const conversationMuted = Color(0xff8b8e95);
const conversationBorder = Color(0xffe8e9eb);

class ConversationMarkdown extends StatelessWidget {
  const ConversationMarkdown({super.key, required this.text, required this.directory, this.fitContent = false, this.fontSize = 14});
  final String text, directory;
  final bool fitContent;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final body = TextStyle(fontSize: fontSize, height: fitContent ? 1.5 : 1.6,
      letterSpacing: 0, color: opencodeInk);
    return SelectionArea(
      child: MarkdownBody(
        data: text,
        extensionSet: md.ExtensionSet.gitHubFlavored,
        inlineSyntaxes: [_SkillInvocationSyntax(), _SkillLinkSyntax()],
        fitContent: fitContent,
        softLineBreak: fitContent,
        styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
          p: body,
          a: body.copyWith(color: const Color(0xff3b5cf6), decoration: TextDecoration.none),
          h1: body.copyWith(fontSize: fontSize + 3, height: 20 / 17, fontWeight: FontWeight.w600),
          h2: body.copyWith(fontSize: fontSize + 1, height: 20 / 15, fontWeight: FontWeight.w600),
          h3: body.copyWith(fontSize: fontSize, height: 20 / 14,
            fontWeight: FontWeight.w600, fontVariations: const [FontVariation('wght', 670)]),
          h4: body.copyWith(fontWeight: FontWeight.w500, color: opencodeMuted),
          h5: body.copyWith(fontWeight: FontWeight.w500, color: opencodeMuted),
          h6: body.copyWith(fontWeight: FontWeight.w500, color: opencodeMuted),
          h1Padding: EdgeInsets.only(top: 28, bottom: 12),
          h2Padding: EdgeInsets.only(top: 24, bottom: 10),
          h3Padding: EdgeInsets.only(top: 20, bottom: 8),
          code: TextStyle(fontFamily: 'IBM Plex Mono', fontSize: 13,
            color: opencodeInk, backgroundColor: opencodeLayer),
          strong: body.copyWith(fontWeight: FontWeight.w600,
            fontVariations: const [FontVariation('wght', 670)]),
          blockSpacing: 12,
          listBullet: body,
          listIndent: 24,
          blockquote: body.copyWith(color: conversationMuted),
          blockquotePadding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
          blockquoteDecoration: const BoxDecoration(
            border: Border(left: BorderSide(color: Color(0xffd4d6db), width: 2)),
          ),
          tableHead: body.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
          tableBody: body.copyWith(fontSize: 13),
          tableHeadAlign: TextAlign.left,
          tableColumnWidth: const IntrinsicColumnWidth(),
          tableBorder: TableBorder.all(color: conversationBorder),
          tableCellsPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          tableHeadCellsDecoration: const BoxDecoration(color: Color(0xfff4f4f6)),
          tableCellsDecoration: const BoxDecoration(color: Colors.white),
          codeblockDecoration: const BoxDecoration(),
          horizontalRuleDecoration: const BoxDecoration(
            border: Border(top: BorderSide(color: conversationBorder)),
          ),
        ),
        builders: {'pre': _CodeBuilder(), 'skill-reference': _SkillLinkBuilder(directory)},
        imageBuilder: (uri, title, alt) => ConversationImage(
          key: ValueKey(uri.toString()), source: uri.toString(),
          label: alt?.isNotEmpty == true ? alt! : title ?? 'Image', directory: directory,
        ),
        checkboxBuilder: (checked) => Padding(
          padding: const EdgeInsets.only(top: 4, right: 4),
          child: Icon(checked ? Icons.check_box_outlined : Icons.check_box_outline_blank,
            size: 17, color: checked ? conversationInk : conversationMuted),
        ),
        onTapLink: (_, href, _) {
          if (href != null) unawaited(_openLink(context, href, directory));
        },
      ),
    );
  }
}

/// Composer atoms retain native paths, including spaces, in their Markdown.
/// Recognize those invocations inside the inline parser so code stays literal.
class _SkillInvocationSyntax extends md.InlineSyntax {
  _SkillInvocationSyntax() : super(r'\[(\$(?:\\.|[^\\\]\r\n])*)\]\(((?:\\.|[^\\)\r\n])+)\)');

  @override
  bool tryMatch(md.InlineParser parser, [int? startMatchPos]) {
    final match = pattern.matchAsPrefix(parser.source, startMatchPos ?? parser.pos);
    if (match == null) return false;
    final destination = match[2]!;
    // Leave ordinary link destinations and optional titles to Markdown.
    if (!RegExp(r'(?:/|\\\\)SKILL\.md$', caseSensitive: false).hasMatch(destination)) return false;
    if (!_localSkillUri(Uri.tryParse(destination))) return false;
    return super.tryMatch(parser, startMatchPos);
  }

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(_SkillLinkSyntax().createNode(match[2]!, null,
      getChildren: () => parser.document.parseInline(match[1]!)));
    return true;
  }
}

bool _localSkillUri(Uri? uri) => uri != null && {'', 'file'}.contains(uri.scheme) &&
    (!uri.hasAuthority || uri.scheme == 'file' && (uri.host.isEmpty || uri.host == 'localhost'));

/// Keep Markdown's link parsing and escaping, decorating only local skill links.
class _SkillLinkSyntax extends md.LinkSyntax {
  @override
  md.Node createNode(String destination, String? title, {required List<md.Node> Function() getChildren}) {
    final node = super.createNode(destination, title, getChildren: getChildren) as md.Element;
    final uri = Uri.tryParse(node.attributes['href']!);
    if (!_localSkillUri(uri)) return node;
    if (!node.textContent.trim().startsWith(r'$') && uri!.path.split('/').last.toLowerCase() != 'skill.md') return node;
    return md.Element('skill-reference', node.children)..attributes.addAll(node.attributes);
  }
}

class _SkillLinkBuilder extends MarkdownElementBuilder {
  _SkillLinkBuilder(this.directory);
  final String directory;

  @override
  Widget visitElementAfterWithContext(BuildContext context, md.Element element,
      TextStyle? preferredStyle, TextStyle? parentStyle) {
    final href = element.attributes['href']!;
    return Tooltip(message: href, child: MouseRegion(cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: () => unawaited(_openLink(context, href, directory)),
        child: Text.rich(TextSpan(children: [
          const WidgetSpan(alignment: PlaceholderAlignment.middle,
            child: Padding(padding: EdgeInsets.only(right: 3), child: SkillIcon())),
          TextSpan(text: element.textContent),
        ]), style: (parentStyle ?? const TextStyle()).copyWith(color: inlineReferenceAccent,
          fontWeight: FontWeight.w500, decoration: TextDecoration.none)),
      ),
    ));
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
        color: opencodeLayer,
        border: Border.all(color: opencodeBorder, width: .5),
        borderRadius: BorderRadius.circular(6),
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
            style: TextStyle(fontFamily: 'IBM Plex Mono', fontSize: 13,
              height: 20 / 13, letterSpacing: -.04,
              color: opencodeInk),
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
  const ConversationCopyButton({super.key, required this.text, required this.label, this.compact = false});
  final String text, label;
  final bool compact;

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
    style: widget.compact ? IconButton.styleFrom(
      minimumSize: const Size.square(20), maximumSize: const Size.square(20),
      padding: EdgeInsets.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap) : null,
    visualDensity: VisualDensity.compact,
    icon: Icon(_copied ? Icons.check_rounded : Icons.content_copy_rounded,
      size: widget.compact ? 14 : 15, color: widget.compact ? opencodeFaint : conversationMuted),
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
  const ConversationImage({super.key, required this.source, required this.label, required this.directory, this.thumbnail = false});
  final String source, label, directory;
  final bool thumbnail;

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
        if (widget.source.length > maxClientFrameBytes) return;
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
    height: widget.thumbnail ? 78 : 150,
    alignment: Alignment.center,
    color: const Color(0xfff3f3f3),
    child: widget.thumbnail ? Icon(failed ? Icons.broken_image_outlined : Icons.image_outlined,
      color: conversationMuted, size: 24) : Column(mainAxisSize: MainAxisSize.min, children: [
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

  Widget _image({bool preview = false}) {
    final provider = _provider;
    if (provider == null) return _placeholder(failed: true);
    return Image(
      image: widget.thumbnail && !preview ? ResizeImage(provider, width: 212, height: 156, policy: ResizeImagePolicy.fit) : provider,
      fit: BoxFit.contain,
      width: widget.thumbnail && !preview ? 106 : null,
      height: widget.thumbnail && !preview ? 78 : null,
      gaplessPlayback: true,
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
              child: Center(child: _image(preview: true)))),
            const Padding(padding: EdgeInsets.only(top: 8, bottom: 4),
              child: Text('Pinch or scroll to zoom', style: TextStyle(fontSize: 11, color: conversationMuted))),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final image = Material(
        color: const Color(0xfff5f5f5),
        clipBehavior: Clip.antiAlias,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: _provider == null ? null : _preview,
          child: Tooltip(message: 'Open image', child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: widget.thumbnail ? 78 : 360), child: _image(),
          )),
        ),
      );
    if (widget.thumbnail) return image;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      image,
      if (widget.label.isNotEmpty && widget.label != 'Image')
        Padding(padding: const EdgeInsets.only(top: 6), child: Text(widget.label,
          style: const TextStyle(fontSize: 12, color: conversationMuted))),
    ]),
    );
  }
}
