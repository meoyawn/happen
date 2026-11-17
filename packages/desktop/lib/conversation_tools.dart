import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'appearance.dart';
import 'conversation_activity.dart';
import 'conversation_activity_icon.dart';
import 'conversation_command.dart';
import 'conversation_data.dart';
import 'conversation_markdown.dart' show ConversationImage, ConversationImageGroup;
import 'conversation_images.dart';
import 'diff_patch.dart';
import 'file_reference.dart';
import 'session.dart';

const _browserActions = {
  'browser_list_tabs': ('Listing Browser tabs', 'Listed Browser tabs'),
  'browser_open_tab': ('Opening a Browser tab', 'Opened a Browser tab'),
  'browser_close_tab': ('Closing a Browser tab', 'Closed a Browser tab'),
  'browser_navigate': ('Navigating in Browser', 'Navigated in Browser'),
  'browser_history': ('Changing Browser history', 'Changed Browser history'),
  'browser_evaluate': ('Evaluating Browser script', 'Evaluated Browser script'),
  'browser_dom': ('Inspecting the Browser page', 'Inspected the Browser page'),
  'browser_action': ('Interacting with the Browser page', 'Interacted with the Browser page'),
  'browser_wait_for': ('Waiting for the Browser page', 'Waited for the Browser page'),
  'browser_screenshot': ('Capturing the Browser page', 'Captured the Browser page'),
  'browser_network_requests': ('Listing Browser requests', 'Listed Browser requests'),
  'browser_network_request': ('Reading a Browser request', 'Read a Browser request'),
  'browser_events': ('Reading Browser events', 'Read Browser events'),
  'browser_visibility': ('Checking Browser visibility', 'Checked Browser visibility'),
};

const _desktopBrowserActions = {
  'browser_tabs': 'browser_list_tabs',
  'browser_open': 'browser_open_tab',
  'browser_close': 'browser_close_tab',
  'browser_snapshot': 'browser_dom',
  'browser_click': 'browser_action',
  'browser_fill': 'browser_action',
};

(String, String)? _browserAction(ToolActivity tool) {
  final source = tool.item['server'] ?? tool.item['namespace'];
  final name = tool.item['tool'];
  if (name is String && name.startsWith('client__')) {
    final action = name.substring('client__'.length);
    if (action == 'browser_dev_servers') return ('Listing Browser servers', 'Listed Browser servers');
    return _browserActions[_desktopBrowserActions[action] ?? action];
  }
  if (source == 'codex_app' || source == null && tool.item['type'] == 'dynamicToolCall') {
    return _browserActions[name];
  }
  return null;
}

final _whitespace = RegExp(r'\s+');
final _pathSeparator = RegExp(r'[/\\]');
String _labelText(Object? value) => value is String ? value.trim().replaceAll(_whitespace, ' ') : '';
Map<Object?, Object?> _fields(Object? value) => value is Map ? value : const {};
Iterable<Map<Object?, Object?>> _entries(Object? value) => value is List ? value.whereType<Map<Object?, Object?>>() : const [];

String? _loadedSkill(ConversationCommandAction action) {
  final path = action.path ?? action.name ?? '';
  return action.type == 'read' && conversationPathName(path) == 'SKILL.md' ? path : null;
}

bool isConversationQuestionTool(ToolActivity tool) =>
  const {'question', 'request_user_input', 'request_user_input_async'}.contains(tool.name.split('.').last.split('__').last);

bool _codeModeWrapper(ToolActivity tool) {
  final item = tool.item;
  return item['type'] == 'dynamicToolCall' &&
    (item['namespace'] == null || item['namespace'] == 'functions') &&
    const {'exec', 'wait', 'functions.exec', 'functions.wait'}.contains(tool.name);
}

