import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:protocol/protocol.dart';

import 'conversation_markdown.dart';
import 'session.dart';
import 'composer_attachments.dart';
import 'appearance.dart';
import 'conversation_activity.dart';

typedef _TranscriptRow = ({String id, ChatEntry? entry, List<ChatEntry> activity, ChatEntry? status});

List<_TranscriptRow> _transcriptRows(List<ChatEntry> entries, bool codex) {
  final rows = <_TranscriptRow>[];
  var segment = <ChatEntry>[];
  void add(ChatEntry entry) => rows.add((id: entry.id, entry: entry, activity: const [], status: null));
  void flush([ChatEntry? status]) {
    if (codex && status != null && segment.any((entry) => entry.tool != null || entry.role == 'Reasoning')) {
      final finalMessage = status.text == 'Completed' ? segment.lastIndexWhere((entry) => entry.role == 'Happen') : -1;
      final activity = finalMessage < 0 ? segment : segment.sublist(0, finalMessage);
      if (activity.isNotEmpty) rows.add((id: 'activity:${activity.first.id}', entry: null, activity: activity, status: status));
      if (finalMessage >= 0) for (final entry in segment.skip(finalMessage)) { add(entry); }
    } else {
      var activity = <ChatEntry>[];
      void flushActivity() {
        if (activity.isEmpty) return;
        rows.add((id: 'activity:${activity.first.id}', entry: null, activity: activity, status: null));
        activity = [];
      }
      for (final entry in segment) {
        if (entry.tool != null || entry.role == 'Reasoning') {
          activity.add(entry);
        } else {
          flushActivity();
          add(entry);
        }
      }
      flushActivity();
      if (status != null && status.text != 'Completed') add(status);
    }
    segment = [];
  }
  for (final entry in entries) {
    if ({'You', 'Queued', 'Steer pending'}.contains(entry.role)) {
      flush();
      add(entry);
    } else if (entry.role == 'Status') {
      flush(entry);
    } else if (entry.role == 'Error' || entry.role == 'Compaction') {
      flush();
      add(entry);
    } else {
      segment.add(entry);
    }
  }
  flush();
  return rows;
}

Iterable<ToolActivity> _visibleTools(ToolActivity tool, bool codex) sync* {
  if (codex && {'exec', 'functions.exec'}.contains(tool.name) && tool.children.isNotEmpty) {
    for (final child in tool.children) { yield* _visibleTools(child, codex); }
  } else {
    yield tool;
  }
}

/// Retain a small working set of laid-out transcripts during sidebar navigation.
class ConversationDeck extends StatefulWidget {
  const ConversationDeck({super.key, required this.task, required this.tasks,
    required this.directory, required this.empty, required this.onRetry});
  final DesktopTask? task;
  final Set<DesktopTask> tasks;
  final String directory;
  final Widget empty;
  final ValueChanged<DesktopTask> onRetry;

  @override
  State<ConversationDeck> createState() => _ConversationDeckState();
}

class _ConversationDeckState extends State<ConversationDeck> {
  final _retained = LinkedHashMap<DesktopTask, ({Object state, Widget view})>();

  @override
  Widget build(BuildContext context) {
    _retained.removeWhere((task, _) => !widget.tasks.contains(task));
    final selected = widget.task;
    if (selected != null) {
      final previous = _retained.remove(selected);
      final state = (conversation(selected), selected.loading, selected.loadError,
        selected.retryStatus, widget.directory);
      _retained[selected] = previous?.state == state ? previous! : (
        state: state,
        view: ConversationTranscript(
          task: selected, directory: widget.directory,
          onRetry: () => widget.onRetry(selected),
        ),
      );
      while (_retained.length > 16) { _retained.remove(_retained.keys.first); }
    }
    return Stack(fit: StackFit.expand, children: [
      for (final entry in _retained.entries) Offstage(
        key: ValueKey(entry.key.id),
        offstage: entry.key != selected,
        child: TickerMode(
          enabled: entry.key == selected,
          child: ExcludeFocus(
            excluding: entry.key != selected,
            child: RepaintBoundary(child: entry.value.view),
          ),
        ),
      ),
      if (selected == null) widget.empty,
    ]);
  }
}

