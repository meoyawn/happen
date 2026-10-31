import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

import 'composer_text_controller.dart';
import 'mcp_menu.dart';

typedef _Mention = ({int start, int end, String query});
typedef _Command = ({int start, int end, String text});

/// One popover and input owner for file mentions and local slash commands.
class ComposerAutocomplete extends StatefulWidget {
  const ComposerAutocomplete({super.key, required this.controller, required this.focusNode,
    required this.client, required this.cwd, required this.enabled, required this.child});

  final TextEditingController controller;
  final FocusNode focusNode;
  final AgentClient client;
  final String cwd;
  final bool enabled;
  final Widget child;

  @override
  State<ComposerAutocomplete> createState() => ComposerAutocompleteState();
}

class ComposerAutocompleteState extends State<ComposerAutocomplete> {
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
  _Command? _command;
  TextEditingValue? _dismissedCommand;
  int? _mcpAnchor;
  String _mcpPrefix = '', _mcpFilter = '';
  bool _verbose = false, _mcpLoading = false, _mcpFailed = false, _changing = false;
  Json? _inventory;
  CancellationToken? _mcpRequest;
  StreamSubscription<Json>? _mcpEvents;
  static const _commands = [
    (name: '/mcp', description: 'Show MCP server status'),
    (name: '/mcp verbose', description: 'Show MCP tools and resources'),
  ];
  bool get _visible => _mention != null || _command != null || _mcpAnchor != null;
  List<({String name, String description})> get _suggestions => [
    for (final command in _commands)
      if (command.name.startsWith(_normalizedCommand(_command?.text ?? ''))) command,
  ];

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    widget.focusNode.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _changed(); });
  }

  @override
  void didUpdateWidget(ComposerAutocomplete oldWidget) {
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
      _closeMcp();
      _cache.clear();
      _mention = null;
      _dismissed = null;
      _command = null;
      _dismissedCommand = null;
      _paths = [];
      _changed();
    }
  }

  @override
  void reassemble() {
    super.reassemble();
    if (_mcpAnchor != null) unawaited(_loadMcp());
  }

  void _closeMcp() {
    _mcpRequest?.cancel();
    _mcpRequest = null;
    unawaited(_mcpEvents?.cancel());
    _mcpEvents = null;
    _mcpAnchor = null;
    _inventory = null;
  }

  void _cancel() {
    _debounce?.cancel();
    _debounce = null;
    _search?.cancel();
    _search = null;
  }

  void _changed() {
    if (_changing) return;
    final value = widget.controller.value;
    final usable = widget.enabled && widget.focusNode.hasFocus && value.selection.isValid &&
        value.selection.isCollapsed && value.composing.isCollapsed;
    final wasMcp = _mcpAnchor != null || _command != null;
    if (_mcpAnchor case final start?) {
      final end = value.selection.extentOffset;
      final query = usable && end >= start && value.text.startsWith(_mcpPrefix)
          ? value.text.substring(start, end) : null;
      // A new trigger or newline replaces the synthetic filter scope.
      if (query != null && !RegExp(r'[\n\r\uFFFC]|(?:^|[\s(\[{])[/@$>]').hasMatch(query)) {
        final matches = (_inventory?['servers'] as List? ?? []).map(jsonObject).where((server) => mcpMatches(server, query));
        if (_mcpLoading || query.trim().isEmpty || !query.contains(RegExp(r'\s')) || matches.isNotEmpty) {
          setState(() => _mcpFilter = query);
          return;
        }
      }
      _closeMcp();
    }
    final command = usable ? _commandAt(value) : null;
    final next = usable ? _mentionAt(value) : null;
    if (command != null && (next == null || command.start > next.start)) {
      if (command == _command) return;
      _cancel();
      setState(() {
        _mention = null;
        _paths = [];
        _command = value == _dismissedCommand ? null : command;
        _selected = 0;
      });
      return;
    }
    _command = null;
    if (next == _dismissed && next != null) return;
    if (next == _mention) {
      if (wasMcp) setState(() {});
      return;
    }
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

  /// The send button and modified Enter run commands locally as well.
  bool consumeCommand() {
    final value = widget.controller.value;
    if (!widget.enabled || !value.composing.isCollapsed) return false;
    // Submission can happen with the whole pasted command still selected.
    final command = _commandAt(value) ?? (RegExp(r'^\s*/mcp(?:\s|$)', caseSensitive: false).hasMatch(value.text)
        ? (start: value.text.indexOf('/'), end: value.text.length, text: value.text.trim()) : null);
    if (command == null) return false;
    final text = _normalizedCommand(command.text);
    if (text != '/mcp' && text != '/mcp verbose') {
      setState(() => _command = command);
      return true;
    }
    _activateMcp(command, text == '/mcp verbose');
    return true;
  }

  void _chooseCommand() {
    final suggestions = _suggestions;
    if (_command == null || suggestions.isEmpty) return;
    _activateMcp(_command!, suggestions[_selected.clamp(0, suggestions.length - 1)].name == '/mcp verbose');
  }

  void _activateMcp(_Command command, bool verbose) {
    _cancel();
    _closeMcp();
    _changing = true;
    final value = widget.controller.value;
    widget.controller.value = value.copyWith(text: value.text.replaceRange(command.start, command.end, ''),
      selection: TextSelection.collapsed(offset: command.start), composing: TextRange.empty);
    _changing = false;
    setState(() {
      _mention = null;
      _paths = [];
      _command = null;
      _dismissed = null;
      _dismissedCommand = null;
      _mcpAnchor = command.start;
      _mcpPrefix = widget.controller.text.substring(0, command.start);
      _mcpFilter = '';
      _verbose = verbose;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _mcpEvents = widget.client.events.stream.listen((event) {
      if (event['type'] == 'mcp.config.reloaded' || event['type'] == 'mcp.config.error') unawaited(_loadMcp());
    }, onDone: () {
      _mcpRequest?.cancel();
      if (mounted && _mcpAnchor != null) setState(() { _mcpLoading = false; _mcpFailed = true; });
    });
    unawaited(_loadMcp());
    widget.focusNode.requestFocus();
  }

  Future<void> _loadMcp() async {
    _mcpRequest?.cancel();
    final token = _mcpRequest = CancellationToken();
    setState(() { _mcpLoading = true; _mcpFailed = false; });
    try {
      final result = await widget.client.mcpInventory(verbose: _verbose, cancellation: token);
      if (!mounted || token.isCancelled || _mcpAnchor == null) return;
      setState(() { _inventory = result; _mcpLoading = false; });
      _changed();
    } on CancelledException {
      // Closing, navigation, newer discovery or disconnect owns the request.
    } catch (_) {
      if (mounted && !token.isCancelled && _mcpAnchor != null) setState(() { _mcpLoading = false; _mcpFailed = true; });
    } finally {
      if (identical(_mcpRequest, token)) _mcpRequest = null;
    }
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

  void dismiss() {
    _cancel();
    _closeMcp();
    setState(() {
      _dismissed = _mention;
      _dismissedCommand = widget.controller.value;
      _mention = null;
      _command = null;
      _paths = [];
    });
  }

  void _updateOverlay() {
    if (_overlayScheduled || _overlay.isShowing == _visible) return;
    _overlayScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _overlayScheduled = false;
      if (!mounted) return;
      if (_visible) {
        _overlay.show();
      } else {
        _overlay.hide();
      }
    });
  }

  void _move(int offset) {
    final count = _command != null ? _suggestions.length : _paths.length;
    setState(() => _selected = (_selected + offset) % count);
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
    final controller = widget.controller;
    if (controller is! ComposerTextController) return;
    dismiss();
    controller.insertFile(TextRange(start: mention.start, end: mention.end), path);
    widget.focusNode.requestFocus();
  }

  @override
  void dispose() {
    _cancel();
    _closeMcp();
    widget.controller.removeListener(_changed);
    widget.focusNode.removeListener(_changed);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    _updateOverlay();
    return CallbackShortcuts(
      bindings: {
        if (visible) ...{
          const SingleActivator(LogicalKeyboardKey.escape): dismiss,
          const SingleActivator(LogicalKeyboardKey.enter, includeRepeats: false): () {
            if (_command != null) {
              _chooseCommand();
            } else if (_mcpAnchor != null) {
              return;
            } else if (_paths.isNotEmpty) {
              _choose(_paths[_selected]);
            } else if (!_loading) {
              dismiss();
            }
          },
          if (_mcpAnchor != null) ...{
            const SingleActivator(LogicalKeyboardKey.tab): () {},
            if (_mcpFilter.isEmpty) const SingleActivator(LogicalKeyboardKey.backspace): dismiss,
          },
          if (_paths.isNotEmpty || _command != null && _suggestions.isNotEmpty) ...{
            const SingleActivator(LogicalKeyboardKey.tab): () {
              if (_command != null) { _chooseCommand(); } else { _choose(_paths[_selected]); }
            },
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
              if (_command != null) ...[
                for (var index = 0; index < _suggestions.length; index++)
                  Semantics(selected: index == _selected, child: MouseRegion(
                    onEnter: (_) => setState(() => _selected = index),
                    child: InkWell(canRequestFocus: false, onTap: () { _selected = index; _chooseCommand(); },
                      borderRadius: BorderRadius.circular(12),
                      child: Container(height: 44, padding: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(color: index == _selected ? Theme.of(context).colorScheme.secondaryContainer : null,
                          borderRadius: BorderRadius.circular(12)),
                        child: Row(children: [
                          const Icon(Icons.extension_outlined, size: 16), const SizedBox(width: 8),
                          Text(_suggestions[index].name), const SizedBox(width: 8),
                          Expanded(child: Text(_suggestions[index].description, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Colors.black54))),
                          const Icon(Icons.chevron_right_rounded, size: 16, color: Colors.black54),
                        ])),
                    ),
                  )),
                if (_suggestions.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('Usage: /mcp [verbose]')),
              ] else if (_mcpAnchor != null)
                McpStatusMenu(inventory: _inventory, verbose: _verbose, loading: _mcpLoading, failed: _mcpFailed,
                  query: _mcpFilter, onRetry: () => unawaited(_loadMcp()))
              else ...[
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
    while (end < text.length && text[end] != ComposerTextController.marker && !RegExp(r'[\s@"\)\]}]').hasMatch(text[end])) {
      end++;
    }
    if (caret > end) return null;
    query = text.substring(start + 1, caret);
  }
  if (query.length > 256) return null;
  return (start: start, end: end, query: query);
}

_Command? _commandAt(TextEditingValue value) {
  if (!value.selection.isValid || !value.selection.isCollapsed || !value.composing.isCollapsed) return null;
  final end = value.selection.extentOffset;
  final prefix = value.text.substring(0, end);
  if ('```'.allMatches(prefix).length.isOdd) return null;
  final line = prefix.substring(prefix.lastIndexOf('\n') + 1);
  if ('`'.allMatches(line).length.isOdd) return null;
  final match = RegExp(r'(?:^|[\s(\[{])(/[A-Za-z]*(?:[ \t]+[^\n/@$>\uFFFC]*)?)$').firstMatch(line);
  if (match == null) return null;
  final text = match[1]!;
  final query = _normalizedCommand(text);
  if (!'/mcp'.startsWith(query) && !query.startsWith('/mcp ')) return null;
  return (start: end - text.length, end: end, text: text);
}

String _normalizedCommand(String text) => text.trimRight().toLowerCase().replaceAll(RegExp(r'[ \t]+'), ' ');