/// Code-mode envelopes carry the underlying steps. Keep errors and media
/// available when an envelope itself is the source of the result.
Iterable<ToolActivity> visibleConversationTools(Iterable<ToolActivity> tools) sync* {
  for (final tool in tools) {
    if (_codeModeWrapper(tool) && tool.status != 'failed' && tool.images.isEmpty) {
      yield* visibleConversationTools(tool.children);
    } else {
      yield tool;
    }
  }
}

bool isPersistentConversationTool(ToolActivity tool) {
  final item = tool.item;
  return item['approvalRequestId'] != null || item['requestId'] != null || item['requiresInput'] == true ||
    _fields(item['appContext'])['resourceUri'] != null || item['mcpAppResourceUri'] != null ||
    _fields(item['mcpAppUi'])['resourceUri'] != null ||
    item['type'] == 'dynamicToolCall' && item['tool'] == 'finalize_environment' &&
      (item['namespace'] == null || item['namespace'] == 'codex_app');
}

bool canGroupConversationTool(ToolActivity tool) =>
  const {'commandExecution', 'fileChange', 'mcpToolCall', 'dynamicToolCall', 'webSearch'}.contains(tool.item['type']) &&
  !_codeModeWrapper(tool) && !isConversationQuestionTool(tool) && !isPersistentConversationTool(tool);

(String, String)? _repeatableTool(ToolActivity tool) {
  final item = tool.item;
  if (item['type'] != 'mcpToolCall' || item['status'] != 'completed' || tool.status != 'done' ||
      !canGroupConversationTool(tool) || item['appContext'] != null || item['mcpAppUi'] != null ||
      item['automaticApprovalReviews'] is List && (item['automaticApprovalReviews'] as List).isNotEmpty) return null;
  final server = item['server'], name = item['tool'], result = item['result'];
  if (server is! String || name is! String || result is! Map || result['isError'] == true ||
      const {'codex_app', 'computer-use', 'node_repl'}.contains(server)) return null;
  final meta = result['_meta'];
  return meta == null || meta is Map && meta.isEmpty ? (server, name) : null;
}

typedef _PatchStats = ({int added, int removed, int? line});
typedef _ToolFile = ({String prefix, String name, String? path, _PatchStats? stats});

class _ToolLabel {
  const _ToolLabel(this.text, this.icon, {this.file});
  final String text;
  final ConversationActivityGlyph icon;
  final _ToolFile? file;
}

double _toolFontSize(BuildContext context) {
  final size = DefaultTextStyle.of(context).style.fontSize ?? 14;
  return size > 12 ? size - 1 : size;
}

_ToolLabel _fileLabel(String prefix, String name, String? path, ConversationActivityGlyph icon, {_PatchStats? stats}) =>
  _ToolLabel('$prefix $name', icon, file: (path: path, prefix: prefix, name: name, stats: stats));

final _patchStatsCache = Expando<_PatchStats>();

_PatchStats _patchStats(Map<Object?, Object?> change) =>
  _patchStatsCache[change] ??= _readPatchStats(change);

_PatchStats _readPatchStats(Map<Object?, Object?> change) {
  const empty = (added: 0, removed: 0, line: null);
  final diff = change['diff'];
  if (diff is! String || diff.isEmpty) return empty;
  final kind = _fields(change['kind'])['type'];
  if (kind == 'add' || kind == 'delete') {
    final count = '\n'.allMatches(diff).length + (diff.endsWith('\n') ? 0 : 1);
    return kind == 'add' ? (added: count, removed: 0, line: 1) : (added: 0, removed: count, line: null);
  }
  try {
    var added = 0, removed = 0;
    int? line;
    for (final hunk in DiffPatch.parse(diff).hunks) {
      for (final row in hunk.lines) {
        if (row.kind == DiffLineKind.addition) { added++; line ??= row.newLine; }
        if (row.kind == DiffLineKind.deletion) { removed++; line ??= hunk.newStart > 0 ? hunk.newStart : null; }
      }
    }
    return (added: added, removed: removed, line: line);
  } on FormatException {
    return empty;
  }
}