class ConversationTranscript extends StatefulWidget {
  const ConversationTranscript({super.key, required this.task, required this.directory, required this.onRetry});
  final DesktopTask task;
  final String directory;
  final VoidCallback onRetry;

  @override
  State<ConversationTranscript> createState() => _ConversationTranscriptState();
}

class _ConversationTranscriptState extends State<ConversationTranscript> {
  final _scroll = ScrollController();
  bool _following = true, _scheduled = false, _showLatest = false, _jumping = false;

  @override
  void initState() {
    super.initState();
    _follow();
  }

  @override
  void didUpdateWidget(ConversationTranscript oldWidget) {
    super.didUpdateWidget(oldWidget);
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
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification && !_jumping) _following = false;
    if (notification is UserScrollNotification) {
      if (notification.direction == ScrollDirection.reverse) _following = false;
      if (notification.direction == ScrollDirection.forward && notification.metrics.extentBefore < 80) _following = true;
    }
    if (notification is ScrollEndNotification && notification.metrics.extentBefore < 1) _following = true;
    final showLatest = notification.metrics.extentBefore > 100;
    if (showLatest != _showLatest) setState(() => _showLatest = showLatest);
    return false;
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
    final harness = ConversationAppearance.of(context) == ConversationStyle.harness;
    if (task.loading) return const Center(child: CircularProgressIndicator());
    if (task.loadError case final error?) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(padding: const EdgeInsets.all(24), child: SelectableText(error)),
        TextButton(onPressed: widget.onRetry, child: const Text('Retry loading conversation')),
      ]));
    }
    final entries = conversation(task);
    final compacting = entries.any((entry) => entry.compaction?.status == 'running');
    final rows = _transcriptRows(entries, harness);
    final latest = entries.where((entry) => !{'Queued', 'Steer pending'}.contains(entry.role)).lastOrNull;
    final activeGroup = task.running && rows.isNotEmpty && rows.last.activity.isNotEmpty &&
      identical(rows.last.activity.last, latest);
    final thinking = task.running && !compacting && !activeGroup && (task.streamingText.isEmpty || task.retryStatus != null);
    final count = rows.length + (thinking ? 1 : 0);
    final indices = {for (var i = 0; i < rows.length; i++) rows[i].id: count - 1 - i};
    final starts = task.events.values.where((event) => event['type'] == 'turn.started').toList()
      ..sort((a, b) => (a['seq'] as int).compareTo(b['seq'] as int));
    final startedAt = DateTime.tryParse(starts.lastOrNull?['created_at'] as String? ?? '');
    return Stack(children: [
      Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: harness ? 768 : 800),
          child: NotificationListener<ScrollMetricsNotification>(
            onNotification: (notification) {
              if (notification.depth == 0) _follow();
              return false;
            },
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScroll,
              child: Scrollbar(
                controller: _scroll,
                child: ListView.builder(
                  key: PageStorageKey('transcript:${task.id}'),
                  controller: _scroll,
                  // Start at the newest row without laying out the entire history.
                  reverse: true,
                  cacheExtent: 0,
                  padding: EdgeInsets.fromLTRB(harness ? 16 : 24, 16, harness ? 16 : 24, 20),
                  itemCount: count,
                  findChildIndexCallback: (key) => key is ValueKey<String> ? indices[key.value] : null,
                  itemBuilder: (context, index) {
                    index = count - 1 - index;
                    if (index == rows.length) return _TurnClock(key: const ValueKey('working'), startedAt: startedAt, status: task.retryStatus);
                    final row = rows[index];
                    final entry = row.entry;
                    return Padding(
                      key: ValueKey(row.id),
                      padding: EdgeInsets.only(bottom: index == rows.length - 1 && !thinking ? 0 : 16),
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
                        _ => _Message(entry: entry, directory: widget.directory),
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
    final codex = ConversationAppearance.of(context) == ConversationStyle.harness;
    final tools = [for (final entry in entries) if (entry.tool case final tool?) ..._visibleTools(tool, codex)];
    final running = tools.where((tool) => tool.status == 'running').lastOrNull;
    final elapsed = status?.startedAt != null && status?.timestamp != null
      ? _duration(status!.startedAt!, status!.timestamp!) : null;
    final label = status != null
      ? status!.text == 'Completed' ? elapsed == null ? 'Worked' : 'Worked for $elapsed' : status!.text
      : codex
        ? active ? running == null ? 'Thinking' : _toolLabel(running, true)
          : tools.isEmpty ? 'Thought' : tools.length == 1 ? _toolLabel(tools.single, true) : 'Called ${tools.length} tools'
        : tools.isEmpty ? 'Thought' : 'Used ${tools.length} ${tools.map((tool) => _toolLabel(tool, false)).toSet().length == 1
            ? _toolLabel(tools.first, false) : 'tools'}';
    return ConversationDisclosure(
      key: PageStorageKey('disclosure:${entries.first.id}'),
      label: label, shimmer: codex && active,
      fontSize: codex ? 14 : 13, ruled: codex && status != null,
      onExpand: onExpand, maxHeight: codex && status == null ? 224 : null,
      builder: (context) => Padding(
        padding: EdgeInsets.only(left: codex ? 0 : 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (var i = 0; i < entries.length; i++) Padding(
            key: ValueKey(entries[i].id),
            padding: EdgeInsets.only(top: i == 0 ? 0 : entries[i].tool != null || entries[i].role == 'Reasoning' ? 8 : 16),
            child: entries[i].tool != null
              ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final tool in _visibleTools(entries[i].tool!, codex))
                    Padding(padding: const EdgeInsets.only(bottom: 4),
                      child: _ToolRow(key: ValueKey(tool.id), tool: tool, directory: directory, onExpand: onExpand)),
                ])
              : entries[i].role == 'Reasoning'
                ? _ReasoningRow(entry: entries[i], directory: directory, onExpand: onExpand)
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

String _toolLabel(ToolActivity tool, bool codex) {
  final name = tool.name.split('.').last;
  final running = tool.status == 'running';
  return switch (name) {
    'shell_command' || 'exec_command' || 'bash' => codex ? running ? 'Running command' : 'Ran command' : 'Shell',
    'read' || 'read_file' => codex ? running ? 'Reading file' : 'Read file' : 'Read',
    'write' || 'write_file' || 'apply_patch' || 'edit' => codex ? running ? 'Editing files' : 'Edited files' : 'Edit',
    'exec' => codex ? running ? 'Running code' : 'Ran code' : 'JavaScript',
    _ => tool.name,
  };
}

String? _toolPreview(ToolActivity tool) {
  final name = tool.name.split('.').last;
  if (!{'shell_command', 'exec_command', 'bash', 'read', 'read_file', 'write', 'write_file', 'edit'}.contains(name)) return null;
  try {
    final input = jsonDecode(tool.input);
    if (input is Map) return (input['command'] ?? input['cmd'] ?? input['filePath'] ?? input['path'])?.toString().split('\n').first;
  } on FormatException { /* Raw shell inputs have no JSON envelope. */ }
  return tool.input.split('\n').first;
}

class _Message extends StatefulWidget {
  const _Message({required this.entry, required this.directory});
  final ChatEntry entry;
  final String directory;

  @override
  State<_Message> createState() => _MessageState();
}

class _MessageState extends State<_Message> {
  bool _hovered = false, _focused = false;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final harness = ConversationAppearance.of(context) == ConversationStyle.harness;
    final user = {'You', 'Queued', 'Steer pending'}.contains(entry.role);
    final pending = entry.role == 'Queued' || entry.role == 'Steer pending';
    final body = ConversationMarkdown(text: entry.text, directory: widget.directory, fitContent: user);
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
              constraints: BoxConstraints(maxWidth: constraints.maxWidth * (harness ? .7 : .82)),
              padding: EdgeInsets.symmetric(horizontal: harness ? 16 : 12, vertical: harness ? 10 : 8),
              decoration: BoxDecoration(
                color: pending ? const Color(0xfffafafa) : const Color(0xfff3f3f4),
                border: pending ? Border.all(color: conversationBorder) : null,
                borderRadius: BorderRadius.circular(harness ? 22 : 10),
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
        const SizedBox(height: 4),
        Opacity(opacity: _hovered || _focused || pending ? 1 : 0, alwaysIncludeSemantics: true, child: Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: user ? WrapAlignment.end : WrapAlignment.start,
          children: [
            if (pending) const Icon(Icons.schedule_rounded, size: 13, color: conversationMuted),
            if (pending) Text(entry.role, style: const TextStyle(fontSize: 11, color: conversationMuted)),
            if (entry.timestamp case final at?) _Timestamp(at: at),
            if (!entry.streaming) SizedBox(height: 24,
              child: ConversationCopyButton(text: entry.text, label: user ? 'Copy message' : 'Copy response')),
          ],
        )),
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
        style: const TextStyle(fontSize: 11, color: conversationMuted)),
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
    final elapsed = entry.startedAt != null && entry.timestamp != null
        ? _duration(entry.startedAt!, entry.timestamp!) : null;
    final codex = ConversationAppearance.of(context) == ConversationStyle.harness;
    final label = entry.text == 'Completed' && codex ? elapsed == null ? 'Worked' : 'Worked for $elapsed'
      : entry.text == 'Stopped' && !codex ? 'Interrupted' : entry.text;
    return Row(children: [
      if (!codex) ...[const Expanded(child: Divider(height: 1)), const SizedBox(width: 12)],
      if (icon != null) ...[Icon(icon, size: 14, color: conversationMuted), const SizedBox(width: 6)],
      Text(label, style: const TextStyle(fontSize: 13, height: 20 / 13, color: conversationMuted)),
      if (!codex) ...[const SizedBox(width: 12), const Expanded(child: Divider(height: 1))],
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
  Widget build(BuildContext context) => Semantics(liveRegion: true,
    child: ThinkingLabel(label: widget.status ?? 'Thinking'));
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
        child: Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.photo_library_outlined, size: 16, color: conversationMuted),
          const SizedBox(width: 4),
          Flexible(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, height: 1.625, color: color))),
          const SizedBox(width: 4),
          Icon(_expanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded, size: 16, color: color),
        ])),
      )),
      if (_expanded) Padding(padding: const EdgeInsets.only(top: 8, bottom: 4), child: SizedBox(height: 80, child: ListView.separated(
        scrollDirection: Axis.horizontal, itemCount: images.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) => SizedBox(width: 106, child: ConversationImage(
          source: attachmentDataUrl(images[index]), label: 'Inspected image', directory: widget.directory, thumbnail: true,
        )),
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
    final harness = ConversationAppearance.of(context) == ConversationStyle.harness;
    final color = failed ? Theme.of(context).colorScheme.error : conversationMuted;
    final elapsed = tool.startedAt != null && tool.endedAt != null
        ? _duration(tool.startedAt!, tool.endedAt!) : null;
    final preview = _toolPreview(tool);
    return ConversationDisclosure(
      key: PageStorageKey('tool:${tool.id}'),
      label: _toolLabel(tool, harness), fontSize: harness ? 14 : 13,
      color: failed ? color : harness ? null : conversationInk,
      shimmer: harness && running,
      onExpand: onExpand,
      icon: harness ? Icon(failed ? Icons.error_outline_rounded
        : _toolLabel(tool, false) == 'Shell' ? Icons.terminal_rounded : Icons.extension_outlined, size: 16, color: color) : null,
      summary: preview != null ? Text('${elapsed == null ? '' : '$elapsed  '}$preview', maxLines: 1, overflow: TextOverflow.ellipsis,
        style: TextStyle(fontFamily: 'monospace', fontSize: 12, height: 20 / 12, color: color))
        : elapsed == null || harness ? null : Text(elapsed, style: TextStyle(fontSize: 12, color: color)),
      builder: (context) => Padding(padding: EdgeInsets.only(left: nested ? 8 : harness ? 20 : 12, bottom: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (tool.startedAt case final at?) Align(alignment: Alignment.centerLeft,
          child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: _Timestamp(at: at))),
        Builder(builder: (context) => _ToolImages(output: tool.rawOutput, directory: directory)),
        _details(),
        for (final child in tool.children)
          Padding(padding: const EdgeInsets.only(top: 8), child: _ToolRow(
            key: ValueKey(child.id), tool: child, directory: directory, nested: true, onExpand: onExpand)),
      ])),
    );
  }

  Widget _details() => ConversationCode(
    source: tool.input,
    language: tool.name == 'functions.exec' || tool.name == 'exec' ? 'javascript' : 'json',
    output: tool.output,
  );
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
