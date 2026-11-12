import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:protocol/protocol.dart';

import 'appearance.dart';
import 'machine_icons.dart';
import 'pinned_sidebar_preferences.dart';
import 'project_avatar.dart';
import 'provider_icon.dart';
import 'rename_state.dart';
import 'session.dart';
import 'sidebar_activity.dart';
import 'sidebar_hover.dart';
import 'sidebar_icons.dart';
import 'thread_reorder_state.dart';
import 'window_chrome.dart';

typedef _SidebarThreadActivity = ({
  bool running, bool needsInput, bool failed, bool interrupted, bool completed, bool unread,
  int lastActivity, int sentAt, int? runStartedAt,
});

typedef _SidebarThread = (Project, DesktopTask, _SidebarThreadActivity);
typedef _PinnedGroup = ({String id, Project project, List<_SidebarThread> threads});

_SidebarThreadActivity _sidebarActivity(DesktopSession session, DesktopTask task) {
  var running = false, needsInput = false, failed = false, interrupted = false, completed = false, unread = false;
  var lastActivity = task.lastActivity, sentAt = 0;
  int? runStartedAt;
  for (final source in [task, ...session.sideChats.values.where((side) =>
      side.sideParentID == task.id && !side.archived && !side.archiving)]) {
    final working = source.running || source.sideSubmitting || source.sidePreparing && source.sideError == null;
    final status = source.turns.values.lastOrNull?['status'];
    running |= working;
    needsInput |= source.questions.isNotEmpty;
    failed |= source.loadError != null || source.sideError != null || status == 'failed';
    interrupted |= !working && (status == 'inProgress' || status == 'interrupted' ||
      source.projectionState['summary']?['time']?['busy'] != null && source.projectionState['summary']?['time']?['idle'] == null);
    completed |= session.hasUnseenCompletion(source);
    unread |= (source == task || source.lastActivity > 0) && source.lastActivity > (session.viewedTasks[source.id] ?? -1);
    if (source.lastActivity > lastActivity) lastActivity = source.lastActivity;
    if (working) {
      final sent = taskLastSentAt(source);
      if (sent > sentAt) sentAt = sent;
      final started = source.runStartedAt;
      if (started != null && (runStartedAt == null || started < runStartedAt)) runStartedAt = started;
    }
  }
  return (running: running, needsInput: needsInput, failed: failed, interrupted: interrupted,
    completed: completed, unread: unread, lastActivity: lastActivity, sentAt: sentAt, runStartedAt: runStartedAt);
}

DesktopSession _projectSource(Iterable<DesktopSession> sources, Project project) =>
  sources.firstWhere((source) => source.projects.contains(project));

Widget _machineBadge(DesktopSession source, MachineIcon Function(DesktopSession)? icon) => Tooltip(
  message: machineLabel(source), child: MachineGlyph(icon?.call(source) ?? parseMachineIcon(null, remote: source.machineAlias != null),
    size: 12, color: desktopTertiary));

List<(Project, DesktopTask, _SidebarThreadActivity)> _sidebarTasks(DesktopSession session, String? projectKey,
    {List<DesktopSession>? sources}) {
  final owners = sources ?? [session];
  final pins = {for (final (index, id) in session.sidebar.pinnedTaskIds.indexed) id: index};
  final keys = {for (final source in owners) for (final project in source.projects)
    for (final task in project.tasks) task: source.sidebarId(task.id)};
  final tasks = [
    for (final source in owners)
    for (final project in source.projects)
      if (!project.removing && (projectKey == null || projectIdentity(source, project) == projectKey))
        for (final task in project.tasks)
          if (!task.archived) (project, task, _sidebarActivity(source, task)),
  ];
  return tasks..sort((a, b) {
    final left = keys[a.$2]!, right = keys[b.$2]!;
    final pin = (pins[left] ?? double.infinity).compareTo(pins[right] ?? double.infinity);
    if (pin != 0) return pin;
    if (a.$3.running != b.$3.running) return a.$3.running ? -1 : 1;
    if (a.$3.running) {
      final sent = b.$3.sentAt.compareTo(a.$3.sentAt);
      return sent != 0 ? sent : left.compareTo(right);
    }
    final activity = b.$3.lastActivity.compareTo(a.$3.lastActivity);
    return activity != 0 ? activity : left.compareTo(right);
  });
}

List<SessionDraft> _sidebarDrafts(DesktopSession session, String? projectKey) =>
  session.sessionDrafts.where((draft) => draft.submission == null &&
    (projectKey == null || session.projects.any((project) => !project.removing &&
      project.checkoutKey == draft.checkoutKey && projectIdentity(session, project) == projectKey)) &&
    ((session.drafts[draft.id] ?? '').trim().isNotEmpty ||
      (session.fileDrafts[draft.id]?.isNotEmpty ?? false) ||
      (session.attachmentDrafts[draft.id]?.isNotEmpty ?? false))).toList().reversed.toList();

List<_PinnedGroup> _pinnedGroups(DesktopSession session, List<DesktopSession> sources, List<_SidebarThread> tasks) {
  final pins = session.sidebar.pinnedTaskIds.toSet();
  final pinned = tasks.where((entry) => pins.contains(_projectSource(sources, entry.$1).sidebarId(entry.$2.id)));
  if (session.pinnedSidebar.value.layout == PinnedThreadLayout.flat) {
    return [for (final entry in pinned)
      (id: _projectSource(sources, entry.$1).sidebarId(entry.$2.id), project: entry.$1, threads: [entry])];
  }
  final groups = <String, List<_SidebarThread>>{};
  for (final entry in pinned) {
    final id = projectIdentity(_projectSource(sources, entry.$1), entry.$1);
    (groups[id] ??= []).add(entry);
  }
  final projects = {for (final project in desktopProjects(sources, preferred: session)) project.id: project.preferred.project};
  return [for (final entry in groups.entries) (id: entry.key, project: projects[entry.key]!, threads: entry.value)];
}

List<String> sidebarThreadIds(DesktopSession session, {String? projectKey, List<DesktopSession>? sources}) {
  final owners = sources ?? [session], preferences = session.sidebar;
  final tasks = _sidebarTasks(session, projectKey, sources: owners);
  final pins = preferences.pinnedTaskIds.toSet();
  String key(Project project, DesktopTask task) => _projectSource(owners, project).sidebarId(task.id);
  return [
    if (!preferences.collapsedSidebarSections.contains('pinned'))
      for (final group in _pinnedGroups(session, owners, tasks))
        if (group.threads.length == 1 || !preferences.pinnedSidebar.value.collapsedProjects.contains(group.id))
          for (final (project, task, _) in group.threads) key(project, task),
    if (!preferences.collapsedSidebarSections.contains('working'))
      for (final (project, task, _) in tasks.where((entry) => entry.$3.running && !pins.contains(key(entry.$1, entry.$2)))) key(project, task),
    for (final source in owners)
      for (final draft in _sidebarDrafts(source, projectKey)) source.sidebarId(draft.id),
    for (final (project, task, _) in tasks.where((entry) => !entry.$3.running && !pins.contains(key(entry.$1, entry.$2)))) key(project, task),
  ];
}