String _patchVerb(Object? kind, bool running, bool failed) => failed ? 'File change failed ·' : switch (kind) {
  'add' => running ? 'Creating' : 'Created',
  'delete' => running ? 'Deleting' : 'Deleted',
  _ => running ? 'Editing' : 'Edited',
};

_ToolLabel _patchLabel(Map<Object?, Object?> change, bool running, bool failed) {
  final kind = _fields(change['kind']);
  final path = kind['move_path'] ?? kind['movePath'] ?? change['path'];
  final name = path is String ? _labelText(conversationPathName(path)) : '';
  return _fileLabel(_patchVerb(kind['type'], running, failed), name.isEmpty ? 'file' : name,
    kind['type'] == 'delete' || path is! String ? null : path, ConversationActivityGlyph.pencil, stats: _patchStats(change));
}

_ToolLabel _toolLabel(ToolActivity tool, {required bool running}) {
  final item = tool.item;
  final failed = tool.status == 'failed';
  switch (item['type']) {
    case 'commandExecution':
      final command = _labelText(conversationCommandText(item));
      final commandLabel = command.isEmpty ? 'Command' : command;
      const terminal = ConversationActivityGlyph.terminal;
      if (item['status'] == 'declined') return _ToolLabel('Command declined ($commandLabel)', terminal);
      if (item['status'] == 'interrupted') return _ToolLabel('Command stopped ($commandLabel)', ConversationActivityGlyph.stop);
      if (failed) return _ToolLabel('Command failed ($commandLabel)', terminal);
      final actions = conversationCommandActions(item);
      if (actions.length == 1) {
        final action = actions.single;
        final path = action.path ?? '';
        final target = _labelText(conversationPathName(path));
        final name = _labelText(action.name ?? target);
        if (_loadedSkill(action) case final skillPath?) {
          final segments = skillPath.split(_pathSeparator);
          final skill = segments.length > 1 ? segments[segments.length - 2] : 'a skill';
          return _ToolLabel('${running ? 'Loading' : 'Loaded'} $skill', ConversationActivityGlyph.book);
        }
        switch (action.type) {
          case 'read':
            final verb = running ? 'Reading' : 'Read';
            return _fileLabel(verb, name.isEmpty ? 'file' : name, action.path, ConversationActivityGlyph.book);
          case 'listFiles':
            return _ToolLabel('${running ? 'Listing' : 'Listed'} files${target.isEmpty ? '' : ' in $target'}',
              ConversationActivityGlyph.folder);
          case 'search':
            final query = _labelText(action.query);
            final subject = query.isEmpty ? 'files' : 'for $query';
            final prefix = '${running ? 'Searching' : 'Searched'} $subject';
            return target.isEmpty ? _ToolLabel(prefix, ConversationActivityGlyph.search)
              : _fileLabel('$prefix in', target, path, ConversationActivityGlyph.search);
        }
      }
      return _ToolLabel(running ? 'Running ${command.isEmpty ? 'command' : command}' : commandLabel, terminal);
    case 'fileChange':
      final changes = _entries(item['changes']).toList();
      if (changes.length == 1) return _patchLabel(changes.single, running, failed);
      final subject = changes.isEmpty ? 'files' : '${changes.length} files';
      return _ToolLabel('${_patchVerb(null, running, failed)} $subject', ConversationActivityGlyph.pencil);
    case 'webSearch':
      final detail = _labelText(_webSearchDetail(item));
      final verb = running ? 'Searching the web' : 'Searched the web';
      return _ToolLabel(detail.isEmpty ? verb : '$verb · $detail', ConversationActivityGlyph.search);
    default:
      if (_codeModeWrapper(tool)) {
        return _ToolLabel(failed ? 'JavaScript failed' : 'JavaScript', ConversationActivityGlyph.terminal);
      }
      final progress = running ? _labelText(item['_progressMessage']) : '';
      if (_browserAction(tool) case final browser?) {
        return _ToolLabel(progress.isNotEmpty ? progress : running ? browser.$1 : failed ? 'Browser call failed · ${browser.$1}' : browser.$2,
          ConversationActivityGlyph.window);
      }
      final action = _labelText(item['tool'] ?? tool.name).replaceAll('_', ' ');
      final source = _labelText(item['server'] ?? item['namespace']).replaceAll('_', ' ');
      final name = action.isEmpty ? 'Tool' : source.isEmpty ? action : '$source · $action';
      return _ToolLabel(progress.isNotEmpty ? progress : failed ? 'Tool failed · $name' : running ? 'Running $name' : name,
        ConversationActivityGlyph.link);
  }
}

