import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/rendering.dart';

import 'conversation_markdown.dart';
import 'conversation_data.dart';
import 'session.dart';
import 'composer_attachments.dart';
import 'appearance.dart';
import 'conversation_activity.dart';
import 'conversation_streaming.dart';
import 'opencode_activity.dart';
import 'opencode_execute.dart';
import 'opencode_response.dart';
import 'session_question.dart';

typedef _TranscriptRow = ({String id, ChatEntry? entry, List<ChatEntry> activity, ChatEntry? status});
typedef PendingMessageAction = Future<void> Function(DesktopTask task, String inboxID, String action);

bool _isJavaScriptCell(ToolActivity tool) => {'exec', 'functions.exec'}.contains(tool.name);

List<_TranscriptRow> _transcriptRows(List<ChatEntry> entries) {
  final rows = <_TranscriptRow>[];
  var activity = <ChatEntry>[];
  void flush() {
    if (activity.isEmpty) return;
    rows.add((id: 'activity:${activity.first.id}', entry: null, activity: activity, status: null));
    activity = [];
  }
  var working = false;
  void addWorking() {
    rows.add((id: 'working', entry: null, activity: const [], status: null));
    working = true;
  }
  for (final entry in entries) {
    if (!working && entry.role == 'Queued') {
      flush();
      addWorking();
    }
    if (entry.tool != null || entry.role == 'Reasoning') { activity.add(entry); continue; }
    flush();
    if (entry.role == 'Status' && entry.text == 'Completed') continue;
    rows.add((id: entry.id, entry: entry, activity: const [], status: null));
  }
  flush();
  if (!working) addWorking();
  return rows;
}

/// Task data is cached by the session; only the selected transcript is mounted.
class ConversationDeck extends StatefulWidget {
  const ConversationDeck({super.key, required this.task, required this.tasks,
    required this.directory, required this.empty, required this.onRetry, this.onRetryTurn, this.onLoadEarlier, this.onPendingAction});
  final DesktopTask? task;
  final Set<DesktopTask> tasks;
  final String directory;
  final Widget empty;
  final ValueChanged<DesktopTask> onRetry;
  final ValueChanged<DesktopTask>? onRetryTurn;
  final ValueChanged<DesktopTask>? onLoadEarlier;
  final PendingMessageAction? onPendingAction;

  @override
  State<ConversationDeck> createState() => _ConversationDeckState();
}

class _ConversationDeckState extends State<ConversationDeck> {
  @override
  Widget build(BuildContext context) {
    final selected = widget.task;
    if (selected == null) return widget.empty;
    return ConversationTranscript(
      key: ValueKey(selected.id),
      task: selected, directory: widget.directory,
      onRetry: () => widget.onRetry(selected),
      onRetryTurn: widget.onRetryTurn == null ? null : () => widget.onRetryTurn!(selected),
      onLoadEarlier: widget.onLoadEarlier == null ? null : () => widget.onLoadEarlier!(selected),
      onPendingAction: widget.onPendingAction,
    );
  }
}

class ConversationTranscript extends StatefulWidget {
  const ConversationTranscript({super.key, required this.task, required this.directory, required this.onRetry, this.onRetryTurn, this.onLoadEarlier, this.onPendingAction});
  final DesktopTask task;
  final String directory;
  final VoidCallback onRetry;
  final VoidCallback? onRetryTurn;
  final VoidCallback? onLoadEarlier;
  final PendingMessageAction? onPendingAction;

  @override
  State<ConversationTranscript> createState() => _ConversationTranscriptState();
}

class _ConversationTranscriptState extends State<ConversationTranscript> {
  final _scroll = ScrollController();
  bool _following = true, _scheduled = false, _showLatest = false, _jumping = false, _userScrolling = false;
  bool _pagingScheduled = false, _latestScheduled = false;
  bool _autofillBlocked = false;
  String? _lastSentID;
  int _visibleRows = 0;
  ({double pixels, double extent, int rows, bool fill})? _pagingPosition;

  @override
  void initState() {
    super.initState();
    _lastSentID = widget.task.lastSentID;
    _follow();
  }

