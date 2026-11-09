import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:protocol/protocol.dart' show Json, jsonObject, attachmentDataUrl, CancellationToken;

import 'code_highlight.dart';
import 'appearance.dart';
import 'browser.dart';
import 'inline_reference.dart';
import 'image_preview.dart';
import 'inline_image.dart';
import 'conversation_data.dart';
import 'conversation_annotations.dart';
import 'response_annotation_reference.dart';
import 'desktop_toast.dart';

class ConversationMarkdown extends StatelessWidget {
  const ConversationMarkdown({super.key, required this.text, required this.directory, this.fitContent = false,
    this.fontSize = 14, this.reasoning = false});
  final String text, directory;
  final bool fitContent;
  final double fontSize;
  final bool reasoning;

  @override
  Widget build(BuildContext context) => _ConversationMarkdownBody(markdown: this);
}

class _ConversationMarkdownBody extends StatefulWidget {
  const _ConversationMarkdownBody({required this.markdown});
  final ConversationMarkdown markdown;

  @override
  State<_ConversationMarkdownBody> createState() => _ConversationMarkdownBodyState();
}

class _ConversationMarkdownBodyState extends State<_ConversationMarkdownBody> {
  final _lifetime = CancellationToken();
  Object? _styleState;
  late MarkdownStyleSheet _styleSheet;
  var _inlineSyntaxes = <md.InlineSyntax>[_SkillInvocationSyntax(), _SkillLinkSyntax(), ResponseAnnotationSyntax()];

  @override
  void dispose() { _lifetime.cancel(); super.dispose(); }

  @override
  void reassemble() {
    super.reassemble();
    _styleState = null;
    _inlineSyntaxes = [_SkillInvocationSyntax(), _SkillLinkSyntax(), ResponseAnnotationSyntax()];
  }

