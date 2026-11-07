import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:protocol/protocol.dart';
import 'package:re_editor/re_editor.dart';

import 'appearance.dart';
import 'browser.dart';
import 'code_highlight.dart';
import 'conversation_markdown.dart';
import 'desktop_toast.dart';
import 'file_icon.dart';

typedef _FilePreview = ({String kind, String? text, int size, bool truncated});

const _previewLimit = 2 * 1024 * 1024;
const _imageExtensions = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'ico'};

String _extension(String path) => path.split('/').last.split('.').last.toLowerCase();
bool _isMarkdown(String path) => {'md', 'markdown', 'mdown', 'mkd'}.contains(_extension(path));
bool _isHtml(String path) => {'html', 'htm', 'xhtml'}.contains(_extension(path));

Future<_FilePreview> _readFilePreview(String path, CancellationToken cancellation) =>
  CancellableIsolate.run(() {
    final file = File(path), stat = file.statSync();
    if (stat.type == FileSystemEntityType.notFound) throw const FileSystemException('File not found');
    if (stat.type == FileSystemEntityType.directory) return (kind: 'directory', text: null, size: 0, truncated: false);
    if (stat.type != FileSystemEntityType.file) return (kind: 'binary', text: null, size: stat.size, truncated: false);
    final extension = _extension(path);
    if (_imageExtensions.contains(extension)) return (kind: 'image', text: null, size: stat.size, truncated: false);
    if (extension == 'svg') return (kind: 'svg', text: null, size: stat.size, truncated: false);
    if (extension == 'pdf') return (kind: 'pdf', text: null, size: stat.size, truncated: false);
    final kind = _isHtml(path) ? 'html' : 'text';
    final input = file.openSync();
    try {
      final bytes = input.readSync(_previewLimit + 1);
      final truncated = bytes.length > _previewLimit;
      final sample = truncated ? bytes.sublist(0, _previewLimit) : bytes;
      if (sample.contains(0)) return (kind: kind == 'html' ? 'html' : 'binary', text: null, size: stat.size, truncated: false);
      try {
        final text = StringBuffer();
        final decoder = utf8.decoder.startChunkedConversion(StringConversionSink.fromStringSink(text));
        decoder.add(sample);
        // An incomplete final UTF-8 character belongs to the omitted suffix.
        if (!truncated) decoder.close();
        return (kind: kind, text: text.toString(), size: stat.size, truncated: truncated);
      } on FormatException {
        return (kind: kind == 'html' ? 'html' : 'binary', text: null, size: stat.size, truncated: false);
      }
    } finally {
      input.closeSync();
    }
  }, cancellation);

Future<void> _revealFile(String path, CancellationToken cancellation) async {
  cancellation.throwIfCancelled();
  final process = await Process.start(Platform.isMacOS ? '/usr/bin/open' : 'xdg-open',
    Platform.isMacOS ? ['-R', path] : [File(path).parent.path]);
  final hook = CancellationHook(cancellation, process.kill);
  try {
    final results = await Future.wait<Object?>([
      process.exitCode,
      process.stdout.drain<Object?>(),
      process.stderr.drain<Object?>(),
    ]).asCancellable(cancellation);
    if (results.first != 0) throw const FileSystemException('Could not reveal file');
  } finally {
    hook.dispose();
  }
}

String _fileSize(int bytes) => bytes < 1024 ? '$bytes B'
  : bytes < 1024 * 1024 ? '${(bytes / 1024).toStringAsFixed(1)} KB'
  : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

String _fileLanguage(String path) {
  final name = path.split('/').last.toLowerCase();
  if (name == 'dockerfile') return 'dockerfile';
  return const {
    'tsx': 'typescript', 'jsx': 'javascript', 'mjs': 'javascript', 'cjs': 'javascript',
    'md': 'markdown', 'mdown': 'markdown', 'mkd': 'markdown', 'yml': 'yaml',
    'h': 'c', 'cc': 'cpp', 'hpp': 'cpp', 'cs': 'csharp', 'sh': 'bash', 'zsh': 'bash',
  }[_extension(path)] ?? _extension(path);
}

List<TextSpan> _highlightedLines(String text, String path) {
  final lines = <List<InlineSpan>>[[]];
  void append(TextSpan span, TextStyle inherited) {
    final style = inherited.merge(span.style), parts = (span.text ?? '').split('\n');
    for (var index = 0; index < parts.length; index++) {
      if (index > 0) lines.add([]);
      if (parts[index].isNotEmpty) lines.last.add(TextSpan(text: parts[index], style: style));
    }
    for (final child in span.children ?? const <InlineSpan>[]) {
      if (child is TextSpan) append(child, style);
    }
  }
  append(highlightedCode(text, language: _fileLanguage(path)), const TextStyle());
  return [for (final line in lines) TextSpan(children: line)];
}

