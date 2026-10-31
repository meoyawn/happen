import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'conversation_markdown.dart';
import 'session.dart';
import 'composer_attachments.dart';

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
      if (_scroll.position.extentAfter > .5) {
        _jumping = true;
        try {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
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
      if (notification.direction == ScrollDirection.forward) _following = false;
      if (notification.direction == ScrollDirection.reverse && notification.metrics.extentAfter < 80) _following = true;
    }
    if (notification is ScrollEndNotification && notification.metrics.extentAfter < 1) _following = true;
    final showLatest = notification.metrics.extentAfter > 100;
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
    if (task.loading) return const Center(child: CircularProgressIndicator());
    if (task.loadError case final error?) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(padding: const EdgeInsets.all(24), child: SelectableText(error)),
        TextButton(onPressed: widget.onRetry, child: const Text('Retry loading conversation')),
      ]));
    }
    final entries = conversation(task);
    final compacting = entries.any((entry) => entry.compaction?.status == 'running');
    final indices = {for (var i = 0; i < entries.length; i++) entries[i].id: i};
    final starts = task.events.values.where((event) => event['type'] == 'turn.started').toList()
      ..sort((a, b) => (a['seq'] as int).compareTo(b['seq'] as int));
    final startedAt = DateTime.tryParse(starts.lastOrNull?['created_at'] as String? ?? '');
    return Stack(children: [
      Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 880),
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
                  padding: const EdgeInsets.fromLTRB(32, 28, 32, 28),
                  itemCount: entries.length + (task.running && !compacting ? 1 : 0),
                  findChildIndexCallback: (key) => key is ValueKey<String> ? indices[key.value] : null,
                  itemBuilder: (context, index) {
                    if (index == entries.length) return _TurnClock(key: const ValueKey('working'), startedAt: startedAt, status: task.retryStatus);
                    final entry = entries[index];
                    return Padding(
                      key: ValueKey(entry.id),
                      padding: EdgeInsets.only(bottom: entry.tool != null ? 6 : entry.role == 'Status' ? 28 : 22),
                      child: switch (entry.role) {
                        'Tool' => _ToolRow(tool: entry.tool!, directory: widget.directory, onExpand: () => _following = false),
                        'Compaction' => _CompactionRow(
                          entry: entry, directory: widget.directory, retryStatus: task.retryStatus,
                          onExpand: () => _following = false,
                        ),
                        'Reasoning' => ExpansionTile(
                          key: PageStorageKey('reasoning:${entry.id}'),
                          tilePadding: EdgeInsets.zero,
                          childrenPadding: const EdgeInsets.only(left: 24, top: 8, bottom: 12),
                          dense: true,
                          shape: const Border(), collapsedShape: const Border(),
                          leading: const Icon(Icons.auto_awesome_outlined, size: 16, color: conversationMuted),
                          title: const Text('Thinking', style: TextStyle(fontSize: 13, color: conversationMuted)),
                          onExpansionChanged: (_) => _following = false,
                          children: [ConversationMarkdown(text: entry.text, directory: widget.directory)],
                        ),
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
          style: FilledButton.styleFrom(elevation: 2, backgroundColor: const Color(0xffe7eee5)),
        )),
      ),
    ]);
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.entry, required this.directory});
  final ChatEntry entry;
  final String directory;

  @override
  Widget build(BuildContext context) {
    final user = {'You', 'Queued', 'Steer pending'}.contains(entry.role);
    final pending = entry.role == 'Queued' || entry.role == 'Steer pending';
    final body = ConversationMarkdown(text: entry.text, directory: directory, fitContent: user);
    return Column(
      crossAxisAlignment: user ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        if (user)
          LayoutBuilder(builder: (context, constraints) => Align(
            alignment: Alignment.centerRight,
            child: Container(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth * .82),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
              decoration: BoxDecoration(
                color: pending ? const Color(0xfff2f3ee) : const Color(0xffeaf0e6),
                border: pending ? Border.all(color: conversationBorder) : null,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
                if (entry.attachments.isNotEmpty) AttachmentRail(attachments: entry.attachments, directory: directory),
                if (entry.attachments.isNotEmpty && entry.text.isNotEmpty) const SizedBox(height: 10),
                if (entry.text.isNotEmpty) body,
              ]),
            ),
          ))
        else
          body,
        const SizedBox(height: 5),
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: user ? WrapAlignment.end : WrapAlignment.start,
          children: [
            if (pending) const Icon(Icons.schedule_rounded, size: 13, color: conversationMuted),
            Text(entry.role, style: const TextStyle(fontSize: 11, color: conversationMuted)),
            if (entry.timestamp case final at?) _Timestamp(at: at),
            if (!entry.streaming) ConversationCopyButton(text: entry.text, label: user ? 'Copy message' : 'Copy response'),
          ],
        ),
      ],
    );
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
    return Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
      Icon(icon ?? (entry.text == 'Completed' ? Icons.check_rounded : Icons.info_outline_rounded),
        size: 14, color: conversationMuted),
      Text('${entry.text}${elapsed == null ? '' : ' in $elapsed'}',
        style: const TextStyle(fontSize: 12, color: conversationMuted)),
      if (entry.timestamp case final at?) _Timestamp(at: at),
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
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Row(children: [
      const SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
      const SizedBox(width: 10),
      Flexible(child: Text('${widget.status ?? 'Working'}${widget.startedAt == null ? '…' : ' · ${_duration(widget.startedAt!, DateTime.now())}'}',
        style: const TextStyle(fontSize: 12, color: conversationMuted))),
    ]),
  );
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
    final color = failed ? Theme.of(context).colorScheme.error : conversationMuted;
    final elapsed = tool.startedAt != null && tool.endedAt != null
        ? _duration(tool.startedAt!, tool.endedAt!) : null;
    return ExpansionTile(
      key: PageStorageKey('tool:${tool.id}'),
      initiallyExpanded: false,
      dense: true,
      minTileHeight: 44,
      tilePadding: const EdgeInsets.symmetric(horizontal: 8),
      childrenPadding: EdgeInsets.only(left: nested ? 8 : 24, right: 8, bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: const BorderSide(color: conversationBorder)),
      collapsedShape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      onExpansionChanged: (_) => onExpand(),
      leading: running
          ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 1.5))
          : Icon(failed ? Icons.error_outline : tool.status == 'done' ? Icons.check_rounded : Icons.stop_circle_outlined,
              size: 16, color: color),
      title: Text(tool.name, maxLines: 1, overflow: TextOverflow.ellipsis,
        style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: color)),
      subtitle: Text([
        if (tool.children.isNotEmpty) '${tool.children.length} calls',
        switch (tool.status) {'done' => 'Done', 'failed' => 'Failed', 'running' => 'Running', 'stopped' => 'Stopped', _ => 'Interrupted'},
        ?elapsed,
      ].join(' · '), style: TextStyle(fontSize: 11, color: color)),
      children: [
        if (tool.startedAt case final at?) Align(alignment: Alignment.centerLeft,
          child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: _Timestamp(at: at))),
        _ToolImages(output: tool.output, directory: directory),
        if (!nested) ...[
          for (final child in tool.children)
            _ToolRow(key: ValueKey(child.id), tool: child, directory: directory, nested: true, onExpand: onExpand),
          ExpansionTile(
            key: const PageStorageKey('code-output'),
            tilePadding: EdgeInsets.zero,
            dense: true,
            shape: const Border(), collapsedShape: const Border(),
            title: const Text('Code & output', style: TextStyle(fontSize: 12)),
            onExpansionChanged: (_) => onExpand(),
            children: [_details()],
          ),
        ] else
          _details(),
      ],
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
  final String? output;
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
    if (value['type'] == 'image' && value['data'] is String &&
        value['mimeType'] is String && (value['mimeType'] as String).startsWith('image/')) {
      yield 'data:${value['mimeType']};base64,${value['data']}';
    } else {
      for (final key in ['output', 'content', 'contentItems']) {
        if (value.containsKey(key)) yield* _toolImages(value[key], depth + 1);
      }
    }
  }
}
