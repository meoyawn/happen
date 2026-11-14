import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable, setEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:protocol/protocol.dart' show CancellationToken;
import 'package:super_sliver_list/super_sliver_list.dart';

import 'conversation_markdown.dart';
import 'session.dart';
import 'composer_attachments.dart';
import 'appearance.dart';
import 'conversation_activity.dart';
import 'conversation_streaming.dart';
import 'conversation_tools.dart';
import 'conversation_response.dart';
import 'conversation_scroll_rail.dart';
import 'conversation_changes.dart';
import 'conversation_images.dart';
import 'conversation_event.dart';
import 'conversation_annotations.dart';
import 'response_annotation.dart';
import 'response_annotation_reference.dart';

typedef _TranscriptRow = ({String id, String kind, List<ChatEntry> entries, String? label});
typedef PendingMessageAction = Future<void> Function(DesktopTask task, String inboxID, String action);
typedef ForkResponseAction = Future<void> Function(DesktopTask task, String turnId);

bool _indicatingWork(DesktopTask task, ChatEntry? latest) => task.running &&
  (task.turns[latest?.turnId] == null || task.turns[latest?.turnId]?['status'] == 'inProgress') &&
  !task.questions.values.any((request) => request['async'] != true);

List<_TranscriptRow> _workRows(List<ChatEntry> entries) {
  final rows = <_TranscriptRow>[];
  var activity = <ChatEntry>[];
  void flush() {
    if (activity.isEmpty) return;
    rows.add((id: 'activity:${activity.first.id}', kind: 'activity', entries: activity, label: null));
    activity = [];
  }
  for (final entry in entries) {
    final imageKind = entry.image != null ? 'images' : entry.tool?.name == 'view_image' ? 'imageViews' : null;
    if (imageKind != null) {
      flush();
      final previous = rows.lastOrNull;
      if (previous != null && previous.kind == imageKind && previous.entries.last.turnId == entry.turnId) {
        rows[rows.length - 1] = (id: previous.id, kind: imageKind, entries: [...previous.entries, entry], label: null);
      } else {
        rows.add((id: entry.id, kind: imageKind, entries: [entry], label: null));
      }
      continue;
    }
    if (entry.tool != null && (toolKind(entry.tool!) == 'question' || toolShowsFailure(entry.tool!))) {
      flush();
      rows.add((id: entry.id, kind: 'message', entries: [entry], label: null));
      continue;
    }
    if (entry.tool != null || entry.role == 'Reasoning') { activity.add(entry); continue; }
    flush();
    if (entry.role == 'Status' && entry.text == 'Completed') continue;
    rows.add((id: entry.id, kind: 'message', entries: [entry], label: null));
  }
  flush();
  return rows;
}

List<_TranscriptRow> _transcriptRows(List<ChatEntry> entries, DesktopTask task, Set<String> expandedTurns) {
  entries = [for (final entry in entries)
    if (entry.tool case final tool?)
      for (final visible in visibleConversationTools([tool]))
        if (identical(visible, tool)) entry
        else ChatEntry(visible.id, 'Tool', visible.name, tool: visible,
          timestamp: visible.startedAt ?? entry.timestamp, turnId: entry.turnId)
    else entry,
  ];
  final rows = <_TranscriptRow>[];
  // Steering and question replies can split one turn into several segments.
  final lastEntries = {
    for (final entry in entries)
      if (entry.turnId != null && entry.role != 'Queued') entry.turnId!: entry,
  };
  final queued = <ChatEntry>[];
  var response = <ChatEntry>[];
  String? responseTurnId;
  var segment = 'initial';
  void flush({bool latest = false}) {
    final turnId = responseTurnId;
    final turn = task.turns[turnId];
    if (response.isEmpty && !(latest && task.running)) {
      responseTurnId = null;
      return;
    }
    final active = task.running && (turn?['status'] == 'inProgress' || latest && turn == null);
    if (active) {
      rows.addAll(_workRows(response));
    } else {
      final answer = response.where((entry) => entry.role == 'Happen' && entry.phase != 'commentary').lastOrNull;
      final work = response.where((entry) => entry != answer && !{'Answer', 'Error', 'Status', 'Compaction', 'Image'}.contains(entry.role)).toList();
      if (work.isNotEmpty) {
        final start = turn?['startedAt'] is int ? DateTime.fromMillisecondsSinceEpoch((turn!['startedAt'] as int) * 1000)
          : work.first.startedAt ?? work.first.timestamp;
        final end = turn?['completedAt'] is int ? DateTime.fromMillisecondsSinceEpoch((turn!['completedAt'] as int) * 1000)
          : answer?.timestamp ?? work.last.tool?.endedAt ?? work.last.timestamp;
        final elapsed = start != null && end != null ? _duration(start, end) : null;
        final stopped = turn?['status'] == 'interrupted' || response.any((entry) => entry.role == 'Status' && entry.text == 'Stopped');
        final id = 'turn:$segment';
        rows.add((id: id, kind: 'turn', entries: work,
          label: stopped ? elapsed == null ? 'You stopped this response' : 'You stopped after $elapsed'
            : elapsed == null ? 'Worked' : 'Worked for $elapsed'));
        if (expandedTurns.contains(id)) rows.addAll(_workRows(work));
        final visible = response.where((entry) => entry == answer ||
          {'Answer', 'Error', 'Status', 'Compaction', 'Image'}.contains(entry.role)).toSet();
        rows.addAll(_workRows(response).where((row) => visible.contains(row.entries.first)));
      } else {
        rows.addAll(_workRows(response));
      }
      if (turn?['diff'] case final String diff when diff.isNotEmpty && response.contains(lastEntries[turnId])) {
        rows.add((id: 'changes:$turnId', kind: 'changes', entries: const [], label: turnId));
      }
    }
    response = [];
    responseTurnId = null;
  }
  for (final entry in entries) {
    if (entry.role == 'Queued') { queued.add(entry); continue; }
    if (entry.role == 'You' || entry.role == 'Answer') {
      flush();
      segment = entry.id;
      responseTurnId = entry.turnId;
      rows.addAll(_workRows([entry]));
    } else {
      // Retrying starts a new turn without another user message. Its live
      // activity must not inherit the failed turn's collapsed presentation.
      if (responseTurnId != null && entry.turnId != null && responseTurnId != entry.turnId) {
        flush();
        segment = entry.id;
      }
      responseTurnId ??= entry.turnId;
      response.add(entry);
    }
  }
  flush(latest: true);
  final latest = entries.where((entry) => entry.role != 'Queued').lastOrNull;
  final activity = rows.lastOrNull;
  final activityOwnsStatus = activity?.kind == 'activity' && identical(activity?.entries.last, latest);
  final retrying = task.retryStatus?['error'] != null || task.retryStatus?['provider_delay'] == true;
  rows.addAll(_workRows(queued));
  // The latest activity group owns the live status, including the pause after
  // its tools finish. Commentary and steering hand it back to the placeholder.
  if (_indicatingWork(task, latest) && (retrying || !activityOwnsStatus &&
      latest?.tool?.status != 'running' && latest?.compaction?.status != 'running' &&
      !(latest?.image != null && latest!.streaming) &&
      !(latest?.role == 'Happen' && latest!.phase != 'commentary'))) {
    rows.add((id: 'working', kind: 'working', entries: const [], label: 'Thinking'));
  }
  return rows;
}

