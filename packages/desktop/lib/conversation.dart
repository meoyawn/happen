import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/rendering.dart';
import 'package:protocol/protocol.dart';

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

typedef _TranscriptRow = ({String id, ChatEntry? entry, List<ChatEntry> activity, ChatEntry? status});

bool _isJavaScriptCell(ToolActivity tool) => {'exec', 'functions.exec'}.contains(tool.name);

List<_TranscriptRow> _transcriptRows(List<ChatEntry> entries) {
  final rows = <_TranscriptRow>[];
  var activity = <ChatEntry>[];
  void flush() {
    if (activity.isEmpty) return;
    rows.add((id: 'activity:${activity.first.id}', entry: null, activity: activity, status: null));
    activity = [];
  }
  for (final entry in entries) {
    if (entry.tool != null || entry.role == 'Reasoning') { activity.add(entry); continue; }
    flush();
    if (entry.role == 'Status' && entry.text == 'Completed') continue;
    rows.add((id: entry.id, entry: entry, activity: const [], status: null));
  }
  flush();
  return rows;
}

/// Task data is cached by the session; only the selected transcript is mounted.
class ConversationDeck extends StatefulWidget {
  const ConversationDeck({super.key, required this.task, required this.tasks,
    required this.directory, required this.empty, required this.onRetry, this.onLoadEarlier});
  final DesktopTask? task;
  final Set<DesktopTask> tasks;
  final String directory;
  final Widget empty;
  final ValueChanged<DesktopTask> onRetry;
  final ValueChanged<DesktopTask>? onLoadEarlier;

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
      onLoadEarlier: widget.onLoadEarlier == null ? null : () => widget.onLoadEarlier!(selected),
    );
  }
}

class ConversationTranscript extends StatefulWidget {
  const ConversationTranscript({super.key, required this.task, required this.directory, required this.onRetry, this.onLoadEarlier});
  final DesktopTask task;
  final String directory;
  final VoidCallback onRetry;
  final VoidCallback? onLoadEarlier;

  @override
  State<ConversationTranscript> createState() => _ConversationTranscriptState();
}

class _ConversationTranscriptState extends State<ConversationTranscript> {
  final _scroll = ScrollController();
  bool _following = true, _scheduled = false, _showLatest = false, _jumping = false, _userScrolling = false;
  bool _pagingScheduled = false, _latestScheduled = false;
  bool _autofillBlocked = false;
  int _visibleRows = 0;
  ({double pixels, double extent, int rows, bool fill})? _pagingPosition;

  @override
  void initState() {
    super.initState();
    _follow();
  }

  @override
  void didUpdateWidget(ConversationTranscript oldWidget) {
    super.didUpdateWidget(oldWidget);
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
    final latest = entries.where((entry) => !{'Queued', 'Steer pending'}.contains(entry.role)).lastOrNull;
    final activeGroup = task.running && rows.isNotEmpty && rows.last.activity.isNotEmpty &&
      identical(rows.last.activity.last, latest);
    final thinkingGroup = activeGroup && rows.last.activity.every((entry) => entry.role == 'Reasoning');
    final thinking = task.running && !compacting && !thinkingGroup;
    final count = rows.length + 1;
    _visibleRows = count;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _loadEarlier(_scroll.position);
    });
    final historyOffset = task.historyBefore != null ? 1 : 0;
    final itemCount = count + historyOffset;
    final indices = {for (var i = 0; i < rows.length; i++) rows[i].id: itemCount - 1 - (i + historyOffset),
      'working': 0};
    final activeMessages = task.messages.values.where((message) => message['type'] == 'assistant' || message['type'] == 'idle').toList()
      ..sort((a, b) => (a['metadata']['seq'] as int).compareTo(b['metadata']['seq'] as int));
    final lastIdle = activeMessages.lastIndexWhere((message) => message['type'] == 'idle');
    final started = activeMessages.skip(lastIdle + 1).firstOrNull?['time']?['created'] as int?;
    final startedAt = started == null ? null : DateTime.fromMillisecondsSinceEpoch(started);
    return Stack(children: [
      Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: opencodeSessionWidth),
          child: NotificationListener<ScrollMetricsNotification>(
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
                  padding: EdgeInsets.fromLTRB(24, 16, 24, 20),
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
                    if (index == rows.length) return thinking
                      ? _TurnClock(key: const ValueKey('working'), startedAt: startedAt, status: task.retryStatus)
                      : const SizedBox(key: ValueKey('working'), height: 36);
                    final row = rows[index];
                    final entry = row.entry;
                    return Padding(
                      key: ValueKey(row.id),
                      padding: EdgeInsets.only(top: index == 0 ? 0 : row.activity.isNotEmpty || entry?.tool != null || entry?.role == 'Reasoning' ? 8 : 16),
                      child: entry == null ? _ActivityGroup(
                        key: PageStorageKey(row.id), entries: row.activity, status: row.status,
                        active: activeGroup && index == rows.length - 1,
                        directory: widget.directory, onExpand: () => _following = false,
                      ) : switch (entry.role) {
                        'Tool' => _ToolRow(tool: entry.tool!, directory: widget.directory, onExpand: () => _following = false),
                        'Image' => _ImageViewRow(entry: entry, directory: widget.directory, onExpand: () => _following = false),
                        'Compaction' => _CompactionRow(
                          entry: entry, directory: widget.directory, retryStatus: task.retryStatus,
                          onExpand: () => _following = false,
                        ),
                        'Reasoning' => _ReasoningRow(entry: entry, directory: widget.directory, onExpand: () => _following = false),
                        'Status' => _TurnStatus(entry: entry),
                        'Error' => _ErrorMessage(entry: entry),
                        _ => _Message(entry: entry, directory: widget.directory,
                          liveText: entry.streaming ? task.liveText : null),
                      },
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
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
    final label = thinking ? 'Thinking' : tools.isEmpty ? 'Thought' : 'Used ${tools.length} $names';
    return ConversationDisclosure(
      key: PageStorageKey('disclosure:${entries.first.id}'),
      label: label, shimmer: thinking,
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
                ? thinking ? ConversationMarkdown(text: entries[i].text, directory: directory)
                  : _ReasoningRow(entry: entries[i], directory: directory, onExpand: onExpand)
                : entries[i].role == 'Image'
                  ? _ImageViewRow(entry: entries[i], directory: directory, onExpand: onExpand)
                  : _Message(entry: entries[i], directory: directory),
          ),
        ]),
      ),
    );
  }
}