_ToolLabel _toolRunSummary(List<ToolActivity> tools) {
  final skills = <String>{}, files = <String>{};
  var commands = 0, calls = 0;
  var browser = false, web = false, explored = false;
  for (final tool in tools) {
    switch (tool.item['type']) {
      case 'commandExecution':
        for (final action in conversationCommandActions(tool.item)) {
          if (_loadedSkill(action) case final skill?) { skills.add(skill); }
          else if (const {'read', 'search', 'listFiles'}.contains(action.type)) { explored = true; }
          else { commands++; }
        }
      case 'fileChange':
        files.addAll(_entries(tool.item['changes']).map((change) => _labelText(change['path'])).where((path) => path.isNotEmpty));
      case 'webSearch':
        web = true;
      default:
        if (_browserAction(tool) != null) { browser = true; } else { calls++; }
    }
  }
  final parts = <_ToolLabel>[
    if (browser) const _ToolLabel('Used Browser', ConversationActivityGlyph.window),
    if (skills.isNotEmpty) _ToolLabel(skills.length == 1 ? 'Loaded a tool' : 'Loaded tools', ConversationActivityGlyph.wrench),
    if (calls > 0) _ToolLabel(calls == 1 ? 'Called a tool' : 'Called tools', ConversationActivityGlyph.link),
    if (files.isNotEmpty) _ToolLabel(files.length == 1 ? 'Edited a file' : 'Edited files', ConversationActivityGlyph.pencil),
    if (explored) const _ToolLabel('Read files', ConversationActivityGlyph.book),
    if (commands > 0) _ToolLabel(commands == 1 ? 'Ran a command' : 'Ran commands', ConversationActivityGlyph.terminal),
    if (web) const _ToolLabel('Searched the web', ConversationActivityGlyph.search),
  ];
  if (parts.isEmpty) return const _ToolLabel('Tool activity', ConversationActivityGlyph.wrench);
  return _ToolLabel([parts.first.text, for (final part in parts.skip(1)) part.text[0].toLowerCase() + part.text.substring(1)]
    .join(', '), parts.first.icon);
}

String _webSearchDetail(Map<String, dynamic> item) {
  final action = _fields(item['action']);
  final value = switch (action['type']) {
    'openPage' => _labelText(action['url']),
    'findInPage' => [_labelText(action['pattern']), _labelText(action['url'])].where((value) => value.isNotEmpty).join(' in '),
    _ => _labelText(action['query']),
  };
  if (value.isNotEmpty) return value;
  final queries = action['queries'];
  if (queries is List) {
    final detail = queries.whereType<String>().where((query) => query.trim().isNotEmpty).join('\n');
    if (detail.isNotEmpty) return detail;
  }
  return item['query'] is String ? (item['query'] as String).trim() : '';
}

List<(String, Object?)> _toolDetails(ToolActivity tool) {
  final item = tool.item;
  final error = item['error'];
  return switch (item['type']) {
    'commandExecution' => [
      ('Command', conversationCommandText(item)),
      ('Output', tool.rawOutput),
      if (item['exitCode'] is num) ('Exit status', item['exitCode'].toString()),
    ],
    'fileChange' => [('Output', tool.rawOutput)],
    'webSearch' => [
      ('Search', _webSearchDetail(item)),
      ('Sources', _entries(item['sources'] ?? item['results']).map((source) => _labelText(source['url']))
        .where((url) => url.isNotEmpty).join('\n')),
    ],
    _ => [
      (_codeModeWrapper(tool) ? 'JavaScript' : 'Input', tool.rawInput),
      ('Output', tool.rawOutput),
      ('Error', error is Map ? error['message'] ?? error : error),
    ],
  };
}

