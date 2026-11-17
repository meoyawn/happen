import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:mermaid_core/mermaid_core.dart' as mermaid;
import 'package:mermaid_flutter/mermaid_flutter.dart';
import 'package:protocol/protocol.dart' show Json, jsonObject, attachmentDataUrl, CancellationToken;

import 'code_highlight.dart';
import 'appearance.dart';
import 'browser.dart';
import 'inline_reference.dart';
import 'image_preview.dart';
import 'image_context_menu.dart';
import 'conversation_image_source.dart';
import 'generated_image_loading.dart';
import 'conversation_data.dart';
import 'conversation_annotations.dart';
import 'response_annotation_reference.dart';
import 'desktop_toast.dart';
import 'selectable_markdown.dart';

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

class _ConversationMarkdownBodyState extends State<_ConversationMarkdownBody> implements MarkdownBuilderDelegate {
  final _lifetime = CancellationToken();
  Object? _styleState;
  late MarkdownStyleSheet _styleSheet;
  var _inlineSyntaxes = <md.InlineSyntax>[_SkillInvocationSyntax(), _SkillLinkSyntax(), ResponseAnnotationSyntax()];
  late final _links = <GestureRecognizer, String?>{};
  Object? _contentState;
  late Widget _content;
  String? _hoveredHref;
  Offset? _tooltipPosition;
  Timer? _tooltipDelay;
  OverlayEntry? _tooltip;
  ScrollPosition? _tooltipScroll;

  void _disposeLinks() {
    for (final recognizer in _links.keys) { recognizer.dispose(); }
    _links.clear();
  }

  @override
  GestureRecognizer createLink(String text, String? href, String title) {
    final recognizer = TapGestureRecognizer()
      ..onTap = () {
        _hideLinkTooltip();
        if (href != null) {
          unawaited(openDesktopLink(context, href, directory: widget.markdown.directory, cancellation: _lifetime));
        }
      }
      ..onSecondaryTapUp = href == null ? null : (details) {
        _hideLinkTooltip();
        unawaited(_showLinkMenu(context, href, details.globalPosition));
      };
    _links[recognizer] = href;
    return recognizer;
  }

  @override
  TextSpan formatText(MarkdownStyleSheet styleSheet, String code) =>
    TextSpan(text: code.replaceFirst(RegExp(r'\n$'), ''), style: styleSheet.code);