class ThreadSidebar extends StatefulWidget {
  const ThreadSidebar({super.key, required this.session, required this.home, required this.windowControls,
    required this.onHome, required this.onSearch, required this.onNew, required this.onSettings,
    required this.onSelect, required this.onArchive, required this.onDraft,
    required this.onAddProject, required this.onRefresh, required this.onProjectFilter,
    this.onProjectSettings, this.projectKey, this.titlebarInset = 0, this.onBack, this.onForward, this.sources, this.machineIcon});
  final DesktopSession session;
  final List<DesktopSession>? sources;
  final MachineIcon Function(DesktopSession)? machineIcon;
  final bool home, windowControls;
  final double titlebarInset;
  final String? projectKey;
  final VoidCallback onHome, onSearch, onNew, onSettings, onAddProject, onRefresh;
  final VoidCallback? onBack, onForward;
  final ValueChanged<String?> onProjectFilter;
  final void Function(Project, DesktopTask) onSelect;
  final void Function(DesktopTask, bool) onArchive;
  final ValueChanged<SessionDraft> onDraft;
  final ValueChanged<Project>? onProjectSettings;

  @override
  State<ThreadSidebar> createState() => _ThreadSidebarState();
}

class _ThreadSidebarState extends State<ThreadSidebar> {
  DesktopSession get session => widget.session;
  DesktopSession get preferences => session.sidebar;
  List<DesktopSession> get sources => widget.sources ?? [session];
  DesktopSession _source(Project project) => _projectSource(sources, project);
  String _taskKey(Project project, DesktopTask task) => _source(project).sidebarId(task.id);
  Timer? _clock;
  late ThreadReorderState _reorder = const ThreadReorderIdle();
  CancellationToken? _reorderCancellation;
  late final _pinnedList = GlobalKey<SliverReorderableListState>();
  late final _projectLists = <String, GlobalKey<ReorderableListState>>{};
  late final _folderAnchors = <String, GlobalKey>{};
  VoidCallback? _cancelListReorder;
  String? _reorderProject;
  Map<String, List<String>>? _reorderMembers;
  PinnedThreadLayout? _reorderLayout;
  late final _threadList = GlobalKey();
  late final _rowAnchors = <String, GlobalKey>{};
  GlobalKey? _selectedRow;
  GlobalKey _anchor(String id) => _rowAnchors.putIfAbsent(id, () => GlobalKey());
  late final _scroll = ScrollController();
  late final _rows = <String, ({Object state, Widget row})>{};
  (String?, String?)? _selection;
  List<String>? _selectionPins;
  (PinnedSidebarPreferences, bool)? _selectionPinnedView;
  GlobalKey? _selectionList;
  int? _selectionIndex;
  int _revealRevision = 0;
  late final _reorderFocus = FocusNode(debugLabel: 'Pinned thread reorder');
  bool get _reordering => _reorder is ThreadReorderDragging || _reorder is ThreadReorderDropping;
  bool get _canStartReorder => switch (_reorder) {
    ThreadReorderIdle() || ThreadReorderSaved() || ThreadReorderFailed() || ThreadReorderCancelled() => !preferences.savingTaskPins,
    _ => false,
  };

  void _transitionReorder(ThreadReorderState next) =>
    _reorder = transitionThreadReorder(_reorder, next);

  void _startReorder(int index, List<String> order, {required VoidCallback cancel,
      String? project, Map<String, List<String>>? members}) {
    if (!_canStartReorder) {
      cancel();
      return;
    }
    _cancelListReorder = cancel;
    _reorderProject = project;
    _reorderMembers = members;
    _reorderLayout = preferences.pinnedSidebar.value.layout;
    _reorderCancellation = CancellationToken();
    setState(() => _transitionReorder(ThreadReorderDragging(index, order)));
    _reorderFocus.requestFocus();
  }

  void _endReorder(int insertionIndex) {
    if (_reorder case final ThreadReorderDragging drag) {
      final target = insertionIndex > drag.sourceIndex ? insertionIndex - 1 : insertionIndex;
      if (target == drag.sourceIndex) {
        setState(() => _transitionReorder(const ThreadReorderIdle()));
        _reorderCancellation?.cancel();
        _reorderCancellation = null;
      } else {
        setState(() => _transitionReorder(ThreadReorderDropping(drag, target)));
      }
    }
  }

  void _dropReorder(int oldIndex, int newIndex) {
    final drop = _reorder;
    if (drop is ThreadReorderCancelled) return;
    if (drop is! ThreadReorderDropping || drop.drag.sourceIndex != oldIndex || drop.targetIndex != newIndex) {
      throw StateError('Unexpected thread reorder drop');
    }
    final pending = ThreadReorderSaving(drop);
    final cancellation = _reorderCancellation!;
    setState(() => _transitionReorder(pending));
    unawaited(_persistReorder(pending, cancellation));
  }

  Future<void> _persistReorder(ThreadReorderSaving pending, CancellationToken cancellation) async {
    try {
      final members = _reorderMembers;
      final order = members == null ? pending.drop.order : [for (final id in pending.drop.order) ...members[id]!];
      await preferences.reorderPinnedTasks(order, cancellation: cancellation);
      if (!mounted || cancellation.isCancelled || !identical(_reorder, pending)) return;
      setState(() => _transitionReorder(ThreadReorderSaved(pending)));
    } catch (error) {
      if (!mounted || cancellation.isCancelled || !identical(_reorder, pending)) return;
      setState(() => _transitionReorder(ThreadReorderFailed(pending, error)));
      session.showError(error);
    } finally {
      if (identical(_reorderCancellation, cancellation)) _reorderCancellation = null;
    }
  }