  @override
  void didUpdateWidget(ConversationTranscript oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_lastSentID != widget.task.lastSentID) {
      _lastSentID = widget.task.lastSentID;
      _following = true;
      _showLatest = false;
    }
    if (!widget.task.loadingEarlier && _pagingPosition != null) {
      final previous = _pagingPosition!;
      _pagingPosition = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        final position = _scroll.position;
        final added = position.maxScrollExtent - previous.extent;
        // Collapsed activity can absorb a page without adding visible rows.
        // Resume on the next scroll gesture rather than draining all history.
        if (_visibleRows <= previous.rows && added <= 1) _autofillBlocked = true;
        _loadEarlier(position);
      });
    }
    _follow();
  }

  void _follow() {
    if (_scheduled || !_following) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted || !_following || !_scroll.hasClients) return;
      if (_scroll.position.extentBefore > .5) {
        _jumping = true;
        try {
          _scroll.jumpTo(_scroll.position.minScrollExtent);
        } finally {
          _jumping = false;
        }
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification && !_jumping && notification.dragDetails != null) {
      _following = false;
      _autofillBlocked = false;
      _userScrolling = true;
    }
    if (notification is UserScrollNotification) {
      if (notification.direction != ScrollDirection.idle) {
        _userScrolling = true;
        _autofillBlocked = false;
      }
      if (notification.direction == ScrollDirection.reverse) _following = false;
      if (notification.direction == ScrollDirection.forward && notification.metrics.extentBefore < 80) _following = true;
    }
    if (notification is ScrollEndNotification) {
      if (_userScrolling && notification.metrics.extentBefore < 1) _following = true;
      _userScrolling = false;
    }
    final showLatest = notification.metrics.extentBefore > 100;
    if (showLatest != _showLatest && !_latestScheduled) {
      _latestScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _latestScheduled = false;
        if (!mounted || !_scroll.hasClients) return;
        final show = _scroll.position.extentBefore > 100;
        if (show != _showLatest) setState(() => _showLatest = show);
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    }
    _loadEarlier(notification.metrics);
    return false;
  }

  void _loadEarlier(ScrollMetrics metrics) {
    final task = widget.task;
    final fill = metrics.maxScrollExtent <= metrics.minScrollExtent + 1;
    if (_following && !fill || _autofillBlocked || _jumping || _pagingScheduled || metrics.extentAfter > 400 ||
        task.historyBefore == null || task.loadingEarlier || task.loadError != null || widget.onLoadEarlier == null) {
      return;
    }
    _pagingScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pagingScheduled = false;
      if (mounted && (fill || !_following) && _scroll.hasClients) {
        _pagingPosition = (pixels: _scroll.position.pixels, extent: _scroll.position.maxScrollExtent, rows: _visibleRows, fill: fill);
        widget.onLoadEarlier?.call();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _latest() {
    _following = true;
    _follow();
    setState(() => _showLatest = false);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    if (task.loading && !task.loaded) return const Center(child: CircularProgressIndicator());
    if (!task.loaded && task.loadError != null) {
      final error = task.loadError!;
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(padding: const EdgeInsets.all(24), child: SelectableText(error)),
        TextButton(onPressed: widget.onRetry, child: const Text('Retry loading conversation')),
      ]));
    }
    final entries = conversation(task);
    final compacting = entries.any((entry) => entry.compaction?.status == 'running');
    final rows = _transcriptRows(entries);
    final latest = entries.where((entry) => entry.role != 'Queued').lastOrNull;
    final workingIndex = rows.indexWhere((row) => row.id == 'working');
    final activeRow = workingIndex > 0 ? rows[workingIndex - 1] : null;
    final activeGroup = task.running && activeRow != null && activeRow.activity.isNotEmpty &&
      identical(activeRow.activity.last, latest);
    final thinkingGroup = activeGroup && activeRow!.activity.every((entry) => entry.role == 'Reasoning');
    final thinking = task.running && !compacting && !thinkingGroup;
    final count = rows.length;
    _visibleRows = count;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _loadEarlier(_scroll.position);
    });
    final historyOffset = task.historyBefore != null ? 1 : 0;
    final itemCount = count + historyOffset;
    final indices = {for (var i = 0; i < rows.length; i++) rows[i].id: itemCount - 1 - (i + historyOffset)};
    final activeMessages = task.messages.values.where((message) => message['type'] == 'assistant' || message['type'] == 'idle').toList()
      ..sort((a, b) => (a['metadata']['seq'] as int).compareTo(b['metadata']['seq'] as int));
    final lastIdle = activeMessages.lastIndexWhere((message) => message['type'] == 'idle');
    final started = activeMessages.skip(lastIdle + 1).firstOrNull?['time']?['created'] as int?;
    final startedAt = started == null ? null : DateTime.fromMillisecondsSinceEpoch(started);
    return Stack(children: [
      LayoutBuilder(builder: (context, constraints) {
        final sidePadding = 24.0 + (constraints.maxWidth > opencodeSessionWidth
          ? (constraints.maxWidth - opencodeSessionWidth) / 2 : 0);
        return NotificationListener<ScrollMetricsNotification>(
            onNotification: (notification) {
              if (notification.depth == 0) {
                _follow();
                _loadEarlier(notification.metrics);
              }
              return false;
            },
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScroll,
              child: Scrollbar(
                controller: _scroll,
                child: ListView.builder(
                  key: PageStorageKey('transcript:${task.id}'),
                  controller: _scroll,
                  reverse: true,
                  cacheExtent: 0,
                  padding: EdgeInsets.fromLTRB(sidePadding, 16, sidePadding, 20),
                  itemCount: itemCount,
                  findChildIndexCallback: (key) => key is ValueKey<String> ? indices[key.value] : null,
                  itemBuilder: (context, index) {
                    index = itemCount - 1 - index;
                    if (historyOffset == 1 && index == 0) return Column(
                      key: const ValueKey('transcript-history'),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (task.loadError != null) TextButton(
                          onPressed: widget.onLoadEarlier, child: const Text('Could not load earlier messages. Retry'))
                        else if (task.loadingEarlier) const Padding(padding: EdgeInsets.all(16),
                          child: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 1.5)))
                        else const SizedBox(height: 1),
                      ],
                    );
                    index -= historyOffset;
                    final row = rows[index];
                    if (row.id == 'working') return thinking
                      ? _TurnClock(key: const ValueKey('working'), startedAt: startedAt, status: task.retryStatus)
                      : const SizedBox(key: ValueKey('working'), height: 36);
                    final entry = row.entry;
                    return Padding(
                      key: ValueKey(row.id),
                      padding: EdgeInsets.only(top: index == 0 ? 0 : row.activity.isNotEmpty || entry?.tool != null || entry?.role == 'Reasoning' ? 8 : 16),
                      child: entry == null ? _ActivityGroup(
                        key: PageStorageKey(row.id), entries: row.activity, status: row.status,
                        active: activeGroup && index == workingIndex - 1,
                        directory: widget.directory, onExpand: () => _following = false,
                      ) : switch (entry.role) {
                        'Tool' => _ToolRow(tool: entry.tool!, directory: widget.directory, onExpand: () => _following = false),
                        'Compaction' => _CompactionRow(
                          entry: entry, directory: widget.directory, retryStatus: task.retryStatus,
                          onExpand: () => _following = false,
                        ),
                        'Reasoning' => _ReasoningRow(entry: entry, directory: widget.directory, onExpand: () => _following = false),
                        'Status' => _TurnStatus(entry: entry),
                        'Error' => _ErrorMessage(entry: entry,
                          onRetry: !task.running && !task.archived && entry.id == latest?.id ? widget.onRetryTurn : null),
                        _ => _Message(entry: entry, directory: widget.directory,
                          running: task.running,
                          onPendingAction: widget.onPendingAction == null || entry.role != 'Queued' ||
                              task.pending[entry.id.substring('pending:'.length)]?['sending'] == true ? null
                            : (action) => widget.onPendingAction!(task, entry.id.substring('pending:'.length), action),
                          liveText: entry.streaming ? task.liveText : null),
                      },
                    );
                  },
                ),
              ),
            ),
          );
      }),
      if (_showLatest) Positioned(
        bottom: 12, left: 0, right: 0,
        child: Center(child: FilledButton.tonalIcon(
          onPressed: _latest,
          icon: const Icon(Icons.arrow_downward_rounded, size: 16),
          label: const Text('Jump to latest'),
          style: FilledButton.styleFrom(elevation: 1, backgroundColor: const Color(0xfff1f1f3), foregroundColor: conversationInk),
        )),
      ),
    ]);
  }
}