/// Task data is cached by the session; only the selected transcript is mounted.
class ConversationDeck extends StatefulWidget {
  const ConversationDeck({super.key, required this.task, required this.tasks,
    required this.directory, required this.empty, required this.onRetry, this.onRetryTurn, this.onLoadEarlier, this.onPendingAction, this.onFork});
  final DesktopTask? task;
  final Set<DesktopTask> tasks;
  final String directory;
  final Widget empty;
  final ValueChanged<DesktopTask> onRetry;
  final ValueChanged<DesktopTask>? onRetryTurn;
  final ValueChanged<DesktopTask>? onLoadEarlier;
  final PendingMessageAction? onPendingAction;
  final ForkResponseAction? onFork;

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
      onFork: widget.onFork,
    );
  }
}

class ConversationTranscript extends StatefulWidget {
  const ConversationTranscript({super.key, required this.task, required this.directory, required this.onRetry, this.onRetryTurn, this.onLoadEarlier, this.onPendingAction, this.onFork});
  final DesktopTask task;
  final String directory;
  final VoidCallback onRetry;
  final VoidCallback? onRetryTurn;
  final VoidCallback? onLoadEarlier;
  final PendingMessageAction? onPendingAction;
  final ForkResponseAction? onFork;

  @override
  State<ConversationTranscript> createState() => _ConversationTranscriptState();
}

class _ConversationTranscriptState extends State<ConversationTranscript> {
  final _scroll = ScrollController();
  late final _list = ListController()..addListener(_scheduleRailRead);
  late final _visiblePrompts = ValueNotifier<Set<String>>(const {});
  late List<ConversationPrompt> _prompts = [];
  late List<String?> _promptForRow = [];
  late final _promptKeys = <String, GlobalKey>{};
  late final _rowAnchors = <String, RenderBox>{};
  ({String id, double top})? _viewportAnchor;
  CancellationToken? _promptNavigation;
  late bool _railReadScheduled = false;
  bool _following = true, _scheduled = false, _showLatest = false, _jumping = false, _userScrolling = false;
  bool _pagingScheduled = false, _latestScheduled = false;
  bool _autofillBlocked = false;
  String? _lastSentID;
  final _expandedTurns = <String>{};
  int _expansionRevision = 0;
  Object? _contentState;
  Widget? _content;
  int _visibleRows = 0;
  ({double extent, int rows})? _pagingPosition;

  @override
  void initState() {
    super.initState();
    _lastSentID = widget.task.lastSentID;
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
  }

  @override
  void reassemble() {
    super.reassemble();
    _contentState = null;
  }