  void _cancelReorder(ThreadReorderCancelReason reason) {
    if (_reorder is! ThreadReorderDragging && _reorder is! ThreadReorderDropping && _reorder is! ThreadReorderSaving) return;
    _transitionReorder(ThreadReorderCancelled(reason));
    _reorderCancellation?.cancel();
    _reorderCancellation = null;
    _cancelListReorder?.call();
    _cancelListReorder = null;
  }

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(minutes: 1), (_) => setState(_rows.clear));
  }

  @override
  void reassemble() {
    super.reassemble();
    _rows.clear();
  }

  @override
  void didUpdateWidget(covariant ThreadSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.projectKey != widget.projectKey || preferences.collapsedSidebarSections.contains('pinned')) {
      _cancelReorder(ThreadReorderCancelReason.changed);
      return;
    }
    _validateReorder(_pinnedGroups(session, sources, _sidebarTasks(session, widget.projectKey, sources: sources)));
  }

  void _validateReorder(List<_PinnedGroup> groups) {
    final order = switch (_reorder) {
      ThreadReorderDragging(:final order) => order,
      ThreadReorderDropping(:final drag) => drag.order,
      _ => null,
    };
    if (order != null) {
      final members = _reorderMembers;
      final current = members != null ? groups.map((group) => group.id).toList() : [
        for (final group in groups)
          if (_reorderProject == null || group.id == _reorderProject)
            for (final entry in group.threads) _taskKey(entry.$1, entry.$2),
      ];
      if (_reorderLayout != preferences.pinnedSidebar.value.layout ||
          preferences.collapsedSidebarSections.contains('pinned') ||
          _reorderProject != null && preferences.pinnedSidebar.value.collapsedProjects.contains(_reorderProject) ||
          !listEquals(order, current) || members != null && groups.any((group) =>
            !listEquals(members[group.id], group.threads.map((entry) => _taskKey(entry.$1, entry.$2)).toList()))) {
        _cancelReorder(ThreadReorderCancelReason.changed);
      }
    }
  }

  @override
  void dispose() {
    _cancelReorder(ThreadReorderCancelReason.disposed);
    _scroll.dispose();
    _reorderFocus.dispose();
    _clock?.cancel();
    super.dispose();
  }

  void _revealSelection(List<_PinnedGroup> pinned, List<(String?, Widget)> rows) {
    final id = widget.home ? null : session.sidebarId(session.draftKey);
    final selection = (id, widget.projectKey);
    final pin = preferences.collapsedSidebarSections.contains('pinned') ? -1 : pinned.indexWhere((group) =>
      group.threads.any((entry) => _taskKey(entry.$1, entry.$2) == id));
    final index = pin >= 0 ? pin : rows.indexWhere((entry) => entry.$1 == id);
    final list = pin >= 0 ? _pinnedList : _threadList;
    final folder = pin >= 0 && pinned[pin].threads.length > 1 &&
      preferences.pinnedSidebar.value.collapsedProjects.contains(pinned[pin].id);
    final anchor = folder ? _folderAnchors[pinned[pin].id] : id == null ? null : _anchor(id);
    final pinOrder = [for (final group in pinned) for (final entry in group.threads) _taskKey(entry.$1, entry.$2)];
    final view = (preferences.pinnedSidebar.value, preferences.collapsedSidebarSections.contains('pinned'));
    if (_selection == selection && _selectionList == list && _selectionIndex == index && identical(_selectedRow, anchor) &&
        listEquals(_selectionPins, pinOrder) && _selectionPinnedView == view) return;
    _selectionPins = pinOrder;
    _selectionPinnedView = view;
    _selectedRow = anchor;
    _selection = selection;
    _selectionList = list;
    _selectionIndex = index;
    final revision = ++_revealRevision;
    if (id == null || index < 0) return;
    final count = pin >= 0 ? pinned.length : rows.length;
    // Mounted cards already have usable bounds. Scroll before layout so held
    // navigation does not paint the new selection outside the viewport first.
    final target = _selectedRow?.currentContext?.findRenderObject();
    if (target is RenderBox && target.attached && target.hasSize) {
      _revealRow(revision, list, index, count);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealRow(revision, list, index, count));
  }

  void _revealRow(int revision, GlobalKey list, int index, int count, {double? lower, double? upper}) {
    if (!mounted || revision != _revealRevision || _reordering || !_scroll.hasClients) return;
    final position = _scroll.position;
    if (!position.hasContentDimensions) return;
    final target = _selectedRow?.currentContext?.findRenderObject();
    if (target != null && target.attached) {
      var viewport = RenderAbstractViewport.of(target);
      // Project children have their own shrink-wrapped viewport. Reveal their
      // bounds in the sidebar's scrolling viewport, including during reparenting.
      for (var ancestor = viewport.parent; ancestor != null; ancestor = ancestor.parent) {
        if (ancestor is RenderAbstractViewport) viewport = ancestor;
      }
      final top = viewport.getOffsetToReveal(target, 0).offset;
      final bottom = viewport.getOffsetToReveal(target, 1).offset;
      final offset = position.pixels > top ? top : position.pixels < bottom ? bottom : position.pixels;
      if ((offset - position.pixels).abs() > .5) {
        _scroll.jumpTo(offset.clamp(position.minScrollExtent, position.maxScrollExtent));
      }
      return;
    }
    // Lazy slivers have no element for a distant card. Seek using the mounted
    // rows, then reveal its actual bounds after layout; never mount the whole list.
    final sliver = list.currentContext?.findRenderObject();
    if (sliver is! RenderSliverMultiBoxAdaptor || sliver.geometry == null) return;
    final first = sliver.firstChild, last = sliver.lastChild;
    var extent = sliver.geometry!.scrollExtent / count;
    var offset = sliver.constraints.precedingScrollExtent + index * extent - position.viewportDimension / 2;
    if (first != null && last != null) {
      final firstIndex = sliver.indexOf(first), lastIndex = sliver.indexOf(last);
      final start = sliver.childScrollOffset(first)!;
      extent = (sliver.childScrollOffset(last)! + last.size.height - start) / (lastIndex - firstIndex + 1);
      offset = sliver.constraints.precedingScrollExtent + start + (index - firstIndex) * extent - position.viewportDimension / 2;
      if (index < firstIndex) upper = position.pixels;
      if (index > lastIndex) lower = position.pixels;
    }
    final min = lower ?? position.minScrollExtent, max = upper ?? position.maxScrollExtent;
    if (max - min <= .5) return;
    offset = offset.clamp(position.minScrollExtent, position.maxScrollExtent);
    if (offset < min || offset > max || (offset - position.pixels).abs() <= .5) offset = (min + max) / 2;
    _scroll.jumpTo(offset.clamp(position.minScrollExtent, position.maxScrollExtent));
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealRow(revision, list, index, count, lower: lower, upper: upper));
  }

  Widget _button(String tooltip, Widget icon, VoidCallback? onPressed) => IconButton(
    tooltip: tooltip, onPressed: onPressed,
    style: IconButton.styleFrom(minimumSize: const Size.square(28), maximumSize: const Size.square(28),
      padding: EdgeInsets.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      foregroundColor: onPressed == null ? const Color(0xffb5b5bd) : desktopSecondary,
      iconSize: 16, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
    icon: icon);

  Widget _dragBoundary(String label) => AnimatedSize(alignment: Alignment.topCenter,
    duration: const Duration(milliseconds: 150), child: !_reordering ? const SizedBox.shrink()
      : SizedBox(height: 24, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Row(children: [
      Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: desktopSecondary)),
      const SizedBox(width: 8),
      const Expanded(child: Divider(height: 1, color: desktopBorderStrong)),
    ]))));

  Widget _dragProxy(Widget child, int index, Animation<double> animation) =>
    AnimatedBuilder(animation: animation, child: child, builder: (context, child) => DecoratedBox(
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6),
          boxShadow: [BoxShadow(color: Color.fromRGBO(0, 0, 0, .12 * animation.value),
            blurRadius: 16 * animation.value, offset: Offset(0, 4 * animation.value))]),
        child: child));

  Widget _sectionHeading(String section, String title, int count) {
    final expanded = !preferences.collapsedSidebarSections.contains(section);
    return InkWell(key: ValueKey('$section-section'),
      mouseCursor: WidgetStateMouseCursor.clickable,
      onTap: () => unawaited(_run(preferences, () => preferences.chooseSidebarSection(section, expanded))),
      borderRadius: BorderRadius.circular(6), child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8), child: Row(children: [
          Expanded(child: Text(title, style: const TextStyle(fontSize: 12, color: desktopSecondary))),
          Text('$count', style: const TextStyle(fontSize: 12, color: desktopTertiary)),
          const SizedBox(width: 8),
          Icon(expanded ? Icons.keyboard_arrow_down_rounded : Icons.chevron_right_rounded, size: 14, color: desktopTertiary),
        ])));
  }

  Widget _projectGroup(_PinnedGroup group, int index, bool reorderable) {
    if (group.threads.length == 1) {
      final (project, task, activity) = group.threads.single;
      return _row(project, task, activity, reorderIndex: reorderable ? index : null);
    }
    final expanded = !preferences.pinnedSidebar.value.collapsedProjects.contains(group.id);
    final selected = !widget.home && group.threads.any((entry) =>
      identical(_source(entry.$1), session) && entry.$2 == session.task);
    final activities = group.threads.map((entry) => entry.$3).toList();
    final activity = (
      running: activities.any((activity) => activity.running),
      needsInput: activities.any((activity) => activity.needsInput),
      failed: activities.any((activity) => activity.failed),
      interrupted: activities.any((activity) => activity.interrupted),
      completed: activities.any((activity) => activity.completed),
      unread: activities.any((activity) => activity.unread),
      lastActivity: 0, sentAt: 0,
      runStartedAt: activities.map((activity) => activity.runStartedAt).whereType<int>().fold<int?>(null,
        (earliest, started) => earliest == null || started < earliest ? started : earliest),
    );
    final anchor = _folderAnchors.putIfAbsent(group.id, () => GlobalKey());
    final list = _projectLists.putIfAbsent(group.id, () => GlobalKey<ReorderableListState>());
    final heading = KeyedSubtree(key: anchor, child: Semantics(
      button: true, expanded: expanded, selected: selected && !expanded,
      child: Tooltip(message: '${expanded ? 'Collapse' : 'Expand'} ${group.project.name}', child: Material(
        color: selected && !expanded ? Colors.white : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(key: ValueKey('pinned-project:${group.id}'), borderRadius: BorderRadius.circular(6),
          onTap: !preferences.pinnedSidebar.enabled || _reordering ? null : () =>
            unawaited(_run(preferences, () => preferences.pinnedSidebar.chooseCollapsed(group.id, expanded))),
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8), child: Row(children: [
            Icon(expanded ? Icons.keyboard_arrow_down_rounded : Icons.chevron_right_rounded,
              size: 16, color: desktopTertiary),
            const SizedBox(width: 6),
            ProjectAvatar(project: group.project, size: 16, generated: session.projectAvatarStyle == 'generated'),
            const SizedBox(width: 8),
            Expanded(child: Text(group.project.name, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: selected || activity.unread ? desktopForeground : desktopSecondary,
                fontWeight: selected || activity.unread ? FontWeight.w600 : FontWeight.w500))),
            _ThreadStatus(activity: activity),
            const SizedBox(width: 8),
            Text('${group.threads.length}', style: const TextStyle(fontSize: 12, color: desktopTertiary)),
          ])))))));
    return Column(key: ValueKey('pinned-group:${group.id}'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ReorderableDragStartListener(index: index, enabled: reorderable && _canStartReorder, child: heading),
      if (expanded) Container(margin: const EdgeInsets.only(left: 15, bottom: 4), padding: const EdgeInsets.only(left: 9),
        decoration: const BoxDecoration(border: Border(left: BorderSide(color: desktopBorder))),
        child: DragBoundary(child: ReorderableList(key: list, itemCount: group.threads.length,
          shrinkWrap: true, primary: false, physics: const NeverScrollableScrollPhysics(), padding: EdgeInsets.zero,
          onReorderStart: (index) => _startReorder(index,
            group.threads.map((entry) => _taskKey(entry.$1, entry.$2)).toList(),
            project: group.id, cancel: () => list.currentState?.cancelReorder()),
          onReorderEnd: _endReorder, onReorderItem: _dropReorder, proxyDecorator: _dragProxy,
          itemBuilder: (context, index) {
            final (project, task, activity) = group.threads[index];
            return _row(project, task, activity, grouped: true, reorderIndex: index);
          }))),
    ]);
  }

  Widget _row(Project project, DesktopTask task, _SidebarThreadActivity activity, {int? reorderIndex, bool grouped = false}) {
    final source = _source(project), session = _source(project);
    final id = source.sidebarId(task.id), active = identical(widget.session, source);
    final state = (
      source, project, task, widget.home, active && session.task == task,
      project.id, project.name, project.branch, project.iconState.value.revision, session.projectAvatarStyle,
      task.title, task.archived, task.archiving, task.provider, task.model, activity,
      session.pinnedTaskIds.contains(task.id), session.connected, session.savingTaskPins,
      _canStartReorder, reorderIndex, grouped, widget.onProjectSettings != null,
      sources.length, machineLabel(source), widget.machineIcon?.call(source),
    );
    final cached = _rows[id];
    if (cached?.state == state) return cached!.row;
    final row = _ThreadRow(
    key: ValueKey('thread-row:$id'), session: session, task: task,
    onArchive: (task, archived) => widget.onArchive(task, archived),
    onProjectSettings: widget.onProjectSettings == null ? null : () => widget.onProjectSettings!(project),
    builder: (renameInput, renameTitle) => SidebarHover(builder: (context, hovering) {
      final selected = !widget.home && active && session.task == task;
      final pinned = session.pinnedTaskIds.contains(task.id);
      final unread = activity.unread;
      final reorderable = reorderIndex != null && renameInput == null && !task.archiving && _canStartReorder;
      final card = Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Material(
        color: selected ? Colors.white : Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: selected ? desktopBorder : Colors.transparent)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(key: ValueKey('thread:$id'), borderRadius: BorderRadius.circular(6),
          mouseCursor: WidgetStateMouseCursor.clickable,
          hoverColor: desktopMuted,
          onTap: renameInput == null ? () => widget.onSelect(project, task) : null,
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (!grouped) ...[
              SizedBox(height: 20, child: Row(children: [
                ProjectAvatar(project: project, size: 16, generated: session.projectAvatarStyle == 'generated'),
                const SizedBox(width: 6),
                Visibility(visible: pinned || hovering, maintainSize: true, maintainAnimation: true, maintainState: true,
                  child: _pinButton(session, task, compact: true)),
                const SizedBox(width: 6),
                Expanded(child: Text(project.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: desktopSecondary))),
                if (!hovering)
                  _ThreadStatus(activity: activity, showLabel: true),
                IgnorePointer(ignoring: !hovering, child: Align(alignment: Alignment.centerRight,
                  widthFactor: hovering ? 1 : 0, child: Opacity(opacity: hovering ? 1 : 0,
                    alwaysIncludeSemantics: true,
                    child: _archiveButton(session, task, () => widget.onArchive(task, true))))),
              ])),
              const SizedBox(height: 4),
              ],
              SizedBox(height: renameInput == null ? 20 : 26, child: Row(children: [
              Expanded(child: renameInput ?? GestureDetector(onDoubleTap: renameTitle,
                child: Tooltip(message: task.title, child: Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14, height: 20 / 14,
                  fontWeight: selected || unread ? FontWeight.w500 : FontWeight.w400,
                  color: selected || unread ? desktopForeground : desktopSecondary))))),
              if (grouped) ...[
                const SizedBox(width: 6),
                if (!hovering) _ThreadStatus(activity: activity),
                if (hovering) ...[
                  _pinButton(session, task, compact: true),
                  _archiveButton(session, task, () => widget.onArchive(task, true)),
                ],
              ],
              ])),
              const SizedBox(height: 2),
              SizedBox(height: 16, child: Row(children: [
                _machineBadge(source, widget.machineIcon), const SizedBox(width: 6),
                Expanded(child: Text.rich(TextSpan(children: [
                  if (project.branch case final branch?) TextSpan(text: branch),
                ]), maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, height: 1, color: desktopSecondary))),
                if (task.provider != null) ...[
                  const SizedBox(width: 8),
                  Tooltip(message: '${task.provider}${task.model == null ? '' : ' · ${task.model}'}',
                    child: SizedBox.square(dimension: 14, child: providerIcon(task.provider, size: 14, color: desktopTertiary))),
                ],
              ])),
            ])))));
      final anchored = KeyedSubtree(key: _anchor(id), child: card);
      return reorderIndex == null ? anchored : ReorderableDragStartListener(
        index: reorderIndex, enabled: reorderable, child: anchored);
    }));
    _rows[id] = (state: state, row: row);
    return row;
  }

  Widget _draft(DesktopSession session, SessionDraft draft) {
    final project = session.projects.where((project) => project.checkoutKey == draft.checkoutKey).firstOrNull;
    var text = session.drafts[draft.id] ?? '';
    for (final file in (session.fileDrafts[draft.id] ?? []).reversed) {
      if (file.offset < 0 || file.offset >= text.length || text[file.offset] != '\uFFFC') continue;
      text = text.replaceRange(file.offset, file.offset + 1, '${file.skillName == null ? '@' : r'$'}${file.label}');
    }
    text = text.trim().split('\n').first;
    final count = (session.fileDrafts[draft.id]?.length ?? 0) + (session.attachmentDrafts[draft.id]?.length ?? 0);
    final selected = !widget.home && identical(widget.session, session) && session.task == null && session.currentDraft == draft;
    final id = session.sidebarId(draft.id);
    return Material(key: ValueKey('draft:$id'), color: selected ? const Color(0xffeeeef0) : Colors.transparent,
      borderRadius: BorderRadius.circular(8), child: InkWell(
        mouseCursor: WidgetStateMouseCursor.clickable,
        borderRadius: BorderRadius.circular(8), onTap: () => widget.onDraft(draft),
        child: KeyedSubtree(key: _anchor(id), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              if (project != null) ...[
                ProjectAvatar(project: project, size: 14, generated: session.projectAvatarStyle == 'generated'),
                const SizedBox(width: 6),
              ],
              Expanded(child: Text(project?.name ?? 'Draft', maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: desktopTertiary))),
              Padding(padding: const EdgeInsets.only(right: 6), child: _machineBadge(session, widget.machineIcon)),
              const Icon(Icons.edit_outlined, size: 13, color: desktopTertiary),
              const SizedBox(width: 4),
              const Text('Draft', style: TextStyle(fontSize: 11, color: desktopTertiary)),
            ]),
            const SizedBox(height: 4),
            Text(text.isEmpty ? '$count attachment${count == 1 ? '' : 's'}' : text,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, height: 20 / 14)),
          ])))));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: Listenable.merge([
    preferences, preferences.pinnedSidebar, for (final source in sources) ...[source, source.sidebarChanges],
  ]),
    builder: (context, _) => _buildSidebar(context));

  Widget _buildSidebar(BuildContext context) {
    final tasks = _sidebarTasks(session, widget.projectKey, sources: sources);
    final ids = tasks.map((entry) => _taskKey(entry.$1, entry.$2)).toSet();
    _rows.removeWhere((id, _) => !ids.contains(id));
    final pins = preferences.pinnedTaskIds.toSet();
    final pinned = _pinnedGroups(session, sources, tasks);
    _validateReorder(pinned);
    final projectIds = pinned.where((group) => group.threads.length > 1).map((group) => group.id).toSet();
    _folderAnchors.removeWhere((id, _) => !projectIds.contains(id));
    _projectLists.removeWhere((id, _) => !projectIds.contains(id));
    for (final id in projectIds) { _folderAnchors.putIfAbsent(id, () => GlobalKey()); }
    final working = tasks.where((entry) => entry.$3.running && !pins.contains(_taskKey(entry.$1, entry.$2))).toList();
    final drafts = [for (final source in sources)
      for (final draft in _sidebarDrafts(source, widget.projectKey)) (source, draft)];
    final anchoredIds = {...ids, ...drafts.map((entry) => entry.$1.sidebarId(entry.$2.id))};
    _rowAnchors.removeWhere((id, _) => !anchoredIds.contains(id));
    final rows = <(String?, Widget)>[
      if (working.isNotEmpty) ...[
        (null, _sectionHeading('working', 'Working', working.length)),
        if (!preferences.collapsedSidebarSections.contains('working'))
          for (final (project, task, activity) in working) (_taskKey(project, task), _row(project, task, activity)),
        (null, const Padding(padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8), child: Divider(height: 1))),
      ],
      for (final (source, draft) in drafts) (source.sidebarId(draft.id), _draft(source, draft)),
      for (final (project, task, activity) in tasks.where((entry) => !entry.$3.running && !pins.contains(_taskKey(entry.$1, entry.$2))))
        (_taskKey(project, task), _row(project, task, activity)),
      (null, const SizedBox(height: 12)),
    ];
    _revealSelection(pinned, rows);
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    return Material(color: desktopSidebar, child: DecoratedBox(
      decoration: const BoxDecoration(border: Border(right: BorderSide(color: desktopBorder))),
      child: Column(children: [
        DesktopWindowDragRegion(child: SizedBox(height: 56, child: Padding(
          padding: EdgeInsets.only(left: widget.windowControls ? widget.titlebarInset + 40 : 48, right: 12),
          child: Row(children: [
            Flexible(child: TextButton(onPressed: widget.onHome,
              style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4),
                minimumSize: const Size(0, 28), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              child: const Text('Happen', maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: -.4)))),
            const SizedBox(width: 6),
            _button('Go back', const Icon(Icons.arrow_back_rounded), widget.onBack),
            _button('Go forward', const Icon(Icons.arrow_forward_rounded), widget.onForward),
          ])))),
        Padding(padding: const EdgeInsets.fromLTRB(12, 4, 12, 12), child: SizedBox(height: 32, child: Row(children: [
          Expanded(child: TextButton.icon(onPressed: widget.onSearch,
            style: TextButton.styleFrom(alignment: Alignment.centerLeft,
              foregroundColor: desktopSecondary, padding: const EdgeInsets.symmetric(horizontal: 6)),
            icon: sidebarIcon(SidebarIcon.search),
            label: const Text('Search', style: TextStyle(fontSize: 14)))),
          PopupMenuButton<String>(tooltip: 'Filter by project',
            onSelected: (key) => widget.onProjectFilter(key == '*' ? null : key),
            itemBuilder: (_) => [
              CheckedPopupMenuItem(value: '*', checked: widget.projectKey == null, child: const Text('All projects')),
              const PopupMenuDivider(),
              for (final project in desktopProjects(sources, preferred: session))
                CheckedPopupMenuItem(value: project.id, checked: widget.projectKey == project.id,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    ProjectAvatar(project: project.preferred.project, size: 14,
                      generated: session.projectAvatarStyle == 'generated'),
                    const SizedBox(width: 8), Text(project.preferred.project.name)])),
            ],
            child: MouseRegion(cursor: SystemMouseCursors.click, child: SizedBox.square(dimension: 28,
              child: Center(child: sidebarIcon(SidebarIcon.listFilter))))),
          _button('Open project', sidebarIcon(SidebarIcon.folderPlus), widget.onAddProject),
          _button('New thread (${mac ? '⌘N' : 'Ctrl+N'})', sidebarIcon(SidebarIcon.squarePen), widget.onNew),
        ]))),
        Expanded(child: Focus(focusNode: _reorderFocus, onKeyEvent: (_, event) {
          if (_reordering && event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
            setState(() => _cancelReorder(ThreadReorderCancelReason.escape));
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        }, child: Listener(onPointerCancel: (_) {
          if (_reordering) setState(() => _cancelReorder(ThreadReorderCancelReason.pointerCancelled));
        }, child: DragBoundary(child: CustomScrollView(key: const PageStorageKey('thread-sidebar'), controller: _scroll, slivers: [
          SliverPadding(padding: const EdgeInsets.symmetric(horizontal: 8), sliver: SliverMainAxisGroup(slivers: [
            if (pinned.isNotEmpty) ...[
              SliverToBoxAdapter(child: _sectionHeading('pinned', 'Pinned', pinned.fold(0, (count, group) => count + group.threads.length))),
              if (!preferences.collapsedSidebarSections.contains('pinned')) ...[
                SliverReorderableList(key: _pinnedList, itemCount: pinned.length,
                  onReorderStart: (index) => _startReorder(index, pinned.map((group) => group.id).toList(),
                    cancel: () => _pinnedList.currentState?.cancelReorder(),
                    members: {for (final group in pinned)
                      group.id: group.threads.map((entry) => _taskKey(entry.$1, entry.$2)).toList()}),
                  onReorderEnd: _endReorder,
                  onReorderItem: _dropReorder,
                  proxyDecorator: _dragProxy,
                  itemBuilder: (context, index) {
                    return _projectGroup(pinned[index], index, pinned.length > 1);
                  }),
                SliverToBoxAdapter(child: _dragBoundary('Threads')),
              ],
            ],
            SliverList.list(key: _threadList, children: [for (final row in rows) row.$2]),
          ])),
        ]))))),
        Padding(padding: const EdgeInsets.fromLTRB(12, 4, 12, 12), child: Row(children: [
          _button('App settings', const Icon(Icons.settings_outlined), widget.onSettings),
          const SizedBox(width: 4),
          _button('All sessions', const Icon(Icons.grid_view_outlined), widget.onHome),
          const Spacer(),
          if (!session.connected) const Padding(padding: EdgeInsets.only(right: 8),
            child: Text('Disconnected', style: TextStyle(fontSize: 11, color: desktopTertiary))),
          _button('Refresh threads', const Icon(Icons.sync_rounded), session.connected ? widget.onRefresh : null),
        ])),
      ])));
  }
}