class _ActivityGroup extends StatelessWidget {
  const _ActivityGroup({super.key, required this.entries, required this.directory, required this.onExpand,
    required this.active, this.status});
  final List<ChatEntry> entries;
  final String directory;
  final VoidCallback onExpand;
  final bool active;
  final ChatEntry? status;

  @override
  Widget build(BuildContext context) {
    final tools = [for (final entry in entries) if (entry.tool != null) entry.tool!];
    final running = tools.where((tool) => tool.status == 'running').lastOrNull;
    final thinking = active && tools.isEmpty;
    final names = tools.map(_toolLabel).toSet().join(', ');
    final skills = tools.expand(toolSkillNames).toSet();
    final label = thinking ? 'Thinking' : tools.isEmpty ? 'Thought' : 'Used ${tools.length} $names';
    return ConversationDisclosure(
      key: PageStorageKey('disclosure:${entries.first.id}'),
      label: label, shimmer: thinking,
      summary: thinking && entries.last.role == 'Reasoning' ? _reasoningTitle(entries.last.text)
        : skills.isEmpty ? null : Text(skills.join(', ') + (skills.length == 1 ? ' skill' : ' skills'),
          maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: opencodeMuted)),
      summaryWhenCollapsed: true,
      icon: active || running != null ? const OpenCodeActivityIndicator() : null,
      labelContent: tools.isNotEmpty ? Text.rich(TextSpan(
        style: const TextStyle(fontSize: 13, height: 16 / 13, letterSpacing: -.04,
          color: opencodeInk, fontVariations: [FontVariation('wght', 440)]),
        children: [const TextSpan(text: 'Used ', style: TextStyle(color: opencodeMuted)),
          TextSpan(text: '${tools.length}', style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
          TextSpan(text: ' $names')]), maxLines: 1, overflow: TextOverflow.ellipsis) : null,
      fontSize: 13,
      onExpand: onExpand,
      builder: (context) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (var i = 0; i < entries.length; i++) Padding(
            key: ValueKey(entries[i].id),
            padding: EdgeInsets.only(top: i == 0 ? 0 : entries[i].tool != null || entries[i].role == 'Reasoning' ? 8 : 16),
            child: entries[i].tool != null
              ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final tool in [entries[i].tool!])
                    Padding(padding: const EdgeInsets.only(bottom: 4),
                      child: _ToolRow(key: ValueKey(tool.id), tool: tool, directory: directory, onExpand: onExpand)),
                ])
              : entries[i].role == 'Reasoning'
                ? _ReasoningRow(entry: entries[i], directory: directory, onExpand: onExpand, initiallyExpanded: thinking)
                : _Message(entry: entries[i], directory: directory),
          ),
        ]),
      ),
    );
  }
}