  void _follow() {
    if (_scheduled || !_following || !_scroll.hasClients || _scroll.position.extentBefore <= .5) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted || !_following || !_scroll.hasClients || _scroll.position.isScrollingNotifier.value) return;
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
    _scheduleRailRead();
    if (notification is ScrollStartNotification && !_jumping && notification.dragDetails != null) {
      _following = false;
      _autofillBlocked = false;
      _userScrolling = true;
    }
    if (notification is UserScrollNotification) {
      if (notification.direction != ScrollDirection.idle) {
        _cancelPromptNavigation();
        _userScrolling = true;
        _autofillBlocked = false;
      }
      if (notification.direction == ScrollDirection.reverse) _following = false;
      if (notification.direction == ScrollDirection.forward && notification.metrics.extentBefore < 24) _following = true;
    }
    if (notification is ScrollEndNotification) {
      if (_userScrolling && notification.metrics.extentBefore < 1) _following = true;
      _userScrolling = false;
      _follow();
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
        _pagingPosition = (extent: _scroll.position.maxScrollExtent, rows: _visibleRows);
        widget.onLoadEarlier?.call();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _latest() {
    _cancelPromptNavigation();
    _following = true;
    _follow();
    setState(() => _showLatest = false);
  }

  void _scheduleRailRead() {
    if (!mounted || _railReadScheduled) return;
    _railReadScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _railReadScheduled = false;
      if (!mounted || !_list.isAttached) return;
      final anchor = _viewportAnchor;
      _viewportAnchor = null;
      if (!_following && _promptNavigation == null && _scroll.hasClients && !_scroll.position.isScrollingNotifier.value) {
        final box = anchor == null ? null : _rowAnchors[anchor.id];
        if (box != null && _anchorLaidOut(box)) {
          final delta = box.localToGlobal(Offset.zero).dy - anchor!.top;
          if (delta.abs() > .5) {
            // New rows and streamed height changes must not move the passage
            // being read. User intent clears the anchor before scrolling.
            _jumping = true;
            try { _scroll.jumpTo((_scroll.offset - delta).clamp(_scroll.position.minScrollExtent, _scroll.position.maxScrollExtent)); }
            finally { _jumping = false; }
            _scheduleRailRead();
            return;
          }
        }
        _viewportAnchor = _readViewportAnchor();
      }
      final range = _list.visibleRange;
      final visible = <String>{};
      if (range != null) {
        for (var i = math.max(0, range.$1); i <= range.$2 && i < _promptForRow.length; i++) {
          if (_promptForRow[i] case final id?) visible.add(id);
        }
      }
      if (visible.isEmpty && _prompts.isNotEmpty) visible.add(_prompts.last.id);
      if (!setEquals(visible, _visiblePrompts.value)) _visiblePrompts.value = Set.unmodifiable(visible);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _cancelPromptNavigation() {
    _viewportAnchor = null;
    final navigation = _promptNavigation;
    if (navigation == null) return;
    _promptNavigation = null;
    navigation.cancel();
    if (_scroll.hasClients) _scroll.jumpTo(_scroll.offset);
  }

  ({String id, double top})? _readViewportAnchor() {
    ({String id, double top})? first;
    for (final entry in _rowAnchors.entries) {
      final box = entry.value;
      if (!_anchorLaidOut(box)) continue;
      final viewport = RenderAbstractViewport.maybeOf(box) as RenderBox?;
      if (viewport == null || !viewport.hasSize) continue;
      final top = box.localToGlobal(Offset.zero).dy;
      final edge = viewport.localToGlobal(const Offset(0, 16)).dy;
      if (top <= edge && top + box.size.height > edge) return (id: entry.key, top: top);
      if (top > edge && top < edge + viewport.size.height && (first == null || top < first.top)) first = (id: entry.key, top: top);
    }
    return first;
  }

  bool _anchorLaidOut(RenderBox box) {
    if (!box.attached || !box.hasSize) return false;
    RenderObject? child = box;
    while (child != null && child is! RenderAbstractViewport) {
      final data = child.parentData;
      if (data is SliverMultiBoxAdaptorParentData && data.keptAlive) return false;
      child = child.parent;
    }
    return child != null;
  }

  void _expand() { _cancelPromptNavigation(); _following = false; }

  Future<void> _revealPrompt(String id, {bool instant = false}) async {
    if (!_list.isAttached || !_scroll.hasClients) return;
    _cancelPromptNavigation();
    final navigation = _promptNavigation = CancellationToken();
    _following = false;
    try {
      var target = _promptKeys[id]?.currentContext;
      final mountedTarget = target != null;
      // An indexed seek mounts only the destination. Resolve its real geometry
      // after layout, including an estimated last row at the history edge.
      for (var seek = 0; target == null && seek < 3; seek++) {
        final prompt = _prompts.where((entry) => entry.id == id).firstOrNull;
        if (prompt == null || !_list.isAttached) return;
        _list.jumpToItem(index: prompt.index, scrollController: _scroll, alignment: 1);
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || navigation.isCancelled) return;
        target = _promptKeys[id]?.currentContext;
      }
      if (target == null || !target.mounted) return;
      await Scrollable.ensureVisible(target, alignment: 1,
        duration: instant || !mountedTarget || MediaQuery.disableAnimationsOf(context)
          ? Duration.zero : const Duration(milliseconds: 260), curve: Curves.easeOutCubic);
    } finally {
      if (identical(_promptNavigation, navigation)) {
        _promptNavigation = null;
        _scheduleRailRead();
      }
    }
  }

  Widget _scrollInput(Widget child) => Focus(canRequestFocus: false, onKeyEvent: (_, event) {
    if ((event is KeyDownEvent || event is KeyRepeatEvent) && [LogicalKeyboardKey.pageUp, LogicalKeyboardKey.pageDown,
        LogicalKeyboardKey.home, LogicalKeyboardKey.end, LogicalKeyboardKey.arrowUp, LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.space].contains(event.logicalKey)) {
      _cancelPromptNavigation();
      if ([LogicalKeyboardKey.pageUp, LogicalKeyboardKey.home, LogicalKeyboardKey.arrowUp].contains(event.logicalKey) ||
          event.logicalKey == LogicalKeyboardKey.space && HardwareKeyboard.instance.isShiftPressed) {
        _following = false;
      }
    }
    return KeyEventResult.ignored;
  }, child: Listener(
    onPointerDown: (_) => _cancelPromptNavigation(),
    onPointerSignal: (event) {
      if (event is PointerScrollEvent && event.scrollDelta.dy.abs() > event.scrollDelta.dx.abs()) {
        _cancelPromptNavigation();
        if (event.scrollDelta.dy < 0) _following = false;
      }
    },
    onPointerPanZoomStart: (_) { _cancelPromptNavigation(); _following = false; },
    child: child,
  ));

  void _toggleTurn(BuildContext context, String id) {
    _cancelPromptNavigation();
    final box = context.findRenderObject();
    final top = box is RenderBox ? box.localToGlobal(Offset.zero).dy : null;
    _following = false;
    setState(() {
      if (!_expandedTurns.remove(id)) _expandedTurns.add(id);
      _expansionRevision++;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !context.mounted || top == null || !_scroll.hasClients) return;
      final next = context.findRenderObject();
      if (next is! RenderBox || !next.attached) return;
      final delta = next.localToGlobal(Offset.zero).dy - top;
      if (delta.abs() > .5) _scroll.jumpTo((_scroll.offset - delta)
        .clamp(_scroll.position.minScrollExtent, _scroll.position.maxScrollExtent));
    });
  }