  void _hoverLink(PointerHoverEvent event) {
    final render = context.findRenderObject();
    if (render is! RenderBox || !render.attached || !render.hasSize) return;
    final hit = BoxHitTestResult();
    render.hitTest(hit, position: render.globalToLocal(event.position));
    final href = hit.path.map((entry) => entry.target).whereType<TextSpan>()
      .map((span) => _links[span.recognizer]).whereType<String>().firstOrNull;
    if (href != _hoveredHref) { _hideLinkTooltip(); _hoveredHref = href; }
    if (href == null) return;
    _tooltipPosition = event.position;
    if (_tooltip != null) { _tooltip!.markNeedsBuild(); return; }
    if (_tooltipDelay != null) return;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_dismissLinkTooltip);
    _tooltipScroll = Scrollable.maybeOf(context)?.position;
    _tooltipScroll?.addListener(_hideLinkTooltip);
    _tooltipDelay = Timer(TooltipTheme.of(context).waitDuration ?? const Duration(milliseconds: 500), () {
      if (!mounted || _hoveredHref == null) return;
      final overlay = Overlay.maybeOf(context);
      if (overlay == null) { _hideLinkTooltip(); return; }
      final style = Theme.of(context).textTheme.bodySmall?.copyWith(color: desktopSurface, fontSize: 12, height: 1.4);
      _tooltip = OverlayEntry(builder: (_) {
        final render = overlay.context.findRenderObject();
        if (render is! RenderBox || !render.hasSize || _tooltipPosition == null || _hoveredHref == null) {
          return const SizedBox.shrink();
        }
        return Positioned.fill(child: IgnorePointer(child: ExcludeSemantics(child: CustomSingleChildLayout(
          delegate: _LinkTooltipLayout(render.globalToLocal(_tooltipPosition!)),
          child: DecoratedBox(decoration: BoxDecoration(color: desktopForeground, borderRadius: BorderRadius.circular(4)),
            child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              child: Text(_hoveredHref!, textDirection: TextDirection.ltr, style: style))),
        ))));
      });
      overlay.insert(_tooltip!);
    });
  }

  void _dismissLinkTooltip(PointerEvent event) {
    if (event is PointerDownEvent || event is PointerSignalEvent || event is PointerPanZoomStartEvent ||
        event is PointerCancelEvent || event is PointerRemovedEvent) { _hideLinkTooltip(); }
  }

  void _hideLinkTooltip() {
    if (_tooltipDelay != null) GestureBinding.instance.pointerRouter.removeGlobalRoute(_dismissLinkTooltip);
    _tooltipDelay?.cancel();
    _tooltipDelay = null;
    _tooltipScroll?.removeListener(_hideLinkTooltip);
    _tooltipScroll = null;
    _tooltip?.remove();
    _tooltip?.dispose();
    _tooltip = null;
    _hoveredHref = null;
  }

  @override
  void didUpdateWidget(_ConversationMarkdownBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.markdown.text != widget.markdown.text || oldWidget.markdown.directory != widget.markdown.directory) {
      _hideLinkTooltip();
    }
  }

  @override
  void deactivate() { _hideLinkTooltip(); super.deactivate(); }

  @override
  void dispose() { _hideLinkTooltip(); _disposeLinks(); _lifetime.cancel(); super.dispose(); }

  @override
  void reassemble() {
    super.reassemble();
    _hideLinkTooltip();
    _styleState = null;
    _contentState = null;
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
        code: TextStyle(fontFamily: desktopMonoFamily, fontSize: fontSize * .875),
        strong: const TextStyle(fontWeight: FontWeight.w600),
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
    final contentKey = (text, directory, fitContent, _styleSheet);
    if (_contentState != contentKey) {
      _hideLinkTooltip();
      _disposeLinks();
      final nodes = md.Document(extensionSet: md.ExtensionSet.gitHubFlavored,
        inlineSyntaxes: _inlineSyntaxes, encodeHtml: false).parseLines(const LineSplitter().convert(text));
      _selectableParagraphs(nodes);
      // Retain the package's block layouts; each inline flow has one native
      // paragraph for selection, copy offsets and code background painting.
      final children = MarkdownBuilder(
        delegate: this,
        selectable: false,
        imageDirectory: null,
        bulletBuilder: null,
        paddingBuilders: const {},
        listItemCrossAxisAlignment: MarkdownListItemCrossAxisAlignment.baseline,
        fitContent: fitContent,
        softLineBreak: fitContent,
        styleSheet: _styleSheet,
        builders: {'pre': _CodeBuilder(), 'selectable-paragraph': _SelectableParagraphBuilder(this)},
        imageBuilder: (uri, title, alt) => ConversationImage(
          key: ValueKey(uri.toString()), source: uri.toString(),
          label: alt?.isNotEmpty == true ? alt! : title ?? 'Image', directory: directory, markdown: true,
        ),
        checkboxBuilder: (checked) => Padding(
          padding: const EdgeInsets.only(top: 4, right: 4),
          child: Icon(checked ? Icons.check_box_outlined : Icons.check_box_outline_blank,
            size: 17, color: checked ? desktopForeground : desktopSecondary),
        ),
      ).build(nodes);
      _content = children.length == 1 ? children.single : Column(mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: fitContent ? CrossAxisAlignment.start : CrossAxisAlignment.stretch, children: children);
      _contentState = contentKey;
    }
    return ConversationImageGroup(child: MouseRegion(onHover: _hoverLink, onExit: (_) => _hideLinkTooltip(),
      child: ConversationAnnotationSelection.contains(context) ? _content : SelectionArea(child: _content)));
  }

  Widget _paragraph(BuildContext context, _SelectableParagraphNode node, TextStyle? parentStyle) =>
    ParagraphSelection(child: Builder(builder: (context) {
      final defaults = DefaultTextStyle.of(context);
      final requested = switch (node.blockTag) {
        'th' => _styleSheet.tableHead!,
        'td' => _styleSheet.tableBody!,
        _ => parentStyle ?? _styleSheet.p!,
      };
      var style = requested.inherit ? defaults.style.merge(requested) : requested;
      if (MediaQuery.boldTextOf(context)) style = style.merge(const TextStyle(fontWeight: FontWeight.bold));
      final selection = DefaultSelectionStyle.of(context);
      final registrar = SelectionContainer.maybeOf(context);
      return MouseRegion(cursor: registrar == null ? MouseCursor.defer : selection.mouseCursor ?? SystemMouseCursors.text,
        child: LaidOutSelectableRichText(
          text: TextSpan(style: style, children: _inline(context, node.nodes, style)),
          textAlign: node.textAlign ?? defaults.textAlign ?? TextAlign.start,
          softWrap: defaults.softWrap, overflow: defaults.overflow, maxLines: defaults.maxLines,
          textScaler: _styleSheet.textScaler ?? MediaQuery.textScalerOf(context),
          textWidthBasis: TextWidthBasis.longestLine,
          strutStyle: StrutStyle(fontFamily: style.fontFamily, fontSize: style.fontSize,
            height: style.height, leading: 0),
          textHeightBehavior: defaults.textHeightBehavior ?? DefaultTextHeightBehavior.maybeOf(context),
          selectionRegistrar: registrar,
          selectionColor: selection.selectionColor ?? DefaultSelectionStyle.defaultColor,
        ));
    }));

  List<InlineSpan> _inline(BuildContext context, List<md.Node> nodes, TextStyle style,
      [GestureRecognizer? recognizer]) => [
    for (final node in nodes) _inlineNode(context, node, style, recognizer),
  ];

  InlineSpan _inlineNode(BuildContext context, md.Node node, TextStyle style, GestureRecognizer? recognizer) {
    if (node is! md.Element) {
      final text = widget.markdown.fitContent ? node.textContent : node.textContent.replaceAll(RegExp(r' ?\n *'), ' ');
      return TextSpan(text: text, recognizer: recognizer);
    }
    final children = node.children ?? const <md.Node>[];
    switch (node.tag) {
      case 'code':
        return InlineCodeTextSpan(text: node.textContent, style: style.merge(_styleSheet.code),
          backgroundColor: desktopMuted, recognizer: recognizer);
      case 'br': return const TextSpan(text: '\n');
      case 'input': return const TextSpan();
      case 'a':
      case 'skill-reference':
        final href = node.attributes['href'];
        if (href == null) return TextSpan(children: _inline(context, children, style, recognizer));
        final link = createLink(node.textContent, href, node.attributes['title'] ?? '') as TapGestureRecognizer;
        final linkStyle = style.merge(_styleSheet.a).copyWith(
          fontWeight: node.tag == 'skill-reference' ? FontWeight.w500 : style.fontWeight);
        return TextSpan(style: linkStyle, recognizer: link, mouseCursor: SystemMouseCursors.click, children: [
          if (node.tag == 'skill-reference') WidgetSpan(alignment: PlaceholderAlignment.middle,
            child: SelectionContainer.disabled(child: Tooltip(message: href,
              child: MouseRegion(cursor: SystemMouseCursors.click,
                child: GestureDetector(onTap: link.onTap, onSecondaryTapUp: link.onSecondaryTapUp,
                  child: const Padding(padding: EdgeInsets.only(right: 3), child: SkillIcon())))))),
          ..._inline(context, children, linkStyle, link),
        ]);
      case 'codex-annotation':
        final index = node.attributes['index'];
        final annotation = resolveResponseAnnotation(index, ResponseAnnotationContext.of(context));
        if (annotation == null) return TextSpan(text: 'Annotation ${index ?? ''}');
        return WidgetSpan(alignment: PlaceholderAlignment.baseline, baseline: TextBaseline.alphabetic,
          child: SelectionContainer.disabled(child: ResponseAnnotationReference(number: int.parse(index!),
            annotation: annotation, style: style, selectionRegistrar: SelectionContainer.maybeOf(context))));
      case 'img':
        final image = ConversationImage(
          key: ValueKey(node.attributes['src']), source: node.attributes['src'] ?? '',
          label: node.attributes['alt']?.isNotEmpty == true ? node.attributes['alt']! : node.attributes['title'] ?? 'Image',
          directory: widget.markdown.directory, markdown: true,
        );
        return WidgetSpan(alignment: PlaceholderAlignment.bottom,
          child: SelectionContainer.disabled(child: recognizer is TapGestureRecognizer
            ? GestureDetector(onTap: recognizer.onTap, child: image) : image));
      default:
        final nestedStyle = style.merge(_styleSheet.styles[node.tag]);
        return TextSpan(style: nestedStyle, children: _inline(context, children, nestedStyle, recognizer));
    }
  }
}