class _ReasoningRow extends StatelessWidget {
  const _ReasoningRow({required this.entry, required this.directory, required this.onExpand, this.initiallyExpanded = false});
  final ChatEntry entry;
  final String directory;
  final VoidCallback onExpand;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) => ConversationDisclosure(
    key: PageStorageKey('reasoning:${entry.id}'), label: entry.streaming ? 'Thinking' : 'Thought', fontSize: 13,
    shimmer: entry.streaming, initiallyExpanded: initiallyExpanded,
    summary: entry.streaming ? _reasoningTitle(entry.text)
      : entry.startedAt != null && entry.timestamp != null ? Text(_duration(entry.startedAt!, entry.timestamp!),
          style: const TextStyle(fontSize: 13, color: opencodeMuted)) : null,
    summaryWhenCollapsed: entry.streaming,
    onExpand: onExpand,
    builder: (context) => Padding(padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: ConversationMarkdown(text: entry.text, directory: directory, fontSize: 13, reasoning: true)),
  );
}

Widget? _reasoningTitle(String text) {
  final title = _reasoningHeading(text);
  return title == null ? null : Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
    style: const TextStyle(fontSize: 13, height: 20 / 13, color: opencodeMuted));
}

// OpenCode session-ui/src/timeline/projection.ts: latest complete Markdown
// heading, with setext headings as the fallback. Ordinary reasoning stays body text.
String? _reasoningHeading(String text) {
  text = text.replaceAll(RegExp(r'\r\n?'), '\n');
  (int, String)? latest, setext;
  for (final (pattern, html) in [
    (RegExp(r'<h[1-6][^>]*>([\s\S]*?)</h[1-6]>', caseSensitive: false), true),
    (RegExp(r'^\s{0,3}#{1,6}[ \t]+(.+?)(?:[ \t]+#+[ \t]*)?$', multiLine: true), false),
    (RegExp(r'^\s*(?:\*\*((?:(?!\*\*).)+)\*\*|__((?:(?!__).)+)__)\s*$', multiLine: true), false),
    (RegExp(r'^([^\n]+)\n(?:=+|-+)\s*$', multiLine: true), false),
  ]) {
    for (final match in pattern.allMatches(text)) {
      var value = match[1] ?? (match.groupCount > 1 ? match[2] : null) ?? '';
      if (html) value = value.replaceAll(RegExp(r'<[^>]+>'), ' ');
      value = value.replaceAllMapped(RegExp(r'`([^`]+)`'), (m) => m[1]!)
        .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]+\)'), (m) => m[1]!)
        .replaceAll(RegExp(r'[*_~]+'), '').trim();
      if (value.isEmpty) continue;
      if (pattern.pattern.startsWith(r'^([^\n]+)')) { setext = (match.start, value); }
      else if (latest == null || match.start >= latest.$1) { latest = (match.start, value); }
    }
  }
  return (latest ?? setext)?.$2;
}