  @override
  void dispose() {
    _promptNavigation?.cancel();
    _list.removeListener(_scheduleRailRead);
    _list.dispose();
    _visiblePrompts.dispose();
    _rowAnchors.clear();
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
    // Session notifications include activity in other threads. Preserve the
    // mounted list when its data has not changed, including during scrolling.
    final contentState = (entries, widget.directory, task, task.running, task.archived, task.archiving, task.retryStatus, task.runStartedAt,
      task.historyBefore, task.loadingEarlier, task.loadError, task.lastSentID,
      task.questions.values.any((request) => request['async'] != true),
      widget.onLoadEarlier != null, widget.onRetryTurn != null, widget.onPendingAction != null, widget.onFork != null,
      _expansionRevision);
    if (_contentState != contentState) {
      if (!_following && _promptNavigation == null) _viewportAnchor ??= _readViewportAnchor();
      _contentState = contentState;
      _content = _buildContent(entries);
    }
    final annotationScope = ConversationAnnotationScope.maybeOf(context);
    return ConversationAnnotationSelection(onAdd: annotationScope?.enabled == true ? annotationScope!.onAdd : null,
      child: LayoutBuilder(builder: (context, constraints) => Stack(children: [
      Positioned.fill(child: _content!),
      if ((constraints.maxWidth - math.min(desktopConversationWidth, constraints.maxWidth)) / 2 >= 48 &&
          constraints.maxHeight > 0 && _prompts.isNotEmpty)
        Positioned(left: 16, top: 0, bottom: 0, child: Center(child: SelectionContainer.disabled(
          child: ValueListenableBuilder<Set<String>>(valueListenable: _visiblePrompts, builder: (context, visible, _) =>
            ConversationScrollRail(entries: _prompts, visibleEntries: visible, directory: widget.directory,
              maxHeight: math.min(constraints.maxHeight, math.min(MediaQuery.sizeOf(context).height * .7, 640)),
              onReveal: (id, {instant = false}) { unawaited(_revealPrompt(id, instant: instant)); })),
        ))),
      if (_showLatest) Positioned(
        bottom: 12, left: 0, right: 0,
        child: Center(child: FilledButton.tonalIcon(
          onPressed: _latest,
          icon: const Icon(Icons.arrow_downward_rounded, size: 16),
          label: const Text('Jump to latest'),
          style: FilledButton.styleFrom(elevation: 1, backgroundColor: const Color(0xfff1f1f3), foregroundColor: desktopForeground),
        )),
      ),
    ])));
  }

