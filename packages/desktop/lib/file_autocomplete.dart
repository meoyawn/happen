import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

typedef _Mention = ({int start, int end, String query});

/// Completes the @ token at the caret; the rest of the draft remains editable text.
class FileAutocomplete extends StatefulWidget {
  const FileAutocomplete({super.key, required this.controller, required this.focusNode,
    required this.client, required this.cwd, required this.enabled, required this.child});

  final TextEditingController controller;
  final FocusNode focusNode;
  final AgentClient client;
  final String cwd;
  final bool enabled;
  final Widget child;

  @override
  State<FileAutocomplete> createState() => _FileAutocompleteState();
}

class _FileAutocompleteState extends State<FileAutocomplete> {
  final _link = LayerLink();
  final _overlay = OverlayPortalController();
  final _scroll = ScrollController();
  final _cache = <String, ({Json result, DateTime time})>{};
  Timer? _debounce;
  CancellationToken? _search;
  _Mention? _mention, _dismissed;
  List<String> _paths = [];
  int _selected = 0;
  bool _loading = false, _failed = false, _truncated = false, _overlayScheduled = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    widget.focusNode.addListener(_changed);
  }

  @override
  void didUpdateWidget(FileAutocomplete oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_changed);
      widget.focusNode.addListener(_changed);
    }
    if (oldWidget.cwd != widget.cwd || oldWidget.client != widget.client ||
        oldWidget.enabled != widget.enabled || oldWidget.controller != widget.controller) {
      _cancel();
      _cache.clear();
      _mention = null;
      _dismissed = null;
      _paths = [];
      _changed();
    }
  }

  void _cancel() {
    _debounce?.cancel();
    _debounce = null;
    _search?.cancel();
    _search = null;
  }

  void _changed() {
    final next = widget.enabled && widget.focusNode.hasFocus
        ? _mentionAt(widget.controller.value) : null;
    if (next == _dismissed && next != null) return;
    if (next == _mention) return;
    _dismissed = null;
    _cancel();
    setState(() {
      _mention = next;
      _paths = [];
      _selected = 0;
      _failed = false;
      _loading = next != null;
      _truncated = false;
    });
    if (next == null) return;
    final cached = _cache.remove(next.query);
    if (cached != null && DateTime.now().difference(cached.time) < const Duration(seconds: 10)) {
      _cache[next.query] = cached;
      _apply(cached.result);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 200), () => unawaited(_lookup(next)));
  }

  Future<void> _lookup(_Mention mention) async {
    final token = _search = CancellationToken();
    try {
      final result = await widget.client.searchFiles(widget.cwd, mention.query, cancellation: token);
      if (!mounted || token.isCancelled || _mention != mention) return;
      _cache[mention.query] = (result: result, time: DateTime.now());
      while (_cache.length > 20) {
        _cache.remove(_cache.keys.first);
      }
      _apply(result);
    } on CancelledException {
      // A new token, focus change, disconnect, or disposal owns cancellation.
    } catch (_) {
      if (mounted && !token.isCancelled && _mention == mention) {
        setState(() { _loading = false; _failed = true; });
      }
    } finally {
      if (identical(_search, token)) _search = null;
    }
  }

  void _apply(Json result) {
    setState(() {
      _paths = (result['paths'] as List).cast<String>();
      _loading = false;
      _failed = false;
      _truncated = result['truncated'] == true;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _dismiss() {
    _cancel();
    setState(() { _dismissed = _mention; _mention = null; _paths = []; });
  }

  void _updateOverlay() {
    if (_overlayScheduled || _overlay.isShowing == (_mention != null)) return;
    _overlayScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _overlayScheduled = false;
      if (!mounted) return;
      if (_mention != null) {
        _overlay.show();
      } else {
        _overlay.hide();
      }
    });
  }

  void _move(int offset) {
    setState(() => _selected = (_selected + offset) % _paths.length);
    if (!_scroll.hasClients) return;
    final top = 4 + _selected * 44.0;
    final bottom = top + 44;
    if (top < _scroll.offset) {
      _scroll.jumpTo(top);
    } else if (bottom > _scroll.offset + _scroll.position.viewportDimension) {
      _scroll.jumpTo(bottom - _scroll.position.viewportDimension);
    }
  }

  void _choose(String path) {
    final mention = _mention;
    if (mention == null || _mentionAt(widget.controller.value) != mention) return;
    final text = widget.controller.text;
    final reference = '@${path.contains(RegExp(r'[\s@"\\()\[\]{}]')) ? jsonEncode(path) : path}';
    final suffix = text.substring(mention.end);
    final replacement = '$reference${suffix.startsWith(' ') ? '' : ' '}';
    _dismiss();
    widget.controller.value = TextEditingValue(
      text: text.replaceRange(mention.start, mention.end, replacement),
      selection: TextSelection.collapsed(offset: mention.start + reference.length + 1),
    );
    widget.focusNode.requestFocus();
  }

  @override
  void dispose() {
    _cancel();
    widget.controller.removeListener(_changed);
    widget.focusNode.removeListener(_changed);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _mention != null;
    _updateOverlay();
    return CallbackShortcuts(
      bindings: {
        if (visible) ...{
          const SingleActivator(LogicalKeyboardKey.escape): _dismiss,
          const SingleActivator(LogicalKeyboardKey.enter, includeRepeats: false): () {
            if (_paths.isNotEmpty) {
              _choose(_paths[_selected]);
            } else if (!_loading) {
              _dismiss();
            }
          },
          if (_paths.isNotEmpty) ...{
            const SingleActivator(LogicalKeyboardKey.tab): () => _choose(_paths[_selected]),
            const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
            const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
          },
        },
      },
      child: LayoutBuilder(
        builder: (context, constraints) => OverlayPortal(
          controller: _overlay,
          overlayChildBuilder: (context) => visible ? Positioned(
            width: constraints.maxWidth - 26,
            child: CompositedTransformFollower(
              link: _link,
              targetAnchor: Alignment.topLeft,
              followerAnchor: Alignment.bottomLeft,
              offset: const Offset(13, -4),
              showWhenUnlinked: false,
              child: TextFieldTapRegion(child: _menu(context)),
            ),
          ) : const SizedBox.shrink(),
          child: CompositedTransformTarget(link: _link, child: widget.child),
        ),
      ),
    );
  }

  Widget _menu(BuildContext context) => Material(
    color: Colors.white,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: const BorderSide(color: Color(0xffdaddd5)),
    ),
    clipBehavior: Clip.antiAlias,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 320),
      child: Scrollbar(
        controller: _scroll,
        child: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.all(4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var index = 0; index < _paths.length; index++)
                Semantics(
                  selected: index == _selected,
                  child: MouseRegion(
                    onEnter: (_) => setState(() => _selected = index),
                    child: InkWell(
                      canRequestFocus: false,
                      onTap: () => _choose(_paths[index]),
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        height: 44,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          color: index == _selected
                              ? Theme.of(context).colorScheme.secondaryContainer
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(children: [
                          Icon(_paths[index].endsWith('/')
                              ? Icons.folder_outlined : Icons.insert_drive_file_outlined, size: 16),
                          const SizedBox(width: 8),
                          Expanded(child: Text(_paths[index], maxLines: 1, overflow: TextOverflow.ellipsis)),
                        ]),
                      ),
                    ),
                  ),
                ),
              if (_paths.isEmpty || _truncated)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  child: _failed
                      ? TextButton(onPressed: () {
                          final mention = _mention!;
                          setState(() { _failed = false; _loading = true; });
                          unawaited(_lookup(mention));
                        }, child: const Text('File search unavailable. Retry'))
                      : Text(_loading ? 'Searching files and folders…' : _paths.isEmpty
                          ? 'No matching files or folders' : 'Type more to narrow the results',
                          style: Theme.of(context).textTheme.bodySmall),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

_Mention? _mentionAt(TextEditingValue value) {
  final selection = value.selection;
  if (!selection.isValid || !selection.isCollapsed || !value.composing.isCollapsed) return null;
  final caret = selection.baseOffset, text = value.text;
  if (caret == 0 || caret > text.length) return null;
  final start = text.lastIndexOf('@', caret - 1);
  if (start < 0 || (start > 0 && !RegExp(r'[\s(\[{]').hasMatch(text[start - 1]))) return null;
  var end = start + 1;
  String query;
  if (end < text.length && text[end] == '"') {
    final from = ++end;
    var escaped = false;
    while (end < text.length) {
      final character = text[end];
      if (!escaped && character == '"') break;
      if (character == '\n' || character == '\r') break;
      escaped = !escaped && character == '\\';
      end++;
    }
    if (caret < from || caret > end) return null;
    query = text.substring(from, caret).replaceAllMapped(RegExp(r'\\(.)'), (match) => match[1]!);
    if (end < text.length && text[end] == '"') end++;
  } else {
    while (end < text.length && !RegExp(r'[\s@"\)\]}]').hasMatch(text[end])) {
      end++;
    }
    if (caret > end) return null;
    query = text.substring(start + 1, caret);
  }
  if (query.length > 256) return null;
  return (start: start, end: end, query: query);
}