String _toolLabel(ToolActivity tool) => switch (tool.name.split('.').last) {
  'shell_command' || 'exec_command' || 'bash' => 'Shell',
  'read' || 'read_file' => 'Read',
  'write' || 'write_file' || 'apply_patch' || 'edit' => 'Edit',
  'exec' => 'JavaScript',
  'question' || 'request_user_input' || 'request_user_input_async' => 'Questions',
  _ => tool.name,
};

String? _toolPreview(ToolActivity tool) {
  if (tool.preview != null) return tool.preview;
  final name = tool.name.split('.').last;
  if (!{'shell_command', 'exec_command', 'bash', 'read', 'read_file', 'write', 'write_file', 'edit'}.contains(name)) return null;
  try {
    final input = jsonDecode(tool.input);
    if (input is Map) return (input['command'] ?? input['cmd'] ?? input['filePath'] ?? input['path'])?.toString().split('\n').first;
  } on FormatException { /* Raw shell inputs have no JSON envelope. */ }
  return tool.input.split('\n').first;
}

class _Message extends StatefulWidget {
  const _Message({required this.entry, required this.directory, this.liveText, this.onPendingAction, this.running = false});
  final ChatEntry entry;
  final String directory;
  final ValueListenable<String>? liveText;
  final Future<void> Function(String action)? onPendingAction;
  final bool running;

  @override
  State<_Message> createState() => _MessageState();
}

class _MessageState extends State<_Message> {
  bool _hovered = false, _focused = false;
  bool _changing = false;

  Future<void> _change(String action) async {
    if (_changing || widget.onPendingAction == null) return;
    setState(() => _changing = true);
    try {
      await widget.onPendingAction!(action);
    } finally {
      if (mounted) setState(() => _changing = false);
    }
  }

  Widget _action(String action, String label, IconData icon) => SizedBox.square(
    dimension: 20,
    child: IconButton(tooltip: label, padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 20, height: 20),
      visualDensity: VisualDensity.compact,
      onPressed: _changing ? null : () => _change(action),
      icon: Icon(icon, size: 14, color: conversationMuted)),
  );

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final pending = entry.role == 'Queued';
    final user = entry.role == 'You' || pending;
    final body = user ? ConversationMarkdown(text: entry.text, directory: widget.directory, fitContent: true)
      : SmoothConversationText(text: entry.text, directory: widget.directory, streaming: entry.streaming, source: widget.liveText);
    return ConversationImageGroup(child: MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(onFocusChange: (value) => setState(() => _focused = value), child: Column(
      crossAxisAlignment: user ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        if (user && entry.attachments.isNotEmpty) ...[
          LayoutBuilder(builder: (context, constraints) => Align(alignment: Alignment.centerRight,
            child: ConstrainedBox(constraints: BoxConstraints(maxWidth: constraints.maxWidth * .82),
              child: AttachmentRail(attachments: entry.attachments, directory: widget.directory)))),
          if (entry.text.isNotEmpty) const SizedBox(height: 8),
        ],
        if (user && entry.text.isNotEmpty)
          LayoutBuilder(builder: (context, constraints) => Align(
            alignment: Alignment.centerRight,
            child: Container(
              key: ValueKey('message-bubble:${entry.id}'),
              constraints: BoxConstraints(maxWidth: constraints.maxWidth * (.82)),
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: pending ? const Color(0xfffafafa) : opencodeLayer,
                border: pending ? Border.all(color: conversationBorder) : null,
                borderRadius: BorderRadius.circular(10),
              ),
              child: body,
            ),
          ))
        else if (!user && entry.text.isNotEmpty)
          body,
        if (!user && entry.attachments.isNotEmpty)
          ConversationImageParts(parts: entry.attachments, directory: widget.directory),
        if (!user) ...[
          if (entry.response != null) OpenCodeResponseFooter(entry: entry, visible: _hovered || _focused),
        ] else ...[
        SizedBox(height: 8),
        Opacity(opacity: _hovered || _focused || pending ? 1 : 0,
          alwaysIncludeSemantics: true, child: Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: user ? WrapAlignment.end : WrapAlignment.start,
          children: [
            if (pending) const Icon(Icons.schedule_rounded, size: 13, color: conversationMuted),
            if (pending) Text(entry.role, style: const TextStyle(fontSize: 11, color: conversationMuted)),
            if (entry.timestamp case final at?) _Timestamp(at: at),
            if (pending && widget.onPendingAction != null) ...[
              _action('steer', widget.running ? 'Steer' : 'Send', Icons.arrow_upward_rounded),
              _action('delete', 'Delete', Icons.delete_outline_rounded),
            ],
            if (!entry.streaming && entry.text.isNotEmpty) SizedBox(height: 20,
              child: ConversationCopyButton(text: entry.text, label: user ? 'Copy message' : 'Copy response', compact: true)),
          ],
        )),
        ],
      ],
    ))));
  }
}

