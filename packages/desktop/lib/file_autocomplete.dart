import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:re_editor/re_editor.dart' show CodeEditorTapRegion;

import 'composer_text_controller.dart';
import 'file_icon.dart';
import 'inline_reference.dart';
import 'mcp_menu.dart';
import 'mcp_auth.dart';
import 'session.dart';

typedef _Mention = ({int start, int end, String query});
typedef _Command = ({int start, int end, String text});
typedef _ContextOption = ({String kind, String label, String description, String path});

class ComposerAutocompleteScope extends InheritedWidget {
  const ComposerAutocompleteScope({super.key, required this.visible, this.owner, required super.child});
  final bool visible;
  final ComposerAutocompleteState? owner;
  static bool of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ComposerAutocompleteScope>()?.visible ?? false;
  static ComposerAutocompleteState? ownerOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ComposerAutocompleteScope>()?.owner;
  @override
  bool updateShouldNotify(ComposerAutocompleteScope oldWidget) => visible != oldWidget.visible;
}

typedef ComposerCommand = ({String description, VoidCallback run});

/// One popover and input owner for file/skill mentions and local slash commands.
class ComposerAutocomplete extends StatefulWidget {
  const ComposerAutocomplete({super.key, required this.controller, required this.focusNode,
    required this.client, required this.cwd, required this.enabled, required this.child,
    this.session, this.commands = const {}});

  final TextEditingController controller;
  final FocusNode focusNode;
  final AgentClient client;
  final String cwd;
  final bool enabled;
  final Widget child;
  final DesktopSession? session;
  final Map<String, ComposerCommand> commands;

  @override
  State<ComposerAutocomplete> createState() => ComposerAutocompleteState();
}