  Widget _buildContent(List<ChatEntry> entries) {
    final task = widget.task;
    _follow();
    final rows = _transcriptRows(entries, task, _expandedTurns);
    final responses = <String, String>{}, toolCalls = <String, int>{};
    int calls(ToolActivity tool) => 1 + tool.children.fold(0, (count, child) => count + calls(child));
    final annotationContexts = <String, List<ResponseAnnotation>>{};
    var annotations = const <ResponseAnnotation>[];
    for (final entry in entries) {
      if (entry.role == 'Queued') continue;
      final turnId = entry.turnId;
      if (turnId != null) {
        if (entry.response != null) responses[turnId] = entry.id;
        if (entry.tool case final tool?) toolCalls[turnId] = (toolCalls[turnId] ?? 0) + calls(tool);
      }
      if (entry.role == 'You') annotations = entry.annotations;
      annotationContexts[entry.id] = annotations;
    }
    final latest = entries.where((entry) => entry.role != 'Queued').lastOrNull;
    final latestRowID = rows.where((row) => row.entries.isEmpty || row.entries.last.role != 'Queued').lastOrNull?.id;
    final count = rows.length;
    _visibleRows = count;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _loadEarlier(_scroll.position);
    });
    final historyOffset = task.historyBefore != null ? 1 : 0;
    final itemCount = count + historyOffset;
    final indices = {for (var i = 0; i < rows.length; i++) rows[i].id: count - 1 - i};
    _prompts = [];
    for (final entry in entries) {
      if (entry.role == 'You' && indices.containsKey(entry.id)) {
        _prompts.add((id: entry.id, text: entry.text.trim(), response: null, index: indices[entry.id]!, liveResponse: null));
      } else if (entry.role == 'Happen' && _prompts.isNotEmpty) {
        final prompt = _prompts.last;
        _prompts[_prompts.length - 1] = (id: prompt.id, text: prompt.text, index: prompt.index,
          response: entry.text, liveResponse: entry.streaming ? task.liveText : null);
      }
    }
    _promptForRow = List.filled(itemCount, null);
    final promptIds = _prompts.map((entry) => entry.id).toSet();
    _promptKeys.removeWhere((id, _) => !promptIds.contains(id));
    for (final id in promptIds) { _promptKeys.putIfAbsent(id, GlobalKey.new); }
    String? promptId;
    for (final row in rows) {
      if (row.kind == 'message' && row.entries.single.role == 'You') promptId = row.id;
      _promptForRow[indices[row.id]!] = promptId;
    }
    _scheduleRailRead();
    final started = task.runStartedAt;
    final startedAt = started == null ? null : DateTime.fromMillisecondsSinceEpoch(started);
    Widget buildRow(BuildContext context, int index) {
      if (historyOffset == 1 && index == count) return Column(
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
      final row = rows[count - 1 - index];
      if (row.kind == 'working') {
        if (task.retryStatus?['error'] != null || task.retryStatus?['provider_delay'] == true) {
          return _ProviderRetryNotice(key: const ValueKey('working'), status: task.retryStatus!);
        }
        return _TurnClock(key: const ValueKey('working'), startedAt: startedAt,
          status: task.retryStatus?['message'] as String? ?? row.label);
      }
      if (row.kind == 'turn') return Padding(
        key: ValueKey(row.id), padding: const EdgeInsets.only(bottom: 6),
        child: Builder(builder: (context) => _TurnFold(
          label: row.label!, expanded: _expandedTurns.contains(row.id),
          onToggle: () => _toggleTurn(context, row.id))));
      if (row.kind == 'changes') return Padding(
        key: ValueKey(row.id), padding: const EdgeInsets.only(bottom: 16, left: 4, right: 4),
        child: ConversationChangedFiles(key: PageStorageKey(row.id), source: 'turn:${row.label}',
          files: changesForSource(task, 'turn:${row.label}'), directory: widget.directory));
      if (row.kind == 'images') return Padding(
        key: ValueKey(row.id), padding: const EdgeInsets.only(bottom: 16, left: 4, right: 4),
        child: ConversationGeneratedImages(items: row.entries, directory: widget.directory,
          conversationImages: entries.where((entry) => entry.image != null).toList(growable: false),
          onExpand: _expand));
      if (row.kind == 'imageViews') return Padding(
        key: ValueKey(row.id), padding: const EdgeInsets.only(bottom: 8),
        child: ConversationInspectedImages(tools: row.entries.map((entry) => entry.tool!).toList(growable: false),
          directory: widget.directory, onExpand: _expand));
      final entry = row.kind == 'message' ? row.entries.single : null;
      return Padding(
        key: ValueKey(row.id),
        padding: EdgeInsets.only(
          top: entry?.role == 'You' && index > 0 ? 8 : 0,
          bottom: entry == null ? 8 : entry.role == 'You' || entry.response != null ? 16 : 8),
        child: entry == null ? _ActivityGroup(
          key: PageStorageKey(row.id), entries: row.entries,
          active: _indicatingWork(task, row.entries.last) && row.id == latestRowID &&
            task.retryStatus?['error'] == null && task.retryStatus?['provider_delay'] != true,
          directory: widget.directory, onExpand: _expand,
        ) : switch (entry.role) {
          'Tool' => _ToolRow(tool: entry.tool!, directory: widget.directory, onExpand: _expand),
          'Compaction' => _CompactionRow(
            entry: entry, directory: widget.directory, retryStatus: task.retryStatus,
            onExpand: _expand,
          ),
          'Reasoning' => _ReasoningRow(entry: entry, active: entry.streaming && identical(entry, latest),
            directory: widget.directory, onExpand: _expand),
          'Status' => _TurnStatus(entry: entry),
          'Answer' => QuestionAnswerRow(id: entry.id, answers: entry.questionAnswers,
            onExpand: _expand),
          'Error' => _ErrorMessage(entry: entry,
            onRetry: !task.running && !task.archived && entry.id == latest?.id ? widget.onRetryTurn : null),
          _ => Padding(padding: EdgeInsets.symmetric(horizontal: entry.role == 'You' || entry.role == 'Queued' ? 0 : 4),
            child: ResponseAnnotationContext(annotations: annotationContexts[entry.id] ?? const [],
            child: _Message(key: _promptKeys[entry.id], entry: entry, directory: widget.directory,
            running: task.running,
            turn: responses[entry.turnId] == entry.id ? task.turns[entry.turnId] : null,
            toolCalls: toolCalls[entry.turnId] ?? 0,
            onExpand: _expand,
            onFork: widget.onFork == null || task.archiving || task.sideParentID != null ||
                entry.response == null || entry.turnId == null || task.turns[entry.turnId]?['status'] == 'inProgress'
              ? null : () => widget.onFork!(task, entry.turnId!),
            onPendingAction: widget.onPendingAction == null || entry.role != 'Queued' ||
                task.pending[entry.id.substring('pending:'.length)]?['sending'] == true ? null
              : (action) => widget.onPendingAction!(task, entry.id.substring('pending:'.length), action),
            liveText: entry.streaming ? task.liveText : null))),
        },
      );
    }
    return LayoutBuilder(builder: (context, constraints) {
        final sidePadding = constraints.maxWidth > desktopConversationWidth + 40
          ? (constraints.maxWidth - desktopConversationWidth) / 2 : 20.0;
        return NotificationListener<ScrollMetricsNotification>(
            onNotification: (notification) {
              if (notification.depth == 0) {
                _follow();
                _loadEarlier(notification.metrics);
                _scheduleRailRead();
              }
              return false;
            },
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScroll,
              child: _scrollInput(CustomScrollView(
                key: PageStorageKey((task.id, AxisDirection.up)),
                controller: _scroll,
                reverse: true,
                semanticChildCount: itemCount,
                physics: const SuperRangeMaintainingScrollPhysics(),
                // Keep nearby messages laid out without mounting all history.
                scrollCacheExtent: const ScrollCacheExtent.viewport(1),
                slivers: [SliverPadding(
                  padding: EdgeInsets.fromLTRB(sidePadding, 24, sidePadding, 24),
                  sliver: SuperSliverList.builder(
                    listController: _list,
                    delayPopulatingCacheArea: true,
                    itemCount: itemCount,
                    findChildIndexCallback: (key) => key == const ValueKey('transcript-history') && historyOffset == 1
                      ? count : key is ValueKey<String> ? indices[key.value] : null,
                    itemBuilder: (context, index) {
                      final id = index == count ? 'transcript-history' : rows[count - 1 - index].id;
                      return ConversationScrollAnchor(key: ValueKey(id), id: id, anchors: _rowAnchors,
                        child: buildRow(context, index));
                    },
                  ),
                )],
              )),
            ),
          );
      });
  }
}