ConversationFileLocation? _toolFileLocation(_ToolFile file, String directory) {
  final path = file.path;
  if (path == null || path.trim().isEmpty || path.contains('\u0000')) return null;
  final windows = !p.posix.isAbsolute(path) && (p.windows.isAbsolute(path) ||
    !p.posix.isAbsolute(directory) && p.windows.isAbsolute(directory));
  final style = windows ? p.windows : p.posix;
  if (!style.isAbsolute(path) && !style.isAbsolute(directory)) return null;
  return (path: style.normalize(style.isAbsolute(path) ? path : style.join(directory, path)), line: file.stats?.line);
}

Widget _toolFileLabel(BuildContext context, _ToolFile file, TextStyle style, String directory) {
  final location = _toolFileLocation(file, directory);
  final scope = context.getInheritedWidgetOfExactType<ConversationFileScope>();
  final open = scope == null || location == null ? null : () => scope.onOpen(location);
  final name = Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: open == null ? style
    : style.copyWith(color: DesktopAccent.of(context).reference, decoration: TextDecoration.underline));
  final stats = file.stats;
  return LayoutBuilder(builder: (context, constraints) => Row(mainAxisSize: MainAxisSize.min, children: [
    ConstrainedBox(constraints: BoxConstraints(maxWidth: constraints.maxWidth * .78),
      child: Text(file.prefix, maxLines: 1, overflow: TextOverflow.ellipsis, style: style)),
    const SizedBox(width: 4),
    Flexible(child: open == null ? name : Tooltip(message: location!.path,
      child: Semantics(link: true, child: InkWell(onTap: open, mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(3), child: name)))),
    if (stats != null && (stats.added > 0 || stats.removed > 0)) ...[
      const SizedBox(width: 7),
      Semantics(label: '${stats.added} lines added, ${stats.removed} lines removed', excludeSemantics: true,
        child: Text('+${stats.added} −${stats.removed}', maxLines: 1, style: style.copyWith(
          fontSize: (style.fontSize ?? 13) - 1, fontFeatures: const [FontFeature.tabularFigures()]))),
    ],
  ]));
}

class ConversationToolCall extends StatelessWidget {
  const ConversationToolCall({super.key, required this.tool, required this.onExpand, this.directory = ''});
  final ToolActivity tool;
  final VoidCallback onExpand;
  final String directory;

