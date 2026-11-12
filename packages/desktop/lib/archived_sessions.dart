import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:protocol/protocol.dart';

import 'appearance.dart';
import 'conversation.dart';
import 'conversation_data.dart';
import 'session.dart';

class ArchivedSessions extends StatefulWidget {
  const ArchivedSessions({super.key, required this.session, required this.run});
  final DesktopSession session;
  final Future<void> Function(Future<void> Function()) run;

  @override
  State<ArchivedSessions> createState() => _ArchivedSessionsState();
}

class _ArchivedSessionsState extends State<ArchivedSessions> {
  final _scroll = ScrollController();
  final _search = TextEditingController();
  var _read = CancellationToken();
  (Project, DesktopTask)? _preview;

  @override
  void dispose() {
    _read.cancel();
    if (_preview case final preview?) widget.session.releaseHistory(preview.$2);
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  void _back() {
    _read.cancel();
    if (_preview case final preview?) widget.session.releaseHistory(preview.$2);
    _read = CancellationToken();
    setState(() => _preview = null);
  }

  void _open(Project project, DesktopTask task) {
    _read.cancel();
    if (_preview case final preview? when preview.$2 != task) widget.session.releaseHistory(preview.$2);
    _read = CancellationToken();
    setState(() => _preview = (project, task));
    if (!task.loaded) _load(task);
  }

  void _load(DesktopTask task) => unawaited(widget.run(
    () => widget.session.loadHistory(task, cancellation: _read)));

  Future<void> _restore(DesktopTask task) => widget.run(() async {
    if (_preview?.$2 == task) {
      _read.cancel();
      _read = CancellationToken();
    }
    await widget.session.setArchived(task, false);
    if (mounted && !task.archived && _preview?.$2 == task) _back();
  });

  Widget _restoreButton(DesktopTask task) => TextButton(
    onPressed: widget.session.connected && !task.archiving ? () => _restore(task) : null,
    child: Text(task.archiving ? 'Restoring…' : 'Restore'),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) {
      final all = [
        for (final project in widget.session.projects)
          if (!project.removing)
            for (final task in project.tasks)
              if (task.archived) (project, task),
      ];
      final query = _search.text.trim().toLowerCase();
      final archived = [
        for (final entry in all)
          if ('${entry.$2.title} ${entry.$1.name} ${entry.$1.path}'.toLowerCase().contains(query)) entry,
      ]..sort((a, b) {
        final time = (b.$2.archivedAt?.microsecondsSinceEpoch ?? 0)
          .compareTo(a.$2.archivedAt?.microsecondsSinceEpoch ?? 0);
        return time != 0 ? time : a.$2.id.compareTo(b.$2.id);
      });
      final preview = _preview;
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(child: preview != null && archived.contains(preview)
          ? _conversation(preview.$1, preview.$2)
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Archived tasks (${all.length})',
                style: const TextStyle(fontSize: 15, height: 20 / 15, fontWeight: FontWeight.w600, color: desktopForeground)),
              const SizedBox(height: 8),
              const Text('Select a task to preview its conversation. Restore to continue it.',
                style: TextStyle(fontSize: 12, color: desktopSecondary)),
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('archived-search'),
                controller: _search,
                decoration: const InputDecoration(hintText: 'Search archived tasks',
                  prefixIcon: Icon(Icons.search, size: 17)),
                onChanged: (_) {
                  if (_scroll.hasClients) _scroll.jumpTo(0);
                  setState(() {});
                },
              ),
              const SizedBox(height: 16),
              if (archived.isEmpty)
                Text(all.isEmpty ? 'No archived tasks.' : 'No matching archived tasks.',
                  style: const TextStyle(fontSize: 12, color: desktopSecondary))
              else
                Expanded(child: Scrollbar(controller: _scroll, child: ListView.builder(
                  key: const PageStorageKey('archived-sessions'),
                  controller: _scroll,
                  itemCount: archived.length,
                  itemBuilder: (context, index) {
                    final (project, task) = archived[index];
                    return ListTile(
                      key: ValueKey('archived:${task.id}'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(task.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Tooltip(message: project.path,
                        child: Text(project.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                      onTap: task.archiving ? null : () => _open(project, task),
                      trailing: _restoreButton(task),
                    );
                  },
                ))),
            ])),
      ]);
    },
  );

  Widget _conversation(Project project, DesktopTask task) => Focus(
    autofocus: true,
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.escape) return KeyEventResult.ignored;
      _back();
      return KeyEventResult.handled;
    },
    child: Column(key: const ValueKey('archived-preview'), children: [
      Align(alignment: Alignment.centerLeft, child: TextButton.icon(
        onPressed: _back, icon: const Icon(Icons.arrow_back, size: 16),
        label: const Text('Back to archived tasks'))),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(task.title, maxLines: 2, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: desktopForeground)),
          const SizedBox(height: 4),
          Text(project.name, style: const TextStyle(fontSize: 12, color: desktopSecondary)),
        ])),
        const SizedBox(width: 12),
        _restoreButton(task),
      ]),
      const SizedBox(height: 16),
      const Divider(height: 1),
      Expanded(child: ConversationDataScope(client: widget.session.client, providers: widget.session.providers,
        child: ConversationTranscript(
          key: ValueKey('archived-transcript:${task.id}'), task: task, directory: project.path,
          onRetry: () => _load(task),
          onLoadEarlier: () => unawaited(widget.run(
            () => widget.session.loadEarlier(task, cancellation: _read))),
        ))),
    ]),
  );
}