class ComposerAutocompleteState extends State<ComposerAutocomplete> {
  final _link = LayerLink();
  final _overlay = OverlayPortalController();
  final _scroll = ScrollController();
  final _historyQuery = TextEditingController();
  final _historyFocus = FocusNode();
  List<String> _history = [];
  bool _historyOpen = false;
  final _cache = <String, ({Json result, DateTime time})>{};
  Timer? _debounce;
  CancellationToken? _search;
  _Mention? _mention, _dismissed;
  List<String> _paths = [];
  List<Json> _skills = [];
  CancellationToken? _skillSearch;
  bool _skillsLoading = false, _skillsFailed = false, _skillsTruncated = false;
  int _selected = 0;
  bool _loading = false, _failed = false, _truncated = false, _overlayScheduled = false;
  _Command? _command;
  TextEditingValue? _dismissedCommand;
  int? _mcpAnchor;
  String _mcpPrefix = '', _mcpFilter = '';
  bool _verbose = false, _mcpLoading = false, _mcpFailed = false, _changing = false;
  String? _syntaxPrefix;
  bool _insideFence = false;
  Json? _inventory;
  Json? _catalog;
  DateTime? _catalogTime;
  CancellationToken? _catalogSearch, _contextAction;
  TextEditingValue? _contextDraft;
  CancellationToken? _mcpRequest;
  StreamSubscription<Json>? _mcpEvents;
  List<({String name, String description})> get _commands => [
    (name: '/mcp', description: 'Show MCP server status'),
    (name: '/mcp verbose', description: 'Show MCP tools and resources'),
    if (widget.session case final session?) ...[
      if (session.task == null)
        for (final model in session.models)
          (name: '/model ${model['id']}', description: model['provider'] as String? ?? 'Choose model'),
      if (session.task == null || session.task!.reasoningUpdates)
        for (final level in session.modelInfo?['reasoning_levels'] as List? ?? [])
          (name: '/reasoning $level', description: 'Set reasoning effort'),
    ],
    for (final entry in widget.commands.entries)
      (name: entry.key, description: entry.value.description),
  ];
  bool get _visible => _historyOpen || _mention != null || _command != null || _mcpAnchor != null;
  List<({String name, String description})> get _suggestions => [
    for (final command in _commands)
      if (_fuzzyMatch(command.name, _normalizedCommand(_command?.text ?? ''))) command,
  ];
  int get _choiceCount => _historyOpen ? _historyItems.length :
    (_command != null ? _suggestions.length : _paths.length) + _skills.length + _contextOptions.length;
  List<String> get _historyItems => _historyQuery.text.isEmpty ? _history :
    _history.where((text) => _fuzzyMatch(text, _historyQuery.text)).toList();
  bool get _skillsOnly => _mention != null && widget.controller.text[_mention!.start] == r'$';
  List<_ContextOption> get _contextOptions {
    final mention = _mention;
    if (mention == null || _skillsOnly) return const [];
    final options = <_ContextOption>[
      for (final project in widget.session?.projects ?? <Project>[])
        if (project.available) (kind: 'project', label: project.name, description: project.path, path: '${project.path}/'),
      for (final task in (widget.session?.project?.tasks ?? <DesktopTask>[])
          .where((task) => !task.archived && task != widget.session?.task && _fuzzyMatch(task.title, mention.query))
          .take(mention.query.isEmpty ? 5 : 8))
        (kind: 'session', label: task.title, description: 'Session context', path: task.id),
      for (final raw in _catalog?['servers'] as List? ?? [])
        for (final resource in jsonObject(raw)['resources'] as List? ?? [])
          (kind: 'resource', label: '${raw['name']}:${resource['title'] ?? resource['name'] ?? resource['uri']}',
            description: resource['description'] as String? ?? 'MCP resource', path: resource['uri'] as String),
      for (final raw in _catalog?['servers'] as List? ?? [])
        for (final tool in jsonObject(raw)['tools'] as List? ?? [])
          (kind: 'tool', label: '$tool', description: '${raw['name']} · MCP tool', path: '$tool'),
    ];
    return options.where((item) => _fuzzyMatch('${item.label} ${item.description}', mention.query)).take(50).toList();
  }

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
      _historyOpen = false;
      _historyQuery.clear();
      _catalogSearch?.cancel();
      _catalog = null;
      _catalogTime = null;
      _mention = null;
      _dismissed = null;
      _command = null;
      _dismissedCommand = null;
      _paths = [];
      _skills = [];
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
    _skillSearch?.cancel();
    _skillSearch = null;
    _contextAction?.cancel();
    _contextAction = null;
    _contextDraft = null;
  }

  void _changed() {
    if (_changing) return;
    final value = widget.controller.value;
    if (_historyOpen) {
      if (!widget.enabled) dismiss();
      return;
    }
    if (_contextAction != null && (value != _contextDraft || !widget.focusNode.hasFocus)) {
      _contextAction?.cancel();
      _contextAction = null;
      _contextDraft = null;
    }
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
    var next = usable ? _mentionAt(value) : null;
    final trigger = next?.start ?? command?.start;
    if (trigger != null) {
      if (_syntaxPrefix == null || _syntaxPrefix!.length != trigger || !value.text.startsWith(_syntaxPrefix!)) {
        _syntaxPrefix = value.text.substring(0, trigger);
        _insideFence = RegExp(r'^\s*(```|~~~)', multiLine: true).allMatches(_syntaxPrefix!).length.isOdd;
      }
      if (_insideFence) next = null;
    }
    if (command != null && !_insideFence && (next == null || command.start > next.start)) {
      if (command == _command) return;
      _cancel();
      _catalogSearch?.cancel();
      _catalogSearch = null;
      setState(() {
        _mention = null;
        _paths = [];
        _skills = [];
        _skillsLoading = value != _dismissedCommand;
        _skillsFailed = false;
        _skillsTruncated = false;
        _command = value == _dismissedCommand ? null : command;
        _selected = 0;
      });
      if (_command != null) {
        _debounce = Timer(const Duration(milliseconds: 200),
          () => unawaited(_lookupSkills(command.text.substring(1))));
      }
      return;
    }
    _command = null;
    if (next == _dismissed && next != null) return;
    if (next == _mention && !wasMcp) {
      if (next == null) { _dismissed = null; _dismissedCommand = null; }
      return;
    }
    _dismissed = null;
    _cancel();
    setState(() {
      _mention = next;
      _paths = [];
      _skills = [];
      _selected = 0;
      _failed = false;
      _loading = next != null && !_skillsOnly;
      _skillsLoading = next != null;
      _skillsFailed = false;
      _skillsTruncated = false;
      _truncated = false;
    });
    if (next == null) {
      _catalogSearch?.cancel();
      _catalogSearch = null;
      return;
    }
    final cached = _cache.remove('files:${next.query}');
    if (!_skillsOnly && cached != null && DateTime.now().difference(cached.time) < const Duration(seconds: 10)) {
      _cache['files:${next.query}'] = cached;
      _apply(cached.result);
    }
    final mention = next;
    _debounce = Timer(const Duration(milliseconds: 120), () {
      if (_loading) unawaited(_lookup(mention));
      unawaited(_lookupSkills(mention.query));
      if (!_skillsOnly) unawaited(_loadCatalog());
    });
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
    final local = _commands.where((item) => item.name.toLowerCase() == text).firstOrNull;
    if (local != null && !text.startsWith('/mcp')) {
      _runCommand(command, local.name);
      return true;
    }
    if (!RegExp(r'^/mcp(?:\s|$)').hasMatch(text)) return false;
    if (text != '/mcp' && text != '/mcp verbose') {
      setState(() => _command = command);
      return true;
    }
    _activateMcp(command, text == '/mcp verbose');
    return true;
  }

  void _chooseCommand() {
    final suggestions = _suggestions;
    if (_command == null) return;
    if (_selected >= suggestions.length) { _chooseSkill(_skills[_selected - suggestions.length]); return; }
    if (suggestions.isEmpty) return;
    _runCommand(_command!, suggestions[_selected.clamp(0, suggestions.length - 1)].name);
  }

  void _runCommand(_Command command, String name) {
    if (name == '/mcp' || name == '/mcp verbose') { _activateMcp(command, name == '/mcp verbose'); return; }
    dismiss();
    final value = widget.controller.value;
    widget.controller.value = value.copyWith(text: value.text.replaceRange(command.start, command.end, ''),
      selection: TextSelection.collapsed(offset: command.start), composing: TextRange.empty);
    widget.focusNode.requestFocus();
    if (name.startsWith('/model ')) { widget.session?.chooseModel(name.substring(7)); }
    else if (name.startsWith('/reasoning ')) { widget.session?.chooseReasoning(name.substring(11)); }
    else { widget.commands[name]?.run(); }
  }

  void openContext() => _insertTrigger('@');
  void openCommands() => _insertTrigger('/');
  void openHistory() {
    final entries = <String>[];
    for (final message in widget.session?.task?.messages.values ?? <Json>[]) {
      if (message['type'] != 'user') continue;
      final text = message['text'];
      if (text is String && text.isNotEmpty) entries.add(text);
    }
    dismiss();
    setState(() {
      _history = entries.reversed.toSet().take(100).toList();
      _historyOpen = true;
      _historyQuery.clear();
      _selected = 0;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted && _historyOpen) _historyFocus.requestFocus(); });
  }
  void _insertTrigger(String trigger) {
    final value = widget.controller.value;
    final selection = value.selection.isValid ? value.selection : TextSelection.collapsed(offset: value.text.length);
    final prefix = selection.start > 0 && !RegExp(r'\s').hasMatch(value.text[selection.start - 1]) ? ' ' : '';
    widget.focusNode.requestFocus();
    widget.controller.value = TextEditingValue(text: value.text.replaceRange(selection.start, selection.end, '$prefix$trigger'),
      selection: TextSelection.collapsed(offset: selection.start + prefix.length + 1));
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
      _skills = [];
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
      if (event['type'] == 'mcp.config.reloaded' || event['type'] == 'mcp.config.error' || event['type'] == 'mcp.auth.changed') unawaited(_loadMcp());
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
      _cache['files:${mention.query}'] = (result: result, time: DateTime.now());
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

  Future<void> _lookupSkills(String query) async {
    final token = _skillSearch = CancellationToken();
    try {
      final key = 'skills:$query';
      final cached = _cache.remove(key);
      final result = cached != null && DateTime.now().difference(cached.time) < const Duration(seconds: 10)
          ? cached.result : await widget.client.searchSkills(widget.cwd, query, cancellation: token);
      if (!mounted || token.isCancelled || !identical(_skillSearch, token)) return;
      _cache[key] = (result: result, time: DateTime.now());
      while (_cache.length > 20) { _cache.remove(_cache.keys.first); }
      setState(() {
        _skills = (result['skills'] as List).map(jsonObject).toList();
        _skillsLoading = false;
        _skillsFailed = false;
        _skillsTruncated = result['truncated'] == true;
        _selected = _selected.clamp(0, (_choiceCount - 1).clamp(0, _choiceCount));
      });
      if (_selected == 0 && _scroll.hasClients) _scroll.jumpTo(0);
    } on CancelledException {
      // Navigation, dismissal or a newer query owns cancellation.
    } catch (_) {
      if (mounted && !token.isCancelled && identical(_skillSearch, token)) {
        setState(() { _skillsLoading = false; _skillsFailed = true; });
      }
    } finally {
      if (identical(_skillSearch, token)) _skillSearch = null;
    }
  }

  Future<void> _loadCatalog() async {
    if (_catalogSearch != null || _catalogTime != null &&
        DateTime.now().difference(_catalogTime!) < const Duration(seconds: 30)) { return; }
    final token = _catalogSearch = CancellationToken();
    try {
      final result = await widget.client.mcpInventory(verbose: true, cancellation: token);
      if (!mounted || token.isCancelled) return;
      setState(() { _catalog = result; _catalogTime = DateTime.now(); });
    } on CancelledException {
      // The active completion, project, or app owns the catalog request.
    } catch (_) {
      // File and skill completion remain usable when an MCP server is offline.
    } finally {
      if (identical(_catalogSearch, token)) _catalogSearch = null;
    }
  }

  void _chooseContext(_ContextOption item) {
    final mention = _mention;
    final controller = widget.controller;
    if (mention == null || controller is! ComposerTextController || _mentionAt(controller.value) != mention) return;
    if (item.kind == 'session') { unawaited(_insertSession(item, mention)); return; }
    final range = TextRange(start: mention.start, end: mention.end);
    dismiss();
    controller.insertFile(range, item.path,
      title: item.kind == 'resource' || item.kind == 'tool' ? item.label : null,
      prompt: item.kind == 'tool' ? '`${item.path}`' : null);
    widget.focusNode.requestFocus();
  }

  Future<void> _insertSession(_ContextOption item, _Mention mention) async {
    final controller = widget.controller as ComposerTextController, before = widget.controller.value;
    dismiss();
    final token = _contextAction = CancellationToken();
    _contextDraft = before;
    try {
      final page = await widget.client.sessionRead('session.message.list', {'sessionID': item.path, 'limit': 20}, cancellation: token);
      final transcript = StringBuffer('Context from session "${item.label}" (${item.path}):\n');
      for (final raw in page['data'] as List? ?? []) {
        final message = jsonObject(raw);
        if (message['type'] != 'user' && message['type'] != 'assistant') continue;
        final text = StringBuffer();
        final parts = message['type'] == 'user' ? [message['text']] : [
          for (final part in message['content'] as List? ?? [])
            if (part['type'] == 'text') part['text'],
        ];
        for (var content in parts) {
          if (content is Map && content[r'$part'] is String) {
            content = await widget.client.conversationPart(content[r'$part'] as String, cancellation: token);
          }
          if (content is String) text.writeln(content);
        }
        if (text.isNotEmpty) transcript..writeln('\n${message['type'] == 'user' ? 'User' : 'Assistant'}:')..write(text);
      }
      if (!mounted || token.isCancelled || !identical(widget.controller, controller) || controller.value != before) return;
      controller.insertFile(TextRange(start: mention.start, end: mention.end), 'session:${item.path}',
        title: item.label, prompt: '\n$transcript\n');
      widget.focusNode.requestFocus();
    } on CancelledException {
      // Editing the draft, navigating, and disposal cancel context insertion.
    } catch (error) {
      if (mounted && !token.isCancelled) widget.session?.showError(error);
    } finally {
      if (identical(_contextAction, token)) { _contextAction = null; _contextDraft = null; }
    }
  }

  void _apply(Json result) {
    setState(() {
      _paths = (result['paths'] as List).cast<String>();
      _loading = false;
      _failed = false;
      _truncated = result['truncated'] == true;
      _selected = _selected.clamp(0, (_choiceCount - 1).clamp(0, _choiceCount));
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void dismiss() {
    _cancel();
    _catalogSearch?.cancel();
    _catalogSearch = null;
    _closeMcp();
    setState(() {
      _historyOpen = false;
      _dismissed = _mention;
      _dismissedCommand = widget.controller.value;
      _mention = null;
      _command = null;
      _paths = [];
      _skills = [];
      _loading = _skillsLoading = _failed = _skillsFailed = false;
      _truncated = _skillsTruncated = false;
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
    final count = _choiceCount;
    if (count == 0) return;
    setState(() => _selected = (_selected + offset) % count);
    if (_scroll.hasClients) {
      final top = _selected * 28.0;
      final bottom = top + 28;
      if (top < _scroll.offset) { _scroll.jumpTo(top); }
      else if (bottom > _scroll.offset + _scroll.position.viewportDimension) {
        _scroll.jumpTo((bottom - _scroll.position.viewportDimension).clamp(0, _scroll.position.maxScrollExtent));
      }
    }
  }

  bool moveSelection(int direction) {
    if (!_visible) return false;
    if (_choiceCount > 0) _move(direction);
    return true;
  }

  bool completeSelection() {
    if (!_visible) return false;
    if (_choiceCount > 0) _chooseSelected();
    return true;
  }

  void _chooseSkill(Json skill) {
    final mention = _mention;
    final command = _command;
    final controller = widget.controller;
    if (controller is! ComposerTextController || mention == null && command == null) return;
    if (mention != null && _mentionAt(controller.value) != mention ||
        command != null && _commandAt(controller.value) != command) {
      return;
    }
    final range = TextRange(start: command?.start ?? mention!.start, end: command?.end ?? mention!.end);
    dismiss();
    controller.insertFile(range, skill['path'] as String, skillName: skill['name'] as String);
    widget.focusNode.requestFocus();
  }

  void _chooseSelected() {
    if (_historyOpen) {
      final text = _historyItems[_selected];
      dismiss();
      widget.controller.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
      widget.focusNode.requestFocus();
    }
    else if (_command != null) { _chooseCommand(); }
    else if (_selected < _paths.length) { _choose(_paths[_selected]); }
    else if (_selected < _paths.length + _skills.length) { _chooseSkill(_skills[_selected - _paths.length]); }
    else { _chooseContext(_contextOptions[_selected - _paths.length - _skills.length]); }
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
    _catalogSearch?.cancel();
    _closeMcp();
    widget.controller.removeListener(_changed);
    widget.focusNode.removeListener(_changed);
    _scroll.dispose();
    _historyQuery.dispose();
    _historyFocus.dispose();
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
            if (_mcpAnchor != null) {
              return;
            } else if (_choiceCount > 0) {
              _chooseSelected();
            } else if (!_loading && !_skillsLoading && _command == null) {
              dismiss();
            }
          },
          if (_mcpAnchor != null) ...{
            const SingleActivator(LogicalKeyboardKey.tab): () {},
            if (_mcpFilter.isEmpty) const SingleActivator(LogicalKeyboardKey.backspace): dismiss,
          },
          if (_choiceCount > 0) ...{
            const SingleActivator(LogicalKeyboardKey.tab): _chooseSelected,
            const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
            const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
            const SingleActivator(LogicalKeyboardKey.keyN, control: true): () => _move(1),
            const SingleActivator(LogicalKeyboardKey.keyP, control: true): () => _move(-1),
          },
          const SingleActivator(LogicalKeyboardKey.keyG, control: true): dismiss,
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
              child: CodeEditorTapRegion(child: TextFieldTapRegion(child: _menu(context))),
            ),
          ) : const SizedBox.shrink(),
          child: CompositedTransformTarget(link: _link,
            child: ComposerAutocompleteScope(visible: visible, owner: this, child: widget.child)),
        ),
      ),
    );
  }

  Widget _menu(BuildContext context) {
    final count = _choiceCount;
    final query = _command?.text.substring(1) ?? _mention?.query ?? '';
    final commands = _suggestions;
    final contexts = _contextOptions;
    final history = _historyOpen ? _historyItems : const <String>[];
    final maxHeight = (MediaQuery.sizeOf(context).height * .5).clamp(100.0, 320.0);
    return Material(
      color: Colors.white,
      elevation: 8, shadowColor: const Color(0x24000000),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Color(0xffe1e3e6), width: .5)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(constraints: BoxConstraints(maxHeight: maxHeight),
        child: _mcpAnchor != null ? SingleChildScrollView(controller: _scroll,
          padding: const EdgeInsets.all(6),
          child: McpStatusMenu(inventory: _inventory, verbose: _verbose, loading: _mcpLoading, failed: _mcpFailed,
            query: _mcpFilter, onRetry: () => unawaited(_loadMcp()),
            onSignIn: (server) => unawaited(showMcpAuthentication(context, widget.client, server)),
            onSignOut: (server) => unawaited(showMcpAuthentication(context, widget.client, server, signOut: true))),
        ) : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 6), child: Row(children: [
            Text(_historyOpen ? 'Prompt history' : _command != null ? 'Commands' : _skillsOnly ? 'Skills' : 'Add context',
              style: const TextStyle(fontSize: 11, color: Color(0xff858a94))),
            const Spacer(),
            if (_loading || _skillsLoading) const SizedBox.square(dimension: 10,
              child: CircularProgressIndicator(strokeWidth: 1.2, color: Color(0xff858a94))),
          ])),
          if (_historyOpen) Padding(padding: const EdgeInsets.symmetric(horizontal: 6),
            child: CallbackShortcuts(bindings: {
              const SingleActivator(LogicalKeyboardKey.arrowDown): () => moveSelection(1),
              const SingleActivator(LogicalKeyboardKey.arrowUp): () => moveSelection(-1),
              const SingleActivator(LogicalKeyboardKey.enter): () => completeSelection(),
              const SingleActivator(LogicalKeyboardKey.escape): () { dismiss(); widget.focusNode.requestFocus(); },
            }, child: TextField(controller: _historyQuery, focusNode: _historyFocus,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(isDense: true, hintText: 'Search prompts…',
                border: InputBorder.none, contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 8)),
              onChanged: (_) { setState(() => _selected = 0); if (_scroll.hasClients) _scroll.jumpTo(0); },
            ))),
          if (count > 0) Flexible(child: SizedBox(height: count * 28.0,
            child: Scrollbar(controller: _scroll, child: ListView.builder(controller: _scroll,
              padding: const EdgeInsets.symmetric(horizontal: 6), itemExtent: 28,
              itemCount: count, itemBuilder: (context, index) {
                final commandCount = !_historyOpen && _command != null ? commands.length : 0;
                final pathCount = !_historyOpen && _command == null ? _paths.length : 0;
                final command = index < commandCount ? commands[index] : null;
                final path = index >= commandCount && index < commandCount + pathCount ? _paths[index - commandCount] : null;
                final skillIndex = index - commandCount - pathCount;
                final skill = !_historyOpen && skillIndex >= 0 && skillIndex < _skills.length ? _skills[skillIndex] : null;
                final extra = !_historyOpen && skillIndex >= _skills.length ? contexts[skillIndex - _skills.length] : null;
                final name = _historyOpen ? history[index].substring(0, history[index].length.clamp(0, 240)).replaceAll(RegExp(r'\s+'), ' ') :
                  command?.name ?? (path != null ? _basename(path) : skill != null
                  ? '${_command != null ? '/' : r'$'}${skill['name']}' : extra!.label);
                final detail = _historyOpen ? '' : command?.description ?? (path != null ? _dirname(path) : skill != null
                  ? skill['description'] as String? ?? '' : extra!.description);
                final scope = skill == null ? null : skill['scope'] == 'repo' ? 'Project' : 'Global';
                return Semantics(selected: index == _selected, button: true,
                  child: MouseRegion(onEnter: (_) { if (_selected != index) setState(() => _selected = index); },
                    child: InkWell(canRequestFocus: false, borderRadius: BorderRadius.circular(4),
                      onTap: () { _selected = index; _chooseSelected(); },
                      child: Container(padding: const EdgeInsets.symmetric(horizontal: 6),
                        decoration: BoxDecoration(color: index == _selected ? const Color(0xfff1f2f4) : null,
                          borderRadius: BorderRadius.circular(4)),
                        child: Row(children: [
                          if (_historyOpen) const Icon(Icons.history_rounded, size: 16, color: Color(0xff858a94))
                          else if (path != null) FileIcon(path)
                          else if (skill != null) const SkillIcon(color: Color(0xff858a94))
                          else if (extra != null) extra.kind == 'project' ? FileIcon(extra.path)
                            : Icon(extra.kind == 'session' ? Icons.chat_bubble_outline_rounded :
                              extra.kind == 'tool' ? Icons.build_outlined : Icons.link_rounded, size: 16, color: const Color(0xff858a94))
                          else Icon(command!.name.startsWith('/model ') ? Icons.tune_rounded :
                            command.name.startsWith('/reasoning ') ? Icons.psychology_outlined :
                            command.name.startsWith('/mcp') ? Icons.extension_outlined : Icons.terminal_rounded,
                            size: 16, color: const Color(0xff858a94)),
                          const SizedBox(width: 8),
                          Flexible(child: Text.rich(_matched(name, query), maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13, height: 20 / 13, color: Color(0xff1a1c1f)))),
                          if (detail.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            Expanded(child: Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12, color: Color(0xff858a94)))),
                          ] else const Spacer(),
                          if (scope != null) Padding(padding: const EdgeInsets.only(left: 8),
                            child: Text(scope, style: const TextStyle(fontSize: 10, color: Color(0xff858a94)))),
                        ]),
                      ),
                    ),
                  ),
                );
              },
            )),
          )),
          if (count == 0) Padding(padding: const EdgeInsets.all(12),
            child: Text(_failed || _skillsFailed ? 'Search unavailable' : _loading || _skillsLoading ? 'Searching…' : 'No matching items',
              style: const TextStyle(fontSize: 13, color: Color(0xff858a94)))),
          if (_failed || _skillsFailed) TextButton(onPressed: () {
            if (_mention != null && !_skillsOnly) unawaited(_lookup(_mention!));
            unawaited(_lookupSkills(_command?.text.substring(1) ?? _mention!.query));
          }, child: const Text('Retry search')),
          Padding(padding: const EdgeInsets.fromLTRB(12, 6, 12, 8), child: Row(children: [
            Text(_truncated || _skillsTruncated ? 'Type to narrow results' : '↑↓ Navigate',
              style: const TextStyle(fontSize: 10, color: Color(0xff858a94))),
            const Spacer(),
            const Text('↵ Select    tab Complete    esc Close', style: TextStyle(fontSize: 10, color: Color(0xff858a94))),
          ])),
        ]),
      ),
    );
  }
}