  @override
  Widget build(BuildContext context) {
    if (isConversationQuestionTool(tool)) return QuestionToolResult(tool: tool, onExpand: onExpand);
    if (tool.name == 'view_image') return ConversationInspectedImages(tools: [tool], directory: directory, onExpand: onExpand);
    final running = tool.status == 'running';
    final label = _toolLabel(tool, running: running);
    final colors = Theme.of(context).colorScheme;
    final fontSize = _toolFontSize(context);
    final icon = ConversationActivityIcon(label.icon, size: 15);
    final item = tool.item;
    final cwd = item['cwd'] is String && (item['cwd'] as String).isNotEmpty ? item['cwd'] as String : directory;
    final file = label.file;
    final inline = file == null ? null : (TextStyle style) => _toolFileLabel(context, file, style, cwd);
    final hasDetails = tool.children.isNotEmpty || tool.images.isNotEmpty || tool.rawOutput != null || switch (item['type']) {
      'commandExecution' => conversationCommandText(item).isNotEmpty || item['exitCode'] != null,
      'fileChange' => _entries(item['changes']).isNotEmpty,
      'webSearch' => _webSearchDetail(item).isNotEmpty || _entries(item['sources'] ?? item['results']).isNotEmpty,
      _ => tool.rawInput != null || item['error'] != null,
    };
    if (!hasDetails) {
      return ConversationActivityHeader(label: label.text, fontSize: fontSize, icon: icon, inlineLabel: inline);
    }
    final titleStyle = TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: colors.onSurfaceVariant);
    final detailStyle = TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.45, color: colors.onSurface);
    return ConversationDisclosure(key: PageStorageKey('tool:${tool.id}'),
      label: label.text, fontSize: fontSize, icon: icon, toolActivity: true, onExpand: onExpand, inlineLabel: inline,
      builder: (context) => Padding(padding: const EdgeInsets.fromLTRB(22, 4, 2, 8),
        child: ConstrainedBox(constraints: const BoxConstraints(maxHeight: 280), child: SingleChildScrollView(
          key: PageStorageKey('tool-details:${tool.id}'), primary: false,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            if (item['type'] == 'fileChange')
              for (final change in _entries(item['changes'])) Padding(padding: const EdgeInsets.only(bottom: 8),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (file == null) _toolFileLabel(context, _patchLabel(change, running, tool.status == 'failed').file!,
                    titleStyle, cwd),
                  if (change['diff'] case final String diff when diff.isNotEmpty) Text(diff, style: detailStyle),
                ])),
            for (final (name, value) in _toolDetails(tool))
              if (value != null) ConversationData(value: value,
                formatText: value is! String || name == 'Input' || item['type'] == 'mcpToolCall' || item['type'] == 'dynamicToolCall',
                builder: (context, text) =>
                text is! String || text.trim().isEmpty ? const SizedBox.shrink()
                : Padding(padding: const EdgeInsets.only(bottom: 8), child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(name, style: titleStyle),
                    const SizedBox(height: 2),
                    Text(text, style: detailStyle),
                  ]))),
            if (tool.images.isNotEmpty) ConversationImageGroup(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, spacing: 12, children: [
                for (final part in tool.images)
                  if (toolImageSource(part) case final String source)
                    ConversationImage(source: source, label: 'Tool image', directory: directory),
              ])),
            for (final child in visibleConversationTools(tool.children))
              ConversationToolCall(key: ValueKey(child.id), tool: child, directory: directory, onExpand: onExpand),
          ]),
        ))));
  }
}

class ConversationToolRun extends StatefulWidget {
  const ConversationToolRun({super.key, required this.tools, required this.directory, required this.onExpand,
    this.thinkingLabel, required this.inProgress});
  final List<ToolActivity> tools;
  final String directory;
  final VoidCallback onExpand;
  final String? thinkingLabel;
  final bool inProgress;

  @override
  State<ConversationToolRun> createState() => _ConversationToolRunState();
}

class _ConversationToolRunState extends State<ConversationToolRun> {
  final _header = GlobalKey();
  bool? _expanded;
  Object get _storageKey => ('tool-run', widget.tools.first.threadId, widget.tools.first.id);

  void _toggle() => toggleConversationDisclosure(context, _header.currentContext, () {
    setState(() => _expanded = !(_expanded ?? false));
    PageStorage.maybeOf(context)?.writeState(context, _expanded, identifier: _storageKey);
    widget.onExpand();
  });

  Widget _step(ToolActivity tool) => ConversationToolCall(key: ValueKey(tool.id),
    tool: tool, directory: widget.directory, onExpand: widget.onExpand);