/// Replace inline groups without changing list, table or fenced-code ownership.
void _selectableParagraphs(List<md.Node> nodes) {
  const paragraphs = {'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'li', 'th', 'td'};
  const blocks = {'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'ul', 'ol', 'li', 'blockquote', 'pre', 'table', 'thead', 'tbody', 'tr', 'hr'};
  for (final node in nodes) {
    if (node is! md.Element || node.tag == 'pre' || node.children == null) continue;
    if (!paragraphs.contains(node.tag)) { _selectableParagraphs(node.children!); continue; }
    final children = <md.Node>[], inline = <md.Node>[];
    void flush() {
      if (inline.isEmpty) return;
      children.add(_SelectableParagraphNode(List.of(inline), node.tag, switch (node.attributes['align']) {
        'left' => TextAlign.left, 'center' => TextAlign.center, 'right' => TextAlign.right, _ => null,
      }));
      inline.clear();
    }
    for (final child in node.children!) {
      if (child is md.Element && (blocks.contains(child.tag) || child.attributes['type'] == 'checkbox')) {
        flush();
        _selectableParagraphs([child]);
        children.add(child);
      } else { inline.add(child); }
    }
    flush();
    node.children!..clear()..addAll(children);
  }
}

class _SelectableParagraphNode extends md.Element {
  _SelectableParagraphNode(this.nodes, this.blockTag, this.textAlign) : super('selectable-paragraph', []);
  final List<md.Node> nodes;
  final String blockTag;
  final TextAlign? textAlign;
}

class _SelectableParagraphBuilder extends MarkdownElementBuilder {
  _SelectableParagraphBuilder(this.owner);
  final _ConversationMarkdownBodyState owner;

  @override
  Widget visitElementAfterWithContext(BuildContext context, md.Element element,
      TextStyle? preferredStyle, TextStyle? parentStyle) =>
    owner._paragraph(context, element as _SelectableParagraphNode, parentStyle);
}

Future<void> _showLinkMenu(BuildContext context, String href, Offset position) async {
  ContextMenuController.removeAny();
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final copy = await showMenu<bool>(context: context,
    position: RelativeRect.fromRect(overlay.globalToLocal(position) & Size.zero, Offset.zero & overlay.size),
    items: [const PopupMenuItem(value: true, child: Text('Copy link'))]);
  if (copy != true || !context.mounted) return;
  try {
    await Clipboard.setData(ClipboardData(text: href));
  } on PlatformException {
    if (context.mounted) {
      showDesktopToast(context, 'Could not copy to the clipboard.', type: DesktopToastType.error);
    }
  }
}

class _LinkTooltipLayout extends SingleChildLayoutDelegate {
  _LinkTooltipLayout(this.position);
  final Offset position;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => BoxConstraints.loose(Size(
    math.min(480, math.max(0, constraints.maxWidth - 16)), math.max(0, constraints.maxHeight - 16)));

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final left = (position.dx + 12).clamp(8.0, math.max(8.0, size.width - childSize.width - 8));
    final below = position.dy + 18;
    final top = below + childSize.height + 8 <= size.height ? below : position.dy - childSize.height - 12;
    return Offset(left.toDouble(), top.clamp(8.0, math.max(8.0, size.height - childSize.height - 8)).toDouble());
  }

  @override
  bool shouldRelayout(_LinkTooltipLayout oldDelegate) => position != oldDelegate.position;
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

final _flowchartHeader = RegExp(r'^\s*(?:graph|flowchart(?:-elk)?)\b', multiLine: true);

/// Mermaid treats a bare semicolon as a statement break, even inside an edge
/// label delimited by pipes. Quote only those labels for the render input.
String _mermaidRenderSource(String source) {
  if (!source.contains(';') || !_flowchartHeader.hasMatch(source)) return source;
  final rendered = StringBuffer();
  var start = 0;
  var depth = 0;
  var quoted = false;
  var comment = false;
  for (var i = 0; i < source.length; i++) {
    final char = source[i];
    if (char == '\n') { comment = false; continue; }
    if (comment) continue;
    if (char == '"') { quoted = !quoted; continue; }
    if (quoted) continue;
    if (char == '%' && i + 1 < source.length && source[i + 1] == '%') { comment = true; i++; continue; }
    if (char == '[' || char == '(' || char == '{') { depth++; continue; }
    if (char == ']' || char == ')' || char == '}') { if (depth > 0) depth--; continue; }
    if (char != '|' || depth != 0) continue;
    final end = source.indexOf('|', i + 1);
    if (end < 0 || source.substring(i + 1, end).contains('\n')) continue;
    final label = source.substring(i + 1, end);
    if (label.contains(';') && !label.contains('"')) {
      rendered.write(source.substring(start, i + 1));
      rendered.write('"$label"');
      start = end;
    }
    i = end;
  }
  if (start == 0) return source;
  rendered.write(source.substring(start));
  return rendered.toString();
}

mermaid.MermaidTheme _mermaidTheme(ThemeData theme) =>
  MaterialMermaidTheme.fromTheme(theme).copyWith(
    // Nested subgraph fills compound, making each level visible on the canvas.
    clusterBkg: const mermaid.Color(0x28687991),
    clusterBorder: const mermaid.Color(0xff697b8c),
    nodeBorder: const mermaid.Color(0xff607a92),
    lineColor: const mermaid.Color(0xff405163),
    arrowheadColor: const mermaid.Color(0xff405163),
  );

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
  bool _showSource = false;

  void _expandDiagram() {
    final source = widget.source;
    unawaited(showDialog<void>(context: context, builder: (context) => Dialog(
      insetPadding: const EdgeInsets.all(24),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        Padding(padding: const EdgeInsets.only(left: 16, right: 4), child: Row(children: [
          const Expanded(child: Text('Mermaid diagram')),
          ConversationCopyButton(text: source, label: 'Copy code'),
          IconButton(tooltip: 'Close diagram', icon: const Icon(Icons.close, size: 18),
            onPressed: () => Navigator.of(context).pop()),
        ])),
        const Divider(height: 1, color: desktopBorder),
        Expanded(child: MermaidView(source: _mermaidRenderSource(source),
          theme: _mermaidTheme(Theme.of(context)),
          semanticNodes: true, allowFullscreen: false, keepLastGoodSceneOnError: false,
          backgroundColor: desktopSurface)),
      ]),
    )));
  }

  Widget _sourceView() => LayoutBuilder(builder: (context, constraints) {
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
  });

  Widget _diagramView(BuildContext context) => LayoutBuilder(builder: (context, constraints) =>
    Padding(padding: const EdgeInsets.all(14), child: FittedBox(fit: BoxFit.scaleDown,
      child: MermaidDiagram(source: _mermaidRenderSource(widget.source),
        theme: _mermaidTheme(Theme.of(context)),
        semanticNodes: true, keepLastGoodSceneOnError: false,
        errorBuilder: (context, error) => SizedBox(
          width: math.max(0, constraints.maxWidth - 28),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Could not render diagram. Showing source.',
              style: TextStyle(fontSize: 12, color: desktopSecondary)),
            _sourceView(),
          ]),
        ),
      ),
    )));

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.source + (widget.output == null ? '' : '\n\n${widget.output}');
    final mermaid = widget.language.toLowerCase() == 'mermaid' && widget.output == null;
    final showDiagram = mermaid && !_showSource;
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
            if (mermaid) IconButton(
              tooltip: _showSource ? 'Show diagram' : 'Show source',
              isSelected: _showSource,
              visualDensity: VisualDensity.compact,
              icon: Icon(_showSource ? Icons.account_tree_outlined : Icons.code, size: 16),
              onPressed: () => setState(() => _showSource = !_showSource),
            ),
            if (showDiagram) IconButton(
              tooltip: 'Expand diagram',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.open_in_full, size: 16),
              onPressed: _expandDiagram,
            ) else IconButton(
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
        showDiagram ? _diagramView(context) : _sourceView(),
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
    if (source.startsWith('data:') || kIsWeb && (source.startsWith('browser-file:') || source.startsWith('blob:'))) {
      return ConversationImageSource(source);
    }
    final uri = _contentUri(source, directory);
    if (uri == null) return null;
    if (((uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty) || uri.scheme == 'file') {
      return ConversationImageSource(uri.toString());
    }
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
    this.thumbnailSize, this.markdown = false, this.generated = false, this.borderRadius, this.maxHeight,
    this.onAspectRatio, this.previewImages = const [], this.previewID, this.onPreview, this.onOpen, this.provider});
  final String source, label, directory;
  final bool markdown, generated;
  final double? thumbnailSize, borderRadius, maxHeight;
  final ValueChanged<double>? onAspectRatio;
  final List<({String id, String source})> previewImages;
  final String? previewID;
  final VoidCallback? onPreview, onOpen;
  final ImageProvider? provider;

  @override
  State<ConversationImage> createState() => _ConversationImageState();
}