String _basename(String path) => path.replaceAll(r'\', '/').split('/').where((part) => part.isNotEmpty).lastOrNull ?? path;
String _dirname(String path) {
  final normalized = path.replaceAll(r'\', '/').replaceFirst(RegExp(r'/$'), '');
  final slash = normalized.lastIndexOf('/');
  return slash < 0 ? '' : normalized.substring(0, slash + 1);
}

TextSpan _matched(String text, String query) {
  final needle = query.replaceAll(RegExp(r'^[/@$]'), '').toLowerCase();
  final spans = <InlineSpan>[];
  var cursor = 0;
  for (final character in text.characters) {
    final matched = cursor < needle.length && character.toLowerCase() == needle[cursor];
    if (matched) cursor++;
    spans.add(TextSpan(text: character, style: matched ? const TextStyle(fontWeight: FontWeight.w600) : null));
  }
  return TextSpan(children: spans);
}

bool _fuzzyMatch(String text, String query) {
  var offset = 0;
  final haystack = text.toLowerCase();
  for (final rune in query.toLowerCase().runes) {
    final character = String.fromCharCode(rune);
    final found = haystack.indexOf(character, offset);
    if (found < 0) return false;
    offset = found + character.length;
  }
  return true;
}

// Token discovery only visits the caret's immediate surroundings. Code-fence
// state is checked once when a new completion begins, outside this hot path.
_Mention? _mentionAt(TextEditingValue value) {
  if (!value.selection.isValid || !value.selection.isCollapsed || !value.composing.isCollapsed) return null;
  final caret = value.selection.extentOffset, text = value.text;
  if (caret == 0 || caret > text.length) return null;
  final from = (caret - 258).clamp(0, text.length);
  final window = text.substring(from, caret);
  final line = window.substring(window.lastIndexOf('\n') + 1);
  if ('`'.allMatches(line).length.isOdd) return null;
  final match = RegExp(r'(?:^|[\s(\[{])([@$])(?:(?:"((?:\\.|[^"\r\n])*)$)|([^\s@$"\)\]}\uFFFC]*$))').firstMatch(line);
  if (match == null) return null;
  final query = (match[2] ?? match[3] ?? '').replaceAllMapped(RegExp(r'\\(.)'), (match) => match[1]!);
  if (query.length > 256 || match[1] == r'$' && RegExp(r'^[.,]?\d[\d.,]*$').hasMatch(query)) return null;
  final start = caret - (match[2] ?? match[3] ?? '').length - (match[2] == null ? 1 : 2);
  var end = caret;
  while (end < text.length && end - caret < 256 &&
      !(match[2] != null ? RegExp(r'["\r\n]') : RegExp(r'[\s@$"\)\]}\uFFFC]')).hasMatch(text[end])) { end++; }
  if (match[2] != null && end < text.length && text[end] == '"') { end++; }
  return (start: start, end: end, query: query);
}

_Command? _commandAt(TextEditingValue value) {
  if (!value.selection.isValid || !value.selection.isCollapsed || !value.composing.isCollapsed) return null;
  final end = value.selection.extentOffset;
  final from = (end - 258).clamp(0, value.text.length);
  final window = value.text.substring(from, end);
  final line = window.substring(window.lastIndexOf('\n') + 1);
  if ('`'.allMatches(line).length.isOdd) return null;
  final match = RegExp(r'(?:^|[\s(\[{])(/[\p{L}\p{N}\p{M}._:-]*(?:[ \t]+[^\n/@$>\uFFFC]*)?)$', unicode: true).firstMatch(line);
  if (match == null) return null;
  final text = match[1]!;
  final query = _normalizedCommand(text);
  if (query.length > 257 || query.contains(' ') &&
      !['/mcp ', '/model ', '/reasoning '].any(query.startsWith)) { return null; }
  return (start: end - text.length, end: end, text: text);
}

String _normalizedCommand(String text) => text.trimRight().toLowerCase().replaceAll(RegExp(r'[ \t]+'), ' ');