class WorkspaceHome extends StatefulWidget {
  const WorkspaceHome({super.key, required this.session, required this.focusNode, required this.onSelect,
    required this.onNew, required this.onAddProject, required this.onArchive, this.onProjectSettings, this.sources, this.machineIcon});
  final DesktopSession session;
  final List<DesktopSession>? sources;
  final MachineIcon Function(DesktopSession)? machineIcon;
  final FocusNode focusNode;
  final void Function(Project, DesktopTask) onSelect;
  final ValueChanged<Project> onNew;
  final VoidCallback onAddProject;
  final void Function(DesktopTask, bool) onArchive;
  final ValueChanged<Project>? onProjectSettings;
  @override
  State<WorkspaceHome> createState() => _WorkspaceHomeState();
}

class _WorkspaceHomeState extends State<WorkspaceHome> {
  final _search = TextEditingController();
  @override
  void dispose() { _search.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final sources = widget.sources ?? [widget.session];
    final pins = {for (final (index, id) in widget.session.sidebar.pinnedTaskIds.indexed) id: index};
    String key(Project project, DesktopTask task) => _projectSource(sources, project).sidebarId(task.id);
    final entries = [for (final source in sources)
      for (final project in source.projects.where((project) => !project.removing))
      for (final task in project.tasks)
        if (!task.archived && '${task.title} ${project.name} ${project.path}'.toLowerCase().contains(query)) (project, task)]
      ..sort((a, b) {
        final pin = (pins[key(a.$1, a.$2)] ?? double.infinity).compareTo(pins[key(b.$1, b.$2)] ?? double.infinity);
        return pin != 0 ? pin : b.$2.lastActivity.compareTo(a.$2.lastActivity);
      });
    return Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 800),
      child: Padding(padding: const EdgeInsets.fromLTRB(32, 48, 32, 24), child: Column(children: [
        Row(children: [
          const Expanded(child: Text('Threads', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w500))),
          IconButton(tooltip: 'Open project', onPressed: widget.onAddProject, icon: sidebarIcon(SidebarIcon.folderPlus, size: 18)),
        ]),
        const SizedBox(height: 20),
        TextField(key: const ValueKey('session-search'), controller: _search, focusNode: widget.focusNode,
          onChanged: (_) => setState(() {}), decoration: const InputDecoration(hintText: 'Search sessions', prefixIcon: Icon(Icons.search, size: 17))),
        const SizedBox(height: 16),
        Expanded(child: ListView.builder(itemCount: entries.length, itemBuilder: (context, index) {
          final (project, task) = entries[index];
          final source = _projectSource(sources, project), id = key(project, task);
          return _ThreadRow(key: ValueKey('home-row:$id'),
            session: source, task: task, onArchive: widget.onArchive,
            onProjectSettings: widget.onProjectSettings == null ? null : () => widget.onProjectSettings!(project),
            builder: (renameInput, renameTitle) => SidebarHover(builder: (context, hovering) => ListTile(
              key: ValueKey('home:$id'), leading: Row(mainAxisSize: MainAxisSize.min, children: [
                ProjectAvatar(project: project),
                const SizedBox(width: 6),
                Visibility(visible: hovering || pins.containsKey(id),
                  maintainSize: true, maintainAnimation: true, maintainState: true,
                  child: _pinButton(source, task)),
              ]),
              title: renameInput ?? GestureDetector(onDoubleTap: renameTitle,
                child: Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
              subtitle: Row(children: [_machineBadge(source, widget.machineIcon), const SizedBox(width: 6),
                Flexible(child: Text(project.name, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: desktopTertiary)))]),
              trailing: _ThreadStatus(activity: _sidebarActivity(source, task)),
              onTap: renameInput == null ? () => widget.onSelect(project, task) : null)));
        })),
      ]))));
  }
}