  List<Widget> _steps(double fontSize) {
    final groups = <List<ToolActivity>>[];
    (String, String)? previous;
    for (final tool in widget.tools) {
      final key = _repeatableTool(tool);
      if (key != null && key == previous) { groups.last.add(tool); }
      else { groups.add([tool]); }
      previous = key;
    }
    return [for (final group in groups)
      if (group.length == 1) _step(group.single)
      else if (_toolLabel(group.first, running: false) case final label)
        ConversationDisclosure(key: PageStorageKey('tool-repeats:${group.first.id}'),
          label: '${label.text} · ${group.length} calls',
          fontSize: fontSize, toolActivity: true, onExpand: widget.onExpand,
          icon: ConversationActivityIcon(label.icon, size: 15),
          builder: (context) => Padding(padding: const EdgeInsets.only(top: 8, left: 22),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 8,
              children: [for (final tool in group) _step(tool)]))),
    ];
  }

  @override
  Widget build(BuildContext context) {
    _expanded ??= PageStorage.maybeOf(context)?.readState(context, identifier: _storageKey) as bool?;
    final expanded = _expanded == true;
    final thinking = widget.thinkingLabel;
    final active = thinking != null;
    final tools = widget.tools;
    if (tools.length == 1 && !active && _expanded == null) {
      final tool = tools.single;
      if ((tool.status != 'running' || !widget.inProgress) &&
          (tool.item['type'] != 'fileChange' || _entries(tool.item['changes']).length == 1)) return _step(tool);
    }
    final running = active ? tools.where((tool) => tool.status == 'running').lastOrNull : null;
    final label = thinking == null ? _toolRunSummary(tools) : running == null
      ? _ToolLabel(thinking, ConversationActivityGlyph.ellipsis) : _toolLabel(running, running: true);
    final fontSize = _toolFontSize(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      ConversationActivityHeader(key: _header, label: label.text, fontSize: fontSize,
        icon: ConversationActivityIcon(label.icon, size: 16),
        shimmer: active, expanded: expanded, onToggle: _toggle),
      ConversationActivityDetails(expanded: expanded, builder: (context) => Padding(
        padding: const EdgeInsets.only(left: 8, top: 8),
        child: DecoratedBox(decoration: const BoxDecoration(border: Border(left: BorderSide(color: desktopBorder))),
          child: Padding(padding: const EdgeInsets.only(left: 15),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, spacing: 8,
              children: _steps(fontSize)))))),
    ]);
  }
}

Object? _decodeQuestionResult(Object? value) {
  if (value is String) {
    try { return _decodeQuestionResult(jsonDecode(value)); } on FormatException { return value; }
  }
  if (value is List && value.length == 1 && value.first is Map) {
    return _decodeQuestionResult(value.first['text']);
  }
  if (value is Map && value['content'] is List) return _decodeQuestionResult(value['content']);
  return value;
}

class QuestionToolResult extends StatelessWidget {
  const QuestionToolResult({super.key, required this.tool, required this.onExpand});
  final ToolActivity tool;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) => ConversationData(value: tool.rawInput, builder: (context, input) {
    final decoded = _decodeQuestionResult(input);
    final rawQuestions = decoded is Map && decoded['questions'] is List ? decoded['questions'] as List : const <Object?>[];
    final questions = [for (final question in rawQuestions.whereType<Map<Object?, Object?>>())
      if (question['question'] is String || question['title'] is String) {
        'id': question['id'],
        'question': question['question'] is String ? question['question'] : question['title'],
      },
    ];
    return ConversationData(value: tool.rawOutput, builder: (context, output) {
      final result = _decodeQuestionResult(output);
      final rawAnswers = result is Map ? result['answers'] : null;
      final answers = <List<String>>[];
      for (var i = 0; i < questions.length; i++) {
        Object? answer;
        if (rawAnswers is List && i < rawAnswers.length) answer = rawAnswers[i];
        if (rawAnswers is Map) {
          final value = rawAnswers[questions[i]['id']];
          answer = value is Map ? value['answers'] : value;
        }
        answers.add(answer is List ? answer.whereType<String>().toList() : answer is String ? [answer] : const []);
      }
      final running = tool.status == 'running';
      final asynchronous = tool.name.split('.').last.split('__').last == 'request_user_input_async';
      final count = questions.length;
      final status = asynchronous && tool.status == 'done' ? 'Asked $count question${count == 1 ? '' : 's'}'
          : running ? 'Waiting for your answer' : tool.status == 'done'
          ? 'Answered $count question${count == 1 ? '' : 's'}'
          : tool.status == 'failed' ? 'Questions failed' : 'Question dismissed';
      return QuestionAnswerRow(key: PageStorageKey('question:${tool.id}'),
        id: tool.id,
        answers: [for (var i = 0; i < count; i++)
          (question: questions[i]['question'] as String, answer: answers[i].join(', '))],
        status: status, active: running, onExpand: onExpand,
        error: tool.status == 'failed'
          ? (result is Map ? result['error'] ?? result['output'] ?? result : result ?? tool.item['error'])?.toString() : null);
    });
  });
}