class FileViewer extends StatefulWidget {
  const FileViewer({super.key, required this.path, this.line, this.directory, this.revealRequest = 0, this.active = true});
  final String path;
  final String? directory;
  final int? line;
  final int revealRequest;
  final bool active;

  @override
  State<FileViewer> createState() => _FileViewerState();
}

class _FileViewerState extends State<FileViewer> {
  final _lifetime = CancellationToken();
  final _scroll = CodeScrollController();
  late final _code = CodeLineEditingController(spanBuilder: _span);
  CancellationToken? _read;
  _FilePreview? _preview;
  List<TextSpan> _lines = [];
  bool _loading = false, _failed = false, _wrap = false, _source = false, _revealing = false;

  @override
  void initState() {
    super.initState();
    _source = widget.line != null;
    if (widget.active) unawaited(_load());
  }

  @override
  void didUpdateWidget(FileViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.active) {
      _read?.cancel();
      _loading = false;
    } else if (oldWidget.path != widget.path || !oldWidget.active && _preview == null) {
      unawaited(_load());
    } else if (oldWidget.revealRequest != widget.revealRequest && widget.line != null) {
      _source = true;
      _revealLine();
    }
  }

  Future<void> _load() async {
    _read?.cancel();
    final read = _read = CancellationToken();
    setState(() { _loading = true; _failed = false; });
    try {
      final preview = await _readFilePreview(widget.path, read);
      read.throwIfCancelled();
      if (!mounted) return;
      final text = preview.text?.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
      _lines = text == null ? [] : _highlightedLines(text, widget.path);
      _code.text = text ?? '';
      _code.clearHistory();
      setState(() { _preview = preview; _loading = false; });
      _revealLine();
    } on CancelledException {
      // Switching away or closing the tab releases its file read.
    } catch (_) {
      if (mounted && !read.isCancelled) setState(() { _failed = true; _loading = false; });
    }
  }

  TextSpan _span({required BuildContext context, required int index, required CodeLine codeLine,
      required TextSpan textSpan, required TextStyle style}) =>
    TextSpan(style: style, children: [index < _lines.length ? _lines[index] : textSpan]);

  void _revealLine() {
    if (widget.line == null || _preview?.text == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.active || _loading) return;
      final index = (widget.line! - 1).clamp(0, _code.lineCount - 1);
      _code.selection = CodeLineSelection(baseIndex: index, baseOffset: 0,
        extentIndex: index, extentOffset: _code.codeLines[index].length);
      _scroll.makeCenterIfInvisible(CodeLinePosition(index: index, offset: 0));
    });
  }

  Future<void> _reveal() async {
    if (_revealing) return;
    setState(() => _revealing = true);
    try {
      await _revealFile(widget.path, _lifetime);
    } on CancelledException {
      // The viewer was closed.
    } catch (_) {
      if (mounted) showDesktopToast(context, 'This file could not be revealed.', type: DesktopToastType.error);
    } finally {
      if (mounted) setState(() => _revealing = false);
    }
  }

  @override
  void dispose() {
    _read?.cancel();
    _lifetime.cancel();
    _code.dispose();
    _scroll.verticalScroller.dispose();
    _scroll.horizontalScroller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Widget _button(String label, IconData icon, VoidCallback? action, {bool selected = false}) =>
    SizedBox.square(dimension: 28, child: IconButton(tooltip: label, onPressed: action,
      isSelected: selected, padding: EdgeInsets.zero,
      style: IconButton.styleFrom(minimumSize: const Size.square(28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap),
      icon: Icon(icon, size: 16, color: selected ? desktopForeground : desktopSecondary)));

  Widget _notice(IconData icon, String title, {String? detail}) => Center(child: Padding(
    padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 32, color: desktopTertiary),
      const SizedBox(height: 16),
      Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: desktopSecondary)),
      if (detail != null) ...[const SizedBox(height: 8),
        Text(detail, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: desktopTertiary))],
      const SizedBox(height: 16),
      TextButton.icon(onPressed: _revealing ? null : _reveal, icon: const Icon(Icons.folder_open_outlined, size: 16),
        label: Text(Platform.isMacOS ? 'Reveal in Finder' : 'Reveal in File Manager')),
    ])));

  Widget _body() {
    if (_loading) return const Center(child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)));
    if (_failed) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        _notice(Icons.error_outline_rounded, 'Could not read this file.', detail: 'It may have moved or is no longer available.'),
        TextButton(onPressed: _load, child: const Text('Retry')),
      ]));
    }
    final preview = _preview;
    if (preview == null) return const SizedBox.shrink();
    if (preview.kind == 'directory') return _notice(Icons.folder_open_outlined, 'This path is a folder.');
    if (preview.kind == 'binary') {
      return _notice(Icons.insert_drive_file_outlined,
        'Preview is unavailable for this file type.', detail: _fileSize(preview.size));
    }
    if (preview.kind == 'pdf' || preview.kind == 'html' && (!_source || preview.text == null)) {
      return DesktopBrowser(key: ValueKey(widget.path), initialUrl: File(widget.path).absolute.uri.toString(),
        active: widget.active, toolbar: false, navigationEnabled: preview.kind != 'pdf', directory: widget.directory);
    }
    if (preview.kind == 'image' || preview.kind == 'svg') {
      Widget failed(BuildContext context, Object error, StackTrace? stack) {
        return _notice(Icons.broken_image_outlined, 'Could not load this image.');
      }
      return ClipRect(child: InteractiveViewer(minScale: .1, maxScale: 8,
        child: Center(child: Padding(padding: const EdgeInsets.all(24),
          child: preview.kind == 'svg' ? SvgPicture.file(File(widget.path), errorBuilder: failed)
            : Image.file(File(widget.path), fit: BoxFit.contain, errorBuilder: failed)))));
    }
    if (_isMarkdown(widget.path) && !_source && !preview.truncated) {
      return SingleChildScrollView(padding: const EdgeInsets.all(24),
        child: ConversationMarkdown(text: preview.text!, directory: File(widget.path).parent.path));
    }
    return CodeEditor(key: const ValueKey('file-source'), controller: _code, scrollController: _scroll,
      readOnly: true, showCursorWhenReadOnly: false, autofocus: false, wordWrap: _wrap,
      chunkAnalyzer: const NonCodeChunkAnalyzer(), padding: const EdgeInsets.fromLTRB(12, 12, 16, 12),
      style: CodeEditorStyle(fontFamily: desktopMonoFamily, fontSize: 13, fontHeight: 20 / 13,
        textColor: desktopForeground, backgroundColor: desktopSurface, cursorLineColor: desktopMuted,
        selectionColor: DesktopAccent.of(context).selection),
      indicatorBuilder: (context, controller, _, notifier) => Padding(
        padding: const EdgeInsets.only(left: 8, right: 8),
        child: DefaultCodeLineNumber(controller: controller, notifier: notifier,
          textStyle: const TextStyle(fontFamily: desktopMonoFamily, fontSize: 12, height: 20 / 12, color: desktopTertiary),
          focusedTextStyle: const TextStyle(fontFamily: desktopMonoFamily, fontSize: 12, height: 20 / 12, color: desktopSecondary))));
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview, text = preview?.text;
    final canPreviewMarkdown = text != null && _isMarkdown(widget.path) && !preview!.truncated;
    final canPreviewHtml = text != null && preview?.kind == 'html';
    final canPreview = canPreviewMarkdown || canPreviewHtml;
    final source = text != null && (!canPreview || _source);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(height: 44, padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: desktopBorder, width: .5))),
        child: Row(children: [
          Expanded(child: Tooltip(message: widget.path, child: Text(widget.path,
            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: desktopSecondary)))),
          const SizedBox(width: 8),
          _button(Platform.isMacOS ? 'Reveal in Finder' : 'Reveal in File Manager',
            Icons.folder_open_outlined, _revealing ? null : _reveal),
          if (canPreview) _button(_source ? 'Show ${canPreviewHtml ? 'HTML' : 'Markdown'} preview' : 'Show source',
            _source ? Icons.visibility_outlined : Icons.code_rounded, () {
              setState(() => _source = !_source);
            }, selected: !_source),
          if (source) ...[
            _button(_wrap ? 'Scroll long lines' : 'Wrap long lines', Icons.wrap_text_rounded,
              () => setState(() => _wrap = !_wrap), selected: _wrap),
            ConversationCopyButton(text: text, label: 'Copy file contents', compact: true),
          ],
          _button('Reload file', Icons.refresh_rounded, _loading ? null : _load),
        ])),
      if (source && preview?.truncated == true) Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        color: desktopMuted, child: const Text('Showing the first 2 MB of this file.',
          style: TextStyle(fontSize: 12, color: desktopSecondary))),
      Expanded(child: _body()),
      if (preview != null && !_loading && !_failed) Container(height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: const BoxDecoration(border: Border(top: BorderSide(color: desktopBorder, width: .5))),
        child: Row(children: [
          FileIcon(widget.path, size: 12), const SizedBox(width: 6),
          if (source) Text('${_code.lineCount} lines', style: const TextStyle(fontSize: 11, color: desktopTertiary)),
          const Spacer(),
          Text(_fileSize(preview.size), style: const TextStyle(fontSize: 11, color: desktopTertiary)),
        ])),
    ]);
  }
}