class _ActivityGroup extends StatelessWidget {
  const _ActivityGroup({super.key, required this.entries, required this.directory, required this.onExpand,
    required this.active});
  final List<ChatEntry> entries;
  final String directory;
  final VoidCallback onExpand;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final tools = [for (final entry in entries) if (entry.tool != null) entry.tool!];
    final running = tools.where((tool) => tool.status == 'running').lastOrNull;
    final thinking = active && running == null;
    if (entries.length == 1 && tools.length == 1 && !active) {
      return _ToolRow(tool: tools.single, directory: directory, onExpand: onExpand);
    }
    if (entries.length == 1 && tools.isEmpty) {
      return _ReasoningRow(entry: entries.single, active: active,
        directory: directory, onExpand: onExpand);
    }
    final thought = entries.where((entry) => entry.role == 'Reasoning').lastOrNull;
    final label = thinking ? entries.last.role == 'Reasoning' ? _thoughtPreview(thought?.text ?? '', active: true) : 'Thinking'
      : active && running != null ? toolLabel(running, directory: directory, active: true)
      : tools.isEmpty ? entries.length == 1 ? 'Thought' : 'Thought (×${entries.length})' : toolGroupSummary(tools);
    final failed = tools.any(toolShowsFailure);
    return ConversationDisclosure(
      key: PageStorageKey('disclosure:${entries.first.id}'),
      label: label, shimmer: active, timestamp: entries.first.timestamp,
      color: failed ? desktopError : desktopSecondary,
      icon: thinking && entries.last.role != 'Reasoning' ? null : ConversationWorkIcon(kind: thinking || tools.isEmpty ? 'reasoning'
        : active && running != null ? toolKind(running)
        : tools.map(toolKind).toSet().length == 1 ? toolKind(tools.first) : 'tool', failed: failed),
      fontSize: 14,
      onExpand: onExpand,
      builder: (context) => ConstrainedBox(constraints: const BoxConstraints(maxHeight: 224),
          child: SingleChildScrollView(key: PageStorageKey('work-log:${entries.first.id}'),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 4, children: [
              for (final entry in entries)
                if (entry.tool != null) _ToolRow(key: ValueKey(entry.id),
                  tool: entry.tool!, directory: directory, onExpand: onExpand)
                else _ReasoningRow(entry: entry, active: thinking && identical(entry, entries.last),
                  directory: directory, onExpand: onExpand),
            ]))),
    );
  }
}

class _ReasoningRow extends StatelessWidget {
  const _ReasoningRow({required this.entry, required this.active, required this.directory, required this.onExpand});
  final ChatEntry entry;
  final bool active;
  final String directory;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) => ConversationDisclosure(
    key: PageStorageKey('reasoning:${entry.id}'),
    label: _thoughtPreview(entry.text, active: active), fontSize: 14, timestamp: entry.timestamp,
    icon: const ConversationWorkIcon(kind: 'reasoning'),
    shimmer: active,
    onExpand: onExpand,
    builder: (context) => Padding(padding: const EdgeInsets.fromLTRB(30, 4, 2, 8),
      child: ConstrainedBox(constraints: const BoxConstraints(maxHeight: 384),
        child: SingleChildScrollView(child: ConversationMarkdown(text: entry.text, directory: directory, reasoning: true)))),
  );
}