class _ThreadRow extends StatefulWidget {
  const _ThreadRow({super.key, required this.session, required this.task, required this.onArchive,
    required this.builder, this.onProjectSettings});
  final DesktopSession session;
  final DesktopTask task;
  final void Function(DesktopTask, bool) onArchive;
  final Widget Function(Widget? renameInput, VoidCallback? renameTitle) builder;
  final VoidCallback? onProjectSettings;
  @override
  State<_ThreadRow> createState() => _ThreadRowState();
}

class _ThreadRowState extends State<_ThreadRow> {
  final _title = TextEditingController();
  final _renameFocus = FocusNode(debugLabel: 'Thread title');
  final _rowFocus = FocusNode(debugLabel: 'Thread row');
  final _renameLifetime = CancellationToken();
  RenameState _rename = const RenameIdle();
  bool get _renaming => _rename is RenameEditing;
  bool get _canRename => widget.session.connected && !widget.task.archiving && widget.task.sideParentID == null &&
    switch (_rename) {
      RenameIdle() || RenameFailed() => true,
      RenameEditing() || RenameSaving() => false,
    };

  void _transitionRename(RenameState next) => setState(() => _rename = transitionRename(_rename, next));

  @override
  void initState() {
    super.initState();
    _renameFocus.addListener(_onRenameFocus);
  }