class _ReasoningRow extends StatelessWidget {
  const _ReasoningRow({required this.entry, required this.directory, required this.onExpand});
  final ChatEntry entry;
  final String directory;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) => ConversationDisclosure(
    key: PageStorageKey('reasoning:${entry.id}'), label: 'Thought', fontSize: 13,
    onExpand: onExpand,
    builder: (context) => Padding(padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: ConversationMarkdown(text: entry.text, directory: directory)),
  );
}

String _toolLabel(ToolActivity tool) => switch (tool.name.split('.').last) {
  'shell_command' || 'exec_command' || 'bash' => 'Shell',
  'read' || 'read_file' => 'Read',
  'write' || 'write_file' || 'apply_patch' || 'edit' => 'Edit',
  'exec' => 'JavaScript',
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
  const _Message({required this.entry, required this.directory, this.liveText});
  final ChatEntry entry;
  final String directory;
  final ValueListenable<String>? liveText;

  @override
  State<_Message> createState() => _MessageState();
}

class _MessageState extends State<_Message> {
  bool _hovered = false, _focused = false;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final user = {'You', 'Queued', 'Steer pending'}.contains(entry.role);
    final pending = entry.role == 'Queued' || entry.role == 'Steer pending';
    final body = user ? ConversationMarkdown(text: entry.text, directory: widget.directory, fitContent: true)
      : SmoothConversationText(text: entry.text, directory: widget.directory, streaming: entry.streaming, source: widget.liveText);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(onFocusChange: (value) => setState(() => _focused = value), child: Column(
      crossAxisAlignment: user ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        if (user)
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
              child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
                if (entry.attachments.isNotEmpty) AttachmentRail(attachments: entry.attachments, directory: widget.directory),
                if (entry.attachments.isNotEmpty && entry.text.isNotEmpty) const SizedBox(height: 10),
                if (entry.text.isNotEmpty) body,
              ]),
            ),
          ))
        else
          body,
        if (!user) ...[
          if (entry.response != null) OpenCodeResponseFooter(entry: entry, visible: _hovered || _focused),
        ] else ...[
        SizedBox(height: 8),
        SizedBox(height: 20, child: Opacity(opacity: _hovered || _focused || pending ? 1 : 0,
          alwaysIncludeSemantics: true, child: Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: user ? WrapAlignment.end : WrapAlignment.start,
          children: [
            if (pending) const Icon(Icons.schedule_rounded, size: 13, color: conversationMuted),
            if (pending) Text(entry.role, style: const TextStyle(fontSize: 11, color: conversationMuted)),
            if (entry.timestamp case final at?) _Timestamp(at: at),
            if (!entry.streaming) SizedBox(height: 20,
              child: ConversationCopyButton(text: entry.text, label: user ? 'Copy message' : 'Copy response', compact: true)),
          ],
        ))),
        ],
      ],
    )));
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
  const _ErrorMessage({required this.entry});
  final ChatEntry entry;

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
    ]),
  );
}