String _thoughtPreview(String text, {required bool active}) {
  final plain = text.replaceAll(RegExp(r'[#*`_]+'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
  return plain.isEmpty ? active ? 'Thinking' : 'Thought' : plain;
}

class _TurnFold extends StatelessWidget {
  const _TurnFold({required this.label, required this.expanded, required this.onToggle});
  final String label;
  final bool expanded;
  final VoidCallback onToggle;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.only(top: 4, bottom: 8),
    decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0x99e4e4e7)))),
    child: Align(alignment: Alignment.centerLeft, child: Semantics(button: true, expanded: expanded,
      child: InkWell(onTap: onToggle, borderRadius: BorderRadius.circular(6),
        mouseCursor: WidgetStateMouseCursor.clickable,
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(label, style: const TextStyle(fontSize: 14, height: 1.625,
              color: desktopSecondary, fontFeatures: [FontFeature.tabularFigures()])),
            const SizedBox(width: 4),
            Icon(expanded ? Icons.keyboard_arrow_down_rounded : Icons.chevron_right_rounded,
              size: 16, color: desktopSecondary),
          ]))))),
  );
}

class _Message extends StatefulWidget {
  const _Message({super.key, required this.entry, required this.directory, this.liveText, this.onPendingAction, this.onFork,
    this.onExpand, this.running = false, this.turn, this.toolCalls = 0});
  final ChatEntry entry;
  final String directory;
  final ValueListenable<String>? liveText;
  final Future<void> Function(String action)? onPendingAction;
  final Future<void> Function()? onFork;
  final bool running;
  final Map<String, Object?>? turn;
  final int toolCalls;
  final VoidCallback? onExpand;

  @override
  State<_Message> createState() => _MessageState();
}

class _MessageState extends State<_Message> {
  bool _hovered = false, _focused = false;
  bool _changing = false, _forking = false;

  Future<void> _fork() async {
    if (_forking || widget.onFork == null) return;
    setState(() => _forking = true);
    try {
      await widget.onFork!();
    } finally {
      if (mounted) setState(() => _forking = false);
    }
  }

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
      icon: Icon(icon, size: 14, color: desktopSecondary)),
  );

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final pending = entry.role == 'Queued';
    if (entry.event case final event?) return ConversationEventCard(
      key: PageStorageKey(entry.id), event: event, timestamp: entry.timestamp, queued: pending, onExpand: widget.onExpand,
      actions: !pending || widget.onPendingAction == null ? null : Row(mainAxisSize: MainAxisSize.min, children: [
        _action('steer', widget.running ? 'Steer' : 'Send', Icons.arrow_upward_rounded),
        const SizedBox(width: 8), _action('delete', 'Delete', Icons.delete_outline_rounded),
      ]),
    );
    final user = entry.role == 'You' || pending;
    final body = ConversationAnnotationTarget(messageId: entry.id, annotatable: !user && !entry.streaming,
      child: user ? ConversationMarkdown(text: entry.text, directory: widget.directory, fitContent: true)
      : SmoothConversationText(text: entry.text, directory: widget.directory, streaming: entry.streaming, source: widget.liveText));
    return ConversationImageGroup(child: MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(onFocusChange: (value) => setState(() => _focused = value), child: Column(
      crossAxisAlignment: user ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        if (user && entry.annotations.isNotEmpty) Align(alignment: Alignment.centerRight,
          child: FractionallySizedBox(widthFactor: .8, child: ResponseAnnotationAttachments(annotations: entry.annotations))),
        if (user && entry.attachments.isNotEmpty) ...[
          LayoutBuilder(builder: (context, constraints) => Align(alignment: Alignment.centerRight,
            child: ConstrainedBox(constraints: BoxConstraints(maxWidth: constraints.maxWidth * .8),
              child: AttachmentRail(attachments: entry.attachments, directory: widget.directory)))),
          if (entry.text.isNotEmpty) const SizedBox(height: 8),
        ],
        if (user && entry.text.isNotEmpty)
          LayoutBuilder(builder: (context, constraints) => Align(
            alignment: Alignment.centerRight,
            child: Container(
              key: ValueKey('message-bubble:${entry.id}'),
              constraints: BoxConstraints(maxWidth: constraints.maxWidth * .8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: pending ? desktopSidebar : desktopMuted,
                border: pending ? Border.all(color: desktopBorder) : null,
                borderRadius: BorderRadius.circular(16),
              ),
              child: body,
            ),
          ))
        else if (!user && entry.text.isNotEmpty)
          body,
        if (!user && entry.attachments.isNotEmpty)
          ConversationImageParts(parts: entry.attachments, directory: widget.directory),
        if (!user) ...[
          if (entry.response != null) SelectionContainer.disabled(child: ConversationResponseFooter(entry: entry, visible: _hovered || _focused,
            turn: widget.turn, toolCalls: widget.toolCalls,
            onFork: widget.onFork == null ? null : _fork, forking: _forking)),
        ] else ...[
        const SizedBox(height: 4),
        Opacity(opacity: _hovered || _focused || pending ? 1 : 0,
          alwaysIncludeSemantics: true, child: Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: user ? WrapAlignment.end : WrapAlignment.start,
          children: [
            if (pending) const Icon(Icons.schedule_rounded, size: 13, color: desktopSecondary),
            if (pending) Text(entry.role, style: const TextStyle(fontSize: 11, color: desktopSecondary)),
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
          color: desktopSecondary)),
    );
  }
}

String _duration(DateTime start, DateTime end) {
  final seconds = end.difference(start).inSeconds.clamp(0, 1 << 32);
  return _durationSeconds(seconds);
}

String _durationSeconds(int seconds) {
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
      if (icon != null) ...[Icon(icon, size: 14, color: desktopSecondary), const SizedBox(width: 6)],
      Text(label, style: const TextStyle(fontSize: 13, height: 20 / 13, color: desktopSecondary)),
      const SizedBox(width: 12), const Expanded(child: Divider(height: 1)),
    ]);
  }
}