  @override
  void dispose() {
    _renameLifetime.cancel();
    _renameFocus.removeListener(_onRenameFocus);
    _renameFocus.dispose();
    _rowFocus.dispose();
    _title.dispose();
    super.dispose();
  }

  void _startRename() {
    if (!_canRename) return;
    final title = switch (_rename) { RenameFailed(:final title) => title, _ => widget.task.title };
    _title.value = TextEditingValue(text: title,
      selection: TextSelection(baseOffset: 0, extentOffset: title.length));
    _transitionRename(const RenameEditing());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_renaming) return;
      _renameFocus.requestFocus();
      _title.selection = TextSelection(baseOffset: 0, extentOffset: _title.text.length);
    });
  }

  void _onRenameFocus() {
    if (!_renameFocus.hasFocus) _finishRename(cancel: true);
  }

  void _finishRename({bool cancel = false, bool restoreFocus = false}) {
    if (!mounted || !_renaming) return;
    // Settle before removing the input: Enter/Escape must not commit again on blur.
    final next = cancel ? const RenameIdle() : RenameSaving(_title.text);
    _transitionRename(next);
    if (restoreFocus) _rowFocus.requestFocus();
    if (next is RenameSaving) unawaited(_saveRename(next));
  }

  Future<void> _saveRename(RenameSaving saving) async {
    final session = widget.session;
    try {
      await session.renameTask(widget.task, saving.title, cancellation: _renameLifetime);
    } on CancelledException {
      if (mounted && identical(_rename, saving)) _transitionRename(const RenameIdle());
      return;
    } catch (failure) {
      if (mounted && identical(_rename, saving)) _transitionRename(RenameFailed(saving.title, failure));
      session.showError(failure, title: 'Failed to rename thread');
      return;
    }
    if (mounted && identical(_rename, saving)) _transitionRename(const RenameIdle());
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (_renaming) {
      if (event.logicalKey != LogicalKeyboardKey.escape || !_title.value.composing.isCollapsed) return KeyEventResult.ignored;
      _finishRename(cancel: true, restoreFocus: true);
    } else {
      if (event.logicalKey != LogicalKeyboardKey.f2 || !_canRename) return KeyEventResult.ignored;
      _startRename();
    }
    return KeyEventResult.handled;
  }

  Future<void> _showMenu(TapDownDetails details) async {
    final session = widget.session, task = widget.task;
    final pinned = session.pinnedTaskIds.contains(task.id), overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    PopupMenuItem<String> item(String value, String label, IconData icon, {required bool enabled, String? shortcut}) =>
      PopupMenuItem(value: value, enabled: enabled, height: 32, padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(children: [
          Icon(icon, size: 15, color: enabled ? desktopSecondary : desktopBorder),
          const SizedBox(width: 8),
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
          if (shortcut != null) ...[
            const SizedBox(width: 16),
            Text(shortcut, style: const TextStyle(fontSize: 11, color: desktopSecondary)),
          ],
        ]));
    final action = await showMenu<String>(context: context,
      constraints: const BoxConstraints(minWidth: 208, maxWidth: 240), menuPadding: const EdgeInsets.all(4),
      color: Colors.white, surfaceTintColor: Colors.transparent, elevation: 6, shadowColor: const Color(0x24000000),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: desktopBorder)),
      position: RelativeRect.fromRect(details.globalPosition & Size.zero, Offset.zero & overlay.size), items: [
        item('pin', pinned ? 'Unpin session' : 'Pin session', pinned ? Icons.push_pin : Icons.push_pin_outlined, enabled: !task.archiving),
        item('rename', 'Rename thread', Icons.edit_outlined, enabled: _canRename, shortcut: 'F2'),
        if (widget.onProjectSettings != null) ...[
          const PopupMenuDivider(height: 8),
          item('project-settings', 'Project settings', Icons.settings_outlined, enabled: true),
        ],
        const PopupMenuDivider(height: 8),
        item('archive', task.archived ? 'Restore session' : 'Archive session',
          task.archived ? Icons.unarchive_outlined : Icons.archive_outlined, enabled: session.connected && !task.archiving),
      ]);
    if (!mounted) return;
    if (action == 'pin') await _run(session, () => session.pinTask(task, !pinned));
    if (action == 'rename') _startRename();
    if (action == 'project-settings') widget.onProjectSettings?.call();
    if (action == 'archive') widget.onArchive(task, !task.archived);
  }

  @override
  Widget build(BuildContext context) {
    final renameInput = _renaming ? SizedBox(height: 26, child: Semantics(label: 'Thread title',
      child: TextField(
        key: ValueKey('thread-title:${widget.task.id}'), controller: _title, focusNode: _renameFocus, autofocus: true,
        selectAllOnFocus: true, cursorWidth: 1.5,
        style: const TextStyle(fontSize: 14, height: 20 / 14, fontWeight: FontWeight.w500, color: desktopForeground),
        textAlignVertical: TextAlignVertical.center, textInputAction: TextInputAction.done,
        decoration: InputDecoration(isDense: true, filled: true, fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(5), borderSide: const BorderSide(color: desktopBorder)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(5),
            borderSide: BorderSide(color: DesktopAccent.of(context).reference))),
        onEditingComplete: () {},
        onSubmitted: (_) => _finishRename(restoreFocus: true),
        onTapOutside: (_) => _renameFocus.unfocus(),
    ))) : null;
    return Focus(focusNode: _rowFocus, onKeyEvent: _onKeyEvent, child: GestureDetector(
      key: ValueKey('thread-menu:${widget.task.id}'), onSecondaryTapDown: _showMenu,
      child: widget.builder(renameInput, _canRename ? () {
        final keyboard = HardwareKeyboard.instance;
        if (!keyboard.isControlPressed && !keyboard.isMetaPressed && !keyboard.isAltPressed && !keyboard.isShiftPressed) _startRename();
      } : null)));
  }
}