class _Timestamp extends StatelessWidget {
  const _Timestamp({required this.at});
  final DateTime at;

  @override
  Widget build(BuildContext context) {
    final local = at.toLocal();
    final labels = MaterialLocalizations.of(context);
    final time = labels.formatTimeOfDay(TimeOfDay.fromDateTime(local), alwaysUse24HourFormat: true);
    return Tooltip(
      message: '${local.toIso8601String()} ${local.timeZoneName}',
      child: Text('${labels.formatShortDate(local)} · $time',
        style: TextStyle(fontSize: 12, height: 18 / 12,
          color: opencodeFaint)),
    );
  }
}

String _duration(DateTime start, DateTime end) {
  final seconds = end.difference(start).inSeconds.clamp(0, 1 << 32);
  if (seconds < 1) return '<1s';
  if (seconds < 60) return '${seconds}s';
  if (seconds < 3600) return '${seconds ~/ 60}m ${seconds % 60}s';
  return '${seconds ~/ 3600}h ${seconds % 3600 ~/ 60}m';
}

class _TurnStatus extends StatelessWidget {
  const _TurnStatus({required this.entry, this.icon});
  final ChatEntry entry;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final label = entry.text == 'Stopped' ? 'Interrupted' : entry.text;
    return Row(children: [
      const Expanded(child: Divider(height: 1)), const SizedBox(width: 12),
      if (icon != null) ...[Icon(icon, size: 14, color: conversationMuted), const SizedBox(width: 6)],
      Text(label, style: const TextStyle(fontSize: 13, height: 20 / 13, color: conversationMuted)),
      const SizedBox(width: 12), const Expanded(child: Divider(height: 1)),
    ]);
  }
}

class _CompactionRow extends StatelessWidget {
  const _CompactionRow({required this.entry, required this.directory, required this.onExpand, this.retryStatus});
  final ChatEntry entry;
  final String directory;
  final VoidCallback onExpand;
  final String? retryStatus;

  @override
  Widget build(BuildContext context) {
    final compaction = entry.compaction!;
    if (compaction.status == 'running') {
      return _TurnClock(startedAt: compaction.startedAt,
        status: 'Compacting context${retryStatus == null ? '' : ' · $retryStatus'}');
    }
    final label = switch (compaction.status) {
      'done' => 'Context compacted',
      'failed' => 'Compaction failed',
      'stopped' => 'Compaction stopped',
      _ => 'Compaction interrupted',
    };
    final status = _TurnStatus(
      entry: ChatEntry(entry.id, 'Status', label, timestamp: compaction.endedAt, startedAt: compaction.startedAt),
      icon: Icons.compress_rounded,
    );
    if (compaction.summary.trim().isEmpty) {
      return Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: status);
    }
    return ExpansionTile(
      key: PageStorageKey('compaction:${entry.id}'),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(left: 24, top: 8, bottom: 12),
      dense: true,
      shape: const Border(), collapsedShape: const Border(),
      title: status,
      onExpansionChanged: (_) => onExpand(),
      children: [ConversationMarkdown(text: compaction.summary, directory: directory)],
    );
  }
}