  @override
  Widget build(BuildContext context) {
    final markdown = widget.markdown;
    final text = markdown.text, directory = markdown.directory;
    final fitContent = markdown.fitContent, reasoning = markdown.reasoning;
    final fontSize = markdown.fontSize;
    final theme = Theme.of(context);
    final accent = DesktopAccent.of(context);
    final styleKey = (theme, fontSize, reasoning);
    // MarkdownBody reparses on style identity changes. Compare themes by value
    // because Theme.of can return equal localized copies on unrelated rebuilds.
    if (_styleState != styleKey) {
      _styleState = styleKey;
      final body = theme.textTheme.bodyLarge!.copyWith(fontSize: fontSize,
        letterSpacing: 0, color: reasoning ? desktopSecondary : desktopForeground);
      _styleSheet = MarkdownStyleSheet.fromTheme(theme).copyWith(
        p: body,
        a: body.copyWith(color: accent.reference, decoration: TextDecoration.none),
        h1: body.copyWith(fontSize: 20, height: 1.3, fontWeight: FontWeight.w600),
        h2: body.copyWith(fontSize: 18, height: 1.3, fontWeight: FontWeight.w600),
        h3: body.copyWith(fontSize: 16, height: 1.3, fontWeight: FontWeight.w600),
        h4: body.copyWith(fontWeight: FontWeight.w600),
        h5: body.copyWith(fontWeight: FontWeight.w600),
        h6: body.copyWith(fontWeight: FontWeight.w600, color: desktopSecondary),
        h1Padding: const EdgeInsets.only(top: 20, bottom: 8),
        h2Padding: const EdgeInsets.only(top: 20, bottom: 8),
        h3Padding: const EdgeInsets.only(top: 20, bottom: 8),
        code: TextStyle(fontFamily: desktopMonoFamily, fontSize: fontSize * .875,
          // Keep the fill translucent: span backgrounds paint over selection.
          color: desktopForeground, backgroundColor: desktopMuted),
        strong: body.copyWith(fontWeight: FontWeight.w600),
        blockSpacing: 10.4,
        listBullet: body,
        listIndent: 24,
        blockquote: body.copyWith(color: desktopSecondary),
        blockquotePadding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
        blockquoteDecoration: const BoxDecoration(
          border: Border(left: BorderSide(color: desktopBorderStrong, width: 2)),
        ),
        tableHead: body.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
        tableBody: body.copyWith(fontSize: 13),
        tableHeadAlign: TextAlign.left,
        tableColumnWidth: const FlexColumnWidth(),
        tableBorder: TableBorder.all(color: desktopBorder),
        tableCellsPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        tableHeadCellsDecoration: const BoxDecoration(color: desktopMuted),
        tableCellsDecoration: const BoxDecoration(color: desktopSurface),
        codeblockDecoration: const BoxDecoration(),
        horizontalRuleDecoration: const BoxDecoration(
          border: Border(top: BorderSide(color: desktopBorder)),
        ),
      );
    }
    final body = MarkdownBody(
        key: ValueKey((directory, fitContent)),
        data: text,
        extensionSet: md.ExtensionSet.gitHubFlavored,
        inlineSyntaxes: _inlineSyntaxes,
        fitContent: fitContent,
        softLineBreak: fitContent,
        styleSheet: _styleSheet,
        builders: {'pre': _CodeBuilder(), 'skill-reference': _SkillLinkBuilder(directory, _lifetime),
          'codex-annotation': ResponseAnnotationBuilder()},
        imageBuilder: (uri, title, alt) => ConversationImage(
          key: ValueKey(uri.toString()), source: uri.toString(),
          label: alt?.isNotEmpty == true ? alt! : title ?? 'Image', directory: directory, markdown: true,
        ),
        checkboxBuilder: (checked) => Padding(
          padding: const EdgeInsets.only(top: 4, right: 4),
          child: Icon(checked ? Icons.check_box_outlined : Icons.check_box_outline_blank,
            size: 17, color: checked ? desktopForeground : desktopSecondary),
        ),
        onTapLink: (_, href, _) {
          if (href != null) {
            unawaited(openDesktopLink(context, href, directory: directory, cancellation: _lifetime));
          }
        },
      );
    return ConversationImageGroup(child: ConversationAnnotationSelection.contains(context) ? body : SelectionArea(child: body));
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
  _SkillLinkBuilder(this.directory, this.cancellation);
  final String directory;
  final CancellationToken cancellation;

  @override
  Widget visitElementAfterWithContext(BuildContext context, md.Element element,
      TextStyle? preferredStyle, TextStyle? parentStyle) {
    final href = element.attributes['href']!;
    return Tooltip(message: href, child: MouseRegion(cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: () => unawaited(openDesktopLink(context, href,
        directory: directory, cancellation: cancellation)),
        child: Text.rich(TextSpan(children: [
          const WidgetSpan(alignment: PlaceholderAlignment.middle,
            child: Padding(padding: EdgeInsets.only(right: 3), child: SkillIcon())),
          TextSpan(text: element.textContent),
        ]), style: (parentStyle ?? const TextStyle()).copyWith(color: DesktopAccent.of(context).reference,
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
        color: desktopSurface,
        border: Border.all(color: desktopBorder),
        borderRadius: BorderRadius.circular(desktopControlRadius),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.only(left: 14, right: 4),
          child: Row(children: [
            Expanded(child: Text(widget.language.isEmpty ? 'text' : widget.language,
              style: const TextStyle(fontSize: 11, color: desktopSecondary))),
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
        const Divider(height: 1, color: desktopBorder),
        LayoutBuilder(builder: (context, constraints) {
          final span = TextSpan(children: [
              highlightedCode(widget.source, language: widget.language),
              if (widget.output case final output?) TextSpan(text: '\n\n$output'),
            ]);
          const style = TextStyle(fontFamily: desktopMonoFamily, fontSize: 13,
            height: 1.625, letterSpacing: 0, color: desktopForeground);
          final code = ConversationAnnotationSelection.contains(context)
            ? Text.rich(span, style: style)
            : SelectableText.rich(span,
            // ExpansionTile saves a bool; this text saves its own scroll offset.
            key: const PageStorageKey('code-selection'),
            style: style,
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
        showDesktopToast(context, 'Could not copy to the clipboard.', type: DesktopToastType.error);
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
      size: widget.compact ? 14 : 15, color: widget.compact ? desktopTertiary : desktopSecondary),
    onPressed: _copy,
  );
}

Uri? _contentUri(String source, String directory) {
  final uri = Uri.tryParse(source);
  if (uri == null) return null;
  if (uri.scheme.isEmpty) return Directory(directory.isEmpty ? Directory.current.path : directory).absolute.uri.resolveUri(uri);
  if (uri.scheme == 'file' && uri.host.isNotEmpty && uri.host != 'localhost') return null;
  return uri;
}

ImageProvider? conversationImageProvider(String source, String directory) {
  try {
    if (source.startsWith('data:')) return InlineImage(source);
    final uri = _contentUri(source, directory);
    if (uri == null) return null;
    if ((uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty) return NetworkImage(uri.toString());
    if (uri.scheme == 'file') return FileImage(File(uri.toFilePath()));
  } on FormatException {
    // Invalid sources affect only their own image.
  } on ArgumentError {
    // Invalid file URIs are presented as unavailable images.
  }
  return null;
}

/// The outermost group is one message (or the composer's attachment rail).
/// Snapshot mounted images in document order on open, keeping lazy parts lazy.
class ConversationImageGroup extends StatelessWidget {
  const ConversationImageGroup({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => context.getElementForInheritedWidgetOfExactType<_ConversationImageScope>() == null
    ? _ConversationImageScope(child: child) : child;
}

class _ConversationImageScope extends InheritedWidget {
  const _ConversationImageScope({required super.child});

  @override
  bool updateShouldNotify(_ConversationImageScope oldWidget) => false;
}

class ConversationImageParts extends StatelessWidget {
  const ConversationImageParts({super.key, required this.parts, required this.directory});
  final List<Json> parts;
  final String directory;

  @override
  Widget build(BuildContext context) => ConversationImageGroup(child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 12, children: [
    for (final part in parts) ConversationData(value: part, builder: (context, value) {
      final image = jsonObject(value);
      final path = image['path'] as String? ?? '';
      return ConversationImage(source: image['data'] is String ? attachmentDataUrl(image)
        : path.startsWith('/') ? Uri.file(path).toString() : path,
        label: image['name'] as String? ?? 'Image', directory: directory);
    }),
  ]));
}

class ConversationImage extends StatefulWidget {
  const ConversationImage({super.key, required this.source, required this.label, required this.directory,
    this.thumbnail = false, this.markdown = false, this.borderRadius, this.maxHeight,
    this.onAspectRatio, this.previewImages = const [], this.previewID, this.onPreview, this.onPreviewChanged, this.provider});
  final String source, label, directory;
  final bool thumbnail, markdown;
  final double? borderRadius, maxHeight;
  final ValueChanged<double>? onAspectRatio;
  final List<({String id, String source})> previewImages;
  final String? previewID;
  final VoidCallback? onPreview;
  final ValueChanged<String>? onPreviewChanged;
  final ImageProvider? provider;

  @override
  State<ConversationImage> createState() => _ConversationImageState();
}

class _ConversationImageState extends State<ConversationImage> {
  ImageProvider? _provider;
  bool _previewing = false;
  final _imageKey = GlobalKey();
  ImageStream? _ratioStream;
  ImageStreamListener? _ratioListener;
  double? _aspectRatio;
  double get _radius => widget.borderRadius ?? (widget.thumbnail ? 6 : 4);

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(ConversationImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source || oldWidget.directory != widget.directory || oldWidget.provider != widget.provider ||
        oldWidget.onAspectRatio != widget.onAspectRatio) {
      _resolve();
      _observeRatio();
    }
  }

  void _resolve() => _provider = widget.provider ?? conversationImageProvider(widget.source, widget.directory);

  @override
  void didChangeDependencies() { super.didChangeDependencies(); _observeRatio(); }

  void _observeRatio() {
    if (_ratioListener != null) _ratioStream?.removeListener(_ratioListener!);
    _ratioStream = null;
    _ratioListener = null;
    if (widget.onAspectRatio == null || _provider == null) return;
    final source = widget.source;
    _ratioListener = ImageStreamListener((info, _) {
      final ratio = info.image.width / info.image.height;
      info.dispose();
      if (_aspectRatio == ratio) return;
      _aspectRatio = ratio;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.source == source) widget.onAspectRatio?.call(ratio);
      });
    }, onError: (Object _, StackTrace? _) {});
    _ratioStream = _provider!.resolve(createLocalImageConfiguration(context))..addListener(_ratioListener!);
  }

  Widget _placeholder({bool failed = false}) => Container(
    width: widget.thumbnail ? 58 : null,
    height: widget.thumbnail ? 46 : 96,
    alignment: Alignment.center,
    color: desktopMuted,
    child: widget.thumbnail ? (failed ? const Icon(Icons.broken_image_outlined,
      color: desktopTertiary, size: 20) : null) : Column(mainAxisSize: MainAxisSize.min, children: [
      Text(failed ? 'Could not load image' : 'Loading image…',
        style: const TextStyle(fontSize: 12, color: desktopSecondary)),
    ]),
  );

  Widget _image() {
    final provider = _provider;
    if (provider == null) return _placeholder(failed: true);
    return LayoutBuilder(builder: (context, constraints) {
      final ratio = MediaQuery.devicePixelRatioOf(context);
      final height = widget.thumbnail ? 46.0 : widget.maxHeight ?? MediaQuery.sizeOf(context).height * .6;
      final width = widget.thumbnail ? 58.0 : constraints.maxWidth;
      return ConstrainedBox(constraints: BoxConstraints(maxHeight: height), child: Image(
        image: ResizeImage(provider, width: width.isFinite ? (width * ratio).ceil() : null,
          height: (height * ratio).ceil(), policy: ResizeImagePolicy.fit),
        fit: widget.thumbnail ? BoxFit.cover : BoxFit.contain,
        width: widget.thumbnail ? 58 : null,
        height: widget.thumbnail ? 46 : null,
        gaplessPlayback: true,
        semanticLabel: widget.label,
        frameBuilder: (_, child, frame, synchronous) =>
            synchronous || frame != null ? child : _placeholder(),
        errorBuilder: (_, _, _) => _placeholder(failed: true),
      ));
    });
  }

  PreviewImage? _previewImage() {
    final provider = _provider, box = _imageKey.currentContext?.findRenderObject();
    if (provider == null || box is! RenderBox || !box.attached || !box.hasSize) return null;
    return (provider: provider, label: widget.label, origin: box.localToGlobal(Offset.zero) & box.size,
      originRadius: _radius);
  }

  void _preview() {
    if (_previewing) return;
    final images = <(PreviewImage, _ConversationImageState)>[];
    void collect(Element element) {
      if (element is StatefulElement && element.state is _ConversationImageState) {
        final state = element.state as _ConversationImageState;
        final image = state._previewImage();
        if (image != null) images.add((image, state));
      } else {
        element.visitChildElements(collect);
      }
    }
    final group = context.getElementForInheritedWidgetOfExactType<_ConversationImageScope>();
    if (widget.previewImages.isNotEmpty) {
      final origin = _previewImage();
      if (origin == null) return;
      final previews = <PreviewImage>[];
      final ids = <String>[];
      for (final image in widget.previewImages) {
        final provider = conversationImageProvider(image.source, widget.directory);
        if (provider == null) continue;
        ids.add(image.id);
        previews.add((provider: provider, label: widget.label, origin: origin.origin, originRadius: _radius));
      }
      final initial = ids.indexOf(widget.previewID ?? '');
      if (initial < 0) return;
      widget.onPreview?.call();
      showGeneralDialog<void>(context: context, barrierDismissible: true,
        barrierLabel: 'Close image', barrierColor: Colors.transparent,
        transitionDuration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 240),
        pageBuilder: (context, _, _) => ImagePreview(images: previews, initialIndex: initial,
          onChanged: (index) => widget.onPreviewChanged?.call(ids[index])),
        transitionBuilder: (_, _, _, child) => child);
      return;
    }
    if (group != null) {
      group.visitChildElements(collect);
    } else {
      final image = _previewImage();
      if (image != null) images.add((image, this));
    }
    final initial = images.indexWhere((image) => identical(image.$2, this));
    if (initial < 0) return;
    widget.onPreview?.call();
    var active = initial;
    void hide(int index, bool hidden) {
      final state = images[index].$2;
      if (state.mounted) state.setState(() => state._previewing = hidden);
    }
    hide(active, true);
    unawaited(showGeneralDialog<void>(context: context, barrierDismissible: true,
      barrierLabel: 'Close image', barrierColor: Colors.transparent,
      transitionDuration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 240),
      pageBuilder: (context, _, _) => ImagePreview(images: images.map((image) => image.$1).toList(growable: false),
        initialIndex: initial, onChanged: (index) { hide(active, false); active = index; hide(active, true); }),
      transitionBuilder: (_, _, _, child) => child,
    ).whenComplete(() => hide(active, false)));
  }

  @override
  void dispose() {
    if (_ratioListener != null) _ratioStream?.removeListener(_ratioListener!);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = MouseRegion(cursor: _provider == null ? MouseCursor.defer
      : widget.thumbnail ? SystemMouseCursors.click : SystemMouseCursors.zoomIn,
      child: GestureDetector(key: _imageKey, onTap: _provider == null ? null : _preview,
        child: Tooltip(message: 'Open image', child: Semantics(button: _provider != null, label: widget.label,
          child: Opacity(opacity: _previewing ? 0 : 1, child: ClipRRect(
            borderRadius: BorderRadius.circular(_radius),
            child: _image(),
          ))))));
    if (widget.thumbnail) {
      return SizedBox(width: 58, height: 46,
      child: DecoratedBox(position: DecorationPosition.foreground,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(6),
          border: Border.all(color: _previewing ? Colors.transparent : desktopBorder, width: .5)), child: image));
    }
    return widget.markdown ? Padding(padding: const EdgeInsets.symmetric(vertical: 24), child: image) : image;
  }
}