class _ConversationImageState extends State<ConversationImage> {
  final _lifetime = CancellationToken();
  ImageProvider? _provider;
  bool _hovered = false;
  ImageStream? _ratioStream;
  ImageStreamListener? _ratioListener;
  double? _aspectRatio;
  double get _radius => widget.borderRadius ?? 8;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(ConversationImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source || oldWidget.directory != widget.directory || oldWidget.provider != widget.provider) {
      _aspectRatio = null;
      _resolve();
      _observeRatio();
    } else if (oldWidget.onAspectRatio == null && widget.onAspectRatio != null) {
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
    final provider = _provider;
    _ratioListener = ImageStreamListener((info, _) {
      final ratio = info.image.width / info.image.height;
      info.dispose();
      if (_aspectRatio == ratio) return;
      _aspectRatio = ratio;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _provider == provider) widget.onAspectRatio?.call(ratio);
      });
    }, onError: (Object _, StackTrace? _) {});
    _ratioStream = _provider!.resolve(createLocalImageConfiguration(context))..addListener(_ratioListener!);
  }

  Widget _placeholder({bool failed = false}) {
    if (widget.generated && !failed) return GeneratedImageLoading(thumbnail: widget.thumbnailSize != null);
    return SizedBox(width: widget.thumbnailSize, height: widget.thumbnailSize ?? 96,
      child: Center(child: Semantics(label: failed ? 'Could not load image' : 'Loading image',
        child: widget.thumbnailSize != null || !failed
          ? Icon(failed ? Icons.broken_image_outlined : Icons.image_outlined, color: desktopTertiary, size: 16)
          : const Text('Could not load image', style: TextStyle(fontSize: 12, color: desktopSecondary)))));
  }

  Widget _image() {
    final provider = _provider;
    if (provider == null) return _placeholder(failed: true);
    return LayoutBuilder(builder: (context, constraints) {
      final ratio = MediaQuery.devicePixelRatioOf(context);
      final height = widget.thumbnailSize ?? widget.maxHeight ?? MediaQuery.sizeOf(context).height * .6;
      final width = widget.thumbnailSize ?? constraints.maxWidth;
      return ConstrainedBox(constraints: BoxConstraints(maxHeight: height), child: Image(
        image: ResizeImage(provider, width: width.isFinite ? (width * ratio).ceil() : null,
          height: (height * ratio).ceil(), policy: ResizeImagePolicy.fit),
        fit: widget.thumbnailSize != null && !widget.generated ? BoxFit.cover : BoxFit.contain,
        width: widget.thumbnailSize,
        height: widget.thumbnailSize,
        gaplessPlayback: true,
        semanticLabel: widget.label,
        frameBuilder: (_, child, frame, synchronous) =>
            synchronous || frame != null ? child : _placeholder(),
        errorBuilder: (_, _, _) => _placeholder(failed: true),
      ));
    });
  }

  PreviewImage? _previewImage() => _provider == null ? null : (provider: _provider!, label: widget.label);

  void _preview() {
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
      final previews = <PreviewImage>[];
      final ids = <String>[];
      for (final image in widget.previewImages) {
        final provider = conversationImageProvider(image.source, widget.directory);
        if (provider == null) continue;
        ids.add(image.id);
        previews.add((provider: provider, label: widget.label));
      }
      final initial = ids.indexOf(widget.previewID ?? '');
      if (initial < 0) return;
      widget.onPreview?.call();
      unawaited(showImagePreview(context, images: previews, initialIndex: initial));
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
    unawaited(showImagePreview(context, images: images.map((image) => image.$1).toList(growable: false), initialIndex: initial));
  }

  @override
  void dispose() {
    _lifetime.cancel();
    if (_ratioListener != null) _ratioStream?.removeListener(_ratioListener!);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = MouseRegion(cursor: _provider == null ? MouseCursor.defer : SystemMouseCursors.click,
      onEnter: widget.generated ? (_) => setState(() => _hovered = true) : null,
      onExit: widget.generated ? (_) => setState(() => _hovered = false) : null,
      child: GestureDetector(onTap: _provider == null ? null : widget.onOpen ?? _preview,
        onSecondaryTapUp: _provider == null ? null : (event) =>
          unawaited(showImageContextMenu(context, _provider!, event.globalPosition, _lifetime)),
        child: Tooltip(message: 'Open image', child: Semantics(button: _provider != null, label: widget.label,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(_radius),
            child: CustomPaint(painter: widget.generated && _hovered ? _TransparencyBackdrop() : null, child: _image()),
          )))));
    if (widget.thumbnailSize case final double side) {
      return SizedBox.square(dimension: side, child: widget.generated ? image : DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(_radius),
          border: Border.all(color: desktopBorderStrong)), child: Padding(padding: const EdgeInsets.all(1), child: image)));
    }
    return widget.markdown ? Padding(padding: const EdgeInsets.symmetric(vertical: 24), child: image) : image;
  }
}

class _TransparencyBackdrop extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = desktopSurface);
    final paint = Paint()..color = desktopSidebar;
    for (var y = 0; y * 18 < size.height; y++) {
      for (var x = 0; x * 18 < size.width; x++) {
        if ((x + y).isOdd) canvas.drawRect(Rect.fromLTWH(x * 18, y * 18, 18, 18), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_TransparencyBackdrop oldDelegate) => false;
}