class _TurnClock extends StatefulWidget {
  const _TurnClock({super.key, required this.startedAt, this.status});
  final DateTime? startedAt;
  final String? status;

  @override
  State<_TurnClock> createState() => _TurnClockState();
}

class _TurnClockState extends State<_TurnClock> {
  @override
  Widget build(BuildContext context) {
    return Semantics(liveRegion: true,
      child: SizedBox(height: 36, child: Padding(padding: const EdgeInsets.only(top: 12),
        child: Align(alignment: Alignment.topLeft,
          child: ThinkingLabel(label: widget.status ?? 'Working', fontSize: 13)))));
  }
}

class _ErrorMessage extends StatelessWidget {
  const _ErrorMessage({required this.entry, this.onRetry});
  final ChatEntry entry;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: Theme.of(context).colorScheme.errorContainer.withValues(alpha: .3),
      borderRadius: BorderRadius.circular(12)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Something went wrong', style: TextStyle(fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.error)),
      const SizedBox(height: 8),
      SelectableText(entry.text, style: const TextStyle(fontSize: 13, height: 1.5)),
      const SizedBox(height: 10),
      _TurnStatus(entry: ChatEntry(entry.id, 'Status', 'Failed', timestamp: entry.timestamp, startedAt: entry.startedAt)),
      if (onRetry != null) TextButton.icon(onPressed: onRetry,
        icon: const Icon(Icons.refresh, size: 16), label: const Text('Retry')),
    ]),
  );
}

class _ToolRow extends StatelessWidget {
  const _ToolRow({super.key, required this.tool, required this.directory, required this.onExpand, this.nested = false});
  final ToolActivity tool;
  final String directory;
  final VoidCallback onExpand;
  final bool nested;

  @override
  Widget build(BuildContext context) {
    final running = tool.status == 'running';
    final failed = tool.status == 'failed';
    if (_isJavaScriptCell(tool)) return OpenCodeExecute(tool: tool, directory: directory, onExpand: onExpand);
    if ({'question', 'request_user_input', 'request_user_input_async'}.contains(tool.name.split('.').last)) {
      return QuestionToolResult(tool: tool, onExpand: onExpand);
    }
    if (tool.name.split('.').last == 'skill' && toolSkillReads(tool).isNotEmpty) return SkillReadRows(tool: tool);
    final color = failed ? Theme.of(context).colorScheme.error : conversationMuted;
    final elapsed = tool.startedAt != null && tool.endedAt != null
        ? _duration(tool.startedAt!, tool.endedAt!) : null;
    final preview = _toolPreview(tool);
    return ConversationImageGroup(child: ConversationDisclosure(
      key: PageStorageKey('tool:${tool.id}'),
      label: _toolLabel(tool), fontSize: 13,
      color: failed ? color : conversationInk,
      shimmer: running,
      onExpand: onExpand,
      icon: running ? const OpenCodeActivityIndicator() : null,
      summary: preview != null ? Text('${elapsed == null ? '' : '$elapsed  '}$preview', maxLines: 1, overflow: TextOverflow.ellipsis,
        style: TextStyle(fontFamily: 'monospace', fontSize: 12, height: 20 / 12, color: color))
        : elapsed == null ? null : Text(elapsed, style: TextStyle(fontSize: 12, color: color)),
      builder: (context) => Padding(padding: EdgeInsets.only(left: nested ? 8 : 12, bottom: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (tool.startedAt case final at?) Align(alignment: Alignment.centerLeft,
          child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: _Timestamp(at: at))),
        ConversationData(value: tool.rawOutput, formatText: true,
          builder: (context, output) => _details(output as String?)),
        for (final child in tool.children)
          Padding(padding: const EdgeInsets.only(top: 8), child: _ToolRow(
            key: ValueKey(child.id), tool: child, directory: directory, nested: true, onExpand: onExpand)),
      ])),
    ));
  }

  Widget _details(String? output) => ConversationData(value: tool.rawInput, builder: (context, input) => ConversationCode(
    source: identical(input, tool.rawInput) ? tool.input : conversationDataText(input),
    language: tool.name == 'functions.exec' || tool.name == 'exec' ? 'javascript' : 'json',
    output: output,
  ));
}