Widget _archiveButton(DesktopSession session, DesktopTask task, VoidCallback onPressed) =>
  SizedBox(height: 20, child: Tooltip(message: 'Archive thread', child: TextButton(
    key: ValueKey('archive:${task.id}'),
    onPressed: session.connected && !task.archiving ? onPressed : null,
    style: ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size.zero),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 6)),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
      textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 12, height: 16 / 12,
        fontWeight: FontWeight.w400, letterSpacing: 0)),
      foregroundColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.disabled)
        ? const Color(0xffb5b5bd)
        : states.contains(WidgetState.hovered) || states.contains(WidgetState.focused) || states.contains(WidgetState.pressed)
          ? desktopForeground : desktopSecondary),
      overlayColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.focused)
        ? desktopHover : Colors.transparent),
      animationDuration: const Duration(milliseconds: 100),
    ),
    child: Builder(builder: (context) => Row(mainAxisSize: MainAxisSize.min, children: [
      sidebarIcon(SidebarIcon.check, size: 14, color: DefaultTextStyle.of(context).style.color!),
      const SizedBox(width: 4),
      const Text('Archive'),
    ])),
  )));

Widget _pinButton(DesktopSession session, DesktopTask task, {bool compact = false}) {
  final pinned = session.pinnedTaskIds.contains(task.id);
  return SidebarHover(builder: (context, hovering) => SizedBox.square(dimension: compact ? 12 : 20,
    child: IconButton(key: ValueKey('pin:${task.id}'),
    tooltip: pinned ? 'Unpin session' : 'Pin session', padding: EdgeInsets.zero,
    constraints: const BoxConstraints(),
    style: IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
    onPressed: task.archiving || session.savingTaskPins ? null : () => unawaited(_run(session, () => session.pinTask(task, !pinned))),
    icon: sidebarIcon(pinned && hovering ? SidebarIcon.pinOff : SidebarIcon.pin,
      size: compact ? 12 : 13, color: desktopTertiary))));
}