class _ImageViewRow extends StatefulWidget {
  const _ImageViewRow({required this.entry, required this.directory, required this.onExpand});
  final ChatEntry entry;
  final String directory;
  final VoidCallback onExpand;

  @override
  State<_ImageViewRow> createState() => _ImageViewRowState();
}

class _ImageViewRowState extends State<_ImageViewRow> {
  bool _expanded = false, _hovered = false, _focused = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _expanded = PageStorage.maybeOf(context)?.readState(context,
      identifier: 'viewed-images:${widget.entry.id}') as bool? ?? false;
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    PageStorage.maybeOf(context)?.writeState(context, _expanded,
      identifier: 'viewed-images:${widget.entry.id}');
    widget.onExpand();
  }

  @override
  Widget build(BuildContext context) {
    final images = widget.entry.attachments;
    final title = images.length == 1 ? 'Viewed an image' : 'Viewed ${images.length} images';
    final color = _hovered || _focused ? conversationInk : conversationMuted;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Semantics(button: true, expanded: _expanded, child: InkWell(
        borderRadius: BorderRadius.circular(6), onTap: _toggle,
        onHover: (value) => setState(() => _hovered = value),
        onFocusChange: (value) => setState(() => _focused = value),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.photo_library_outlined, size: 16, color: conversationMuted),
          const SizedBox(width: 4),
          Flexible(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 14, height: 1.625, color: color))),
          const SizedBox(width: 4),
          Icon(_expanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded, size: 16, color: color),
        ]),
      )),
      if (_expanded) Padding(padding: const EdgeInsets.only(top: 8, bottom: 4), child: SizedBox(height: 80, child: ListView.separated(
        key: PageStorageKey('viewed-image-rail:${widget.entry.id}'),
        primary: false, padding: EdgeInsets.zero,
        scrollDirection: Axis.horizontal, itemCount: images.length,
        physics: const ClampingScrollPhysics(),
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) => SizedBox(width: 106, height: 80,
          child: ConversationData(value: images[index], builder: (context, value) => ConversationImage(
            source: attachmentDataUrl(jsonObject(value)), label: 'Inspected image', directory: widget.directory, thumbnail: true,
          ))),
      ))),
    ]);
  }
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
    if (_isJavaScriptCell(tool)) return OpenCodeExecute(tool: tool, onExpand: onExpand);
    final color = failed ? Theme.of(context).colorScheme.error : conversationMuted;
    final elapsed = tool.startedAt != null && tool.endedAt != null
        ? _duration(tool.startedAt!, tool.endedAt!) : null;
    final preview = _toolPreview(tool);
    return ConversationDisclosure(
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
        ConversationData(value: tool.rawOutput, builder: (context, output) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ToolImages(output: output, directory: directory),
            _details(identical(output, tool.rawOutput) ? tool.output : conversationDataText(output)),
          ],
        )),
        for (final child in tool.children)
          Padding(padding: const EdgeInsets.only(top: 8), child: _ToolRow(
            key: ValueKey(child.id), tool: child, directory: directory, nested: true, onExpand: onExpand)),
      ])),
    );
  }

  Widget _details(String? output) => ConversationData(value: tool.rawInput, builder: (context, input) => ConversationCode(
    source: identical(input, tool.rawInput) ? tool.input : conversationDataText(input),
    language: tool.name == 'functions.exec' || tool.name == 'exec' ? 'javascript' : 'json',
    output: output,
  ));
}

class _ToolImages extends StatelessWidget {
  const _ToolImages({required this.output, required this.directory});
  final Object? output;
  final String directory;

  @override
  Widget build(BuildContext context) => Column(children: [
    // Parse only when the disclosure is visible. Keep the exact result available
    // in Code & output, including content types with no visual presentation.
    for (final source in _toolImages(output).take(24))
      ConversationImage(source: source, label: 'Tool image', directory: directory),
  ]);
}

Iterable<String> _toolImages(Object? value, [int depth = 0]) sync* {
  if (depth > 8) return;
  if (value is String) {
    try {
      yield* _toolImages(jsonDecode(value), depth + 1);
    } on FormatException {
      // Ordinary output is text, not a serialized MCP result.
    }
  } else if (value is List) {
    for (final part in value) {
      yield* _toolImages(part, depth + 1);
    }
  } else if (value is Map) {
    final mime = value['mimeType'] ?? value['mime_type'];
    if (value['image_url'] case final String source when source.startsWith('data:image/')) {
      yield source;
    } else if (value['type'] == 'image' && value['data'] is String &&
        mime is String && mime.startsWith('image/')) {
      final data = value['data'] as String;
      yield data.startsWith('data:') ? data : 'data:$mime;base64,$data';
    } else {
      for (final key in ['output', 'content', 'contentItems', 'images']) {
        if (value.containsKey(key)) yield* _toolImages(value[key], depth + 1);
      }
    }
  }
}