class QuestionAnswerRow extends StatelessWidget {
  const QuestionAnswerRow({super.key, required this.id, required this.answers, this.status = 'Answered',
    this.active = false, this.onExpand, this.error});
  final List<ChatQuestionAnswer> answers;
  final String id, status;
  final bool active;
  final VoidCallback? onExpand;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final question = answers.map((answer) => answer.question.replaceAll(RegExp(r'\s+'), ' ')).join(' · ');
    final answer = answers.map((answer) => answer.answer.replaceAll(RegExp(r'\s+'), ' ')).where((text) => text.isNotEmpty).join(' · ');
    return ConversationDisclosure(
      key: PageStorageKey('answer:$id'),
      label: question.isEmpty ? status : question, fontSize: 14,
      shimmer: active, onExpand: onExpand,
      icon: ConversationWorkIcon(kind: 'question', failed: error != null),
      labelContent: question.isEmpty ? null : Row(children: [
        Flexible(child: Text(question, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, height: 1.625, color: desktopSecondary))),
        if (answer.isNotEmpty) ...[
          const SizedBox(width: 6),
          Flexible(child: Text(answer, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, height: 1.625, color: desktopForeground))),
        ],
      ]),
      builder: (context) => Padding(padding: const EdgeInsets.fromLTRB(30, 8, 2, 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final answer in answers) Padding(padding: const EdgeInsets.only(bottom: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SelectableText(answer.question,
                style: const TextStyle(fontSize: 14, height: 1.625, color: desktopSecondary)),
              if (answer.answer.isNotEmpty) Padding(padding: const EdgeInsets.only(left: 12, top: 4),
                child: SelectableText(answer.answer,
                  style: const TextStyle(fontSize: 14, height: 1.625, color: desktopSecondary))),
            ])),
          if (error != null) SelectableText(error!,
            style: const TextStyle(fontSize: 14, height: 1.625, color: desktopError)),
        ])),
    );
  }
}

class ConversationWorkIcon extends StatelessWidget {
  const ConversationWorkIcon({super.key, required this.kind, this.failed = false});
  final String kind;
  final bool failed;
  @override
  Widget build(BuildContext context) => CustomPaint(size: const Size.square(16),
    painter: _WorkIconPainter(kind, failed ? desktopError : desktopSecondary));
}

class _WorkIconPainter extends CustomPainter {
  const _WorkIconPainter(this.kind, this.color);
  final String kind;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final stroke = Paint()..color = color..style = PaintingStyle.stroke
      ..strokeWidth = 1.8..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round;
    void line(double x1, double y1, double x2, double y2) =>
      canvas.drawLine(Offset(x1, y1), Offset(x2, y2), stroke);
    switch (kind) {
      case 'image':
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(3, 3, 18, 18), const Radius.circular(2)), stroke);
        canvas.drawCircle(const Offset(8.5, 8.5), 1.5, stroke);
        canvas.drawPath(Path()..moveTo(21, 15)..lineTo(16, 10)..lineTo(5, 21), stroke);
      case 'question':
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(3, 3, 18, 15), const Radius.circular(3)), stroke);
        canvas.drawPath(Path()..moveTo(7, 18)..lineTo(7, 22)..lineTo(12, 18), stroke);
        line(8, 9, 16, 9);
        line(8, 13, 13, 13);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WorkIconPainter oldDelegate) => kind != oldDelegate.kind || color != oldDelegate.color;
}