class _ThreadStatus extends StatelessWidget {
  const _ThreadStatus({required this.activity, this.showLabel = false});
  final _SidebarThreadActivity activity;
  final bool showLabel;
  @override
  Widget build(BuildContext context) {
    final (label, icon, color) = activity.needsInput ? ('Input', Icons.question_answer_outlined, const Color(0xff4f46e5))
      : activity.running ? ('Working', null, const Color(0xff5876ff))
      : activity.failed ? ('Failed', Icons.error_outline, const Color(0xffc44848))
      : activity.interrupted ? ('Interrupted', Icons.pause_circle_outline, const Color(0xffb67a2a))
      : activity.completed ? ('Done', Icons.check_circle_outline, const Color(0xff059669))
      : ('Idle', Icons.circle_outlined, desktopTertiary);
    final started = activity.runStartedAt;
    final elapsed = started == null ? null : DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(started));
    final duration = elapsed == null ? '' : elapsed.inHours > 0 ? '${elapsed.inHours}h ${elapsed.inMinutes % 60}m'
      : elapsed.inMinutes > 0 ? '${elapsed.inMinutes}m' : '<1m';
    final age = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(activity.lastActivity));
    final time = activity.lastActivity <= 0 ? '' : age.inDays > 0 ? '${age.inDays}d'
      : age.inHours > 0 ? '${age.inHours}h' : age.inMinutes > 0 ? '${age.inMinutes}m' : 'now';
    return Tooltip(message: label, child: Semantics(label: label, child: Row(mainAxisSize: MainAxisSize.min, children: [
      if (!showLabel || label != 'Idle') SizedBox.square(dimension: 14,
        child: icon == null ? SidebarActivityIndicator(color: color) : Icon(icon, size: 13, color: color)),
      if (showLabel) ...[
        const SizedBox(width: 4),
        Text(label == 'Idle' ? time : activity.running && !activity.needsInput && duration.isNotEmpty ? duration : label,
          style: TextStyle(fontSize: 12, color: color, fontFeatures: const [FontFeature.tabularFigures()])),
      ],
    ])));
  }
}

Future<void> _run(DesktopSession session, Future<void> Function() action) async {
  try { await action(); } catch (error) { session.showError(error); }
}