class _CompactionRow extends StatelessWidget {
  const _CompactionRow({required this.entry, required this.directory, required this.onExpand, this.retryStatus});
  final ChatEntry entry;
  final String directory;
  final VoidCallback onExpand;
  final Map<String, dynamic>? retryStatus;

  @override
  Widget build(BuildContext context) {
    final compaction = entry.compaction!;
    if (compaction.status == 'running') {
      if (retryStatus?['error'] != null || retryStatus?['provider_delay'] == true) {
        return _ProviderRetryNotice(status: retryStatus!, contextLabel: 'Compacting context');
      }
      return _TurnClock(startedAt: compaction.startedAt,
        status: 'Compacting context${retryStatus == null ? '' : ' · ${retryStatus!['message']}'}');
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
      if (mounted && widget.startedAt != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = widget.startedAt == null ? null : _duration(widget.startedAt!, DateTime.now());
    final label = widget.status ?? 'Working';
    return Semantics(liveRegion: true, label: label, excludeSemantics: true,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.fromLTRB(4, 4, 2, 8),
        alignment: Alignment.centerLeft,
        child: Row(children: [
          Flexible(child: ThinkingLabel(label: label)),
          if (elapsed != null) Text(' · $elapsed', style: const TextStyle(fontSize: 14, height: 1.625,
            color: desktopSecondary, fontFeatures: [FontFeature.tabularFigures()])),
        ])));
  }
}

class _ProviderRetryNotice extends StatefulWidget {
  const _ProviderRetryNotice({super.key, required this.status, this.contextLabel});
  final Map<String, dynamic> status;
  final String? contextLabel;

  @override
  State<_ProviderRetryNotice> createState() => _ProviderRetryNoticeState();
}

class _ProviderRetryNoticeState extends State<_ProviderRetryNotice> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _watchDeadline();
  }

  @override
  void didUpdateWidget(_ProviderRetryNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status['next'] != widget.status['next']) _watchDeadline();
  }

  void _watchDeadline() {
    _timer?.cancel();
    final next = widget.status['next'] as int?;
    if (next == null || next <= DateTime.now().millisecondsSinceEpoch) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (DateTime.now().millisecondsSinceEpoch >= next) _timer?.cancel();
      setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.status;
    final error = status['error'] as Map?;
    final attempt = status['attempt'];
    final maximum = status['max_retries'];
    final progress = attempt == null ? '' : ' ($attempt${maximum == null ? '' : '/$maximum'})';
    final label = 'Retrying provider$progress';
    final next = status['next'] as int?;
    final remaining = next == null ? 0 : next - DateTime.now().millisecondsSinceEpoch;
    final waiting = remaining > 0;
    final detail = error?['message'] as String?;
    final code = error?['code'] as String?;
    final http = error?['http_status'];
    final diagnostics = [if (code != null) code, if (http != null) 'HTTP $http'].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: desktopMuted,
          border: Border.all(color: desktopBorder), borderRadius: BorderRadius.circular(8)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Semantics(liveRegion: true, child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(waiting ? Icons.schedule_outlined : Icons.refresh_rounded, size: 16, color: desktopSecondary),
            const SizedBox(width: 8),
            Expanded(child: Text('${widget.contextLabel == null ? '' : '${widget.contextLabel} · '}$label',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: desktopForeground))),
          ])),
          if (detail != null && detail.isNotEmpty) ...[
            const SizedBox(height: 8),
            SelectableText(detail, style: const TextStyle(fontSize: 13, height: 1.4, color: desktopSecondary)),
          ],
          if (diagnostics.isNotEmpty) ...[
            const SizedBox(height: 4),
            SelectableText(diagnostics, style: const TextStyle(fontSize: 12, color: desktopTertiary)),
          ],
          const SizedBox(height: 8),
          Text(waiting
            ? '${status['provider_delay'] == true ? 'Provider requested a wait. ' : ''}'
              'Retrying automatically in ${_durationSeconds((remaining + 999) ~/ 1000)}.'
            : 'Retrying now…',
            style: const TextStyle(fontSize: 12, color: desktopSecondary)),
        ]),
      ),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
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
  const _ToolRow({super.key, required this.tool, required this.directory, required this.onExpand});
  final ToolActivity tool;
  final String directory;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) => ConversationImageGroup(
    child: ConversationToolCall(tool: tool, directory: directory, onExpand: onExpand));
}
