import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:macos_file_picker/macos_file_picker.dart';
import 'package:protocol/protocol.dart';

import 'session.dart';

class DesktopView extends StatefulWidget {
  const DesktopView({super.key, required this.session});
  final DesktopSession session;

  @override
  State<DesktopView> createState() => _DesktopViewState();
}

class _DesktopViewState extends State<DesktopView> {
  static const _desktop = MethodChannel('happen/desktop');
  DesktopSession get session => widget.session;
  bool _picking = false, _settingsOpen = false;

  @override
  void initState() {
    super.initState();
    _desktop.setMethodCallHandler((call) async {
      if (call.method == 'showSettings') await _settings();
    });
  }

  @override
  void dispose() {
    _desktop.setMethodCallHandler(null);
    super.dispose();
  }

  Future<void> _settings() async {
    if (_settingsOpen || !mounted) return;
    _settingsOpen = true;
    try {
      await showDialog<void>(
    context: context,
    builder: (context) => ListenableBuilder(
      listenable: session,
      builder: (context, _) => AlertDialog(
        title: const Text('App settings'),
        content: SizedBox(width: 360, child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Default provider', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            const Text('Used for new tasks. Existing tasks keep their provider.',
                style: TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 12),
            for (final provider in session.providers)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(session.defaultProviderId == provider['id']
                    ? Icons.radio_button_checked : Icons.radio_button_off),
                title: Text(provider['name'] as String),
                subtitle: Text(_authLabel(provider['status'] as String)),
                onTap: () => _run(() => session.chooseProvider(provider['id'] as String)),
              ),
          ],
        )),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
      ),
    ),
      );
    } finally {
      _settingsOpen = false;
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } on CancelledException {
      // The window was closed while this action was pending.
    } catch (error) {
      session.showError(error);
    }
  }

  Future<void> _addProject() => _run(() async {
    if (_picking) return;
    _picking = true;
    try {
      final paths = await MacosFilePicker().pick(
        MacosFilePickerMode.folder,
        allowsMultiple: false,
        dialogTitle: 'Open project',
      );
      try {
        if (mounted && paths != null && paths.isNotEmpty) {
          await session.addProject(paths.first.path);
        }
      } finally {
        for (final path in paths ?? <MacosFilePickerPath>[]) {
          await path.release();
        }
      }
    } finally {
      _picking = false;
    }
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) => Scaffold(
      body: Row(
        children: [
          _sidebar(context),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              children: [
                _header(context),
                const Divider(height: 1),
                Expanded(
                  child: session.task == null
                      ? _empty(context)
                      : _Transcript(
                          key: ValueKey(session.task!.id),
                          task: session.task!,
                          onRetry: () =>
                              _run(() => session.loadHistory(session.task!)),
                        ),
                ),
                if (session.error case final error?)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(28, 8, 28, 0),
                    child: SelectableText(
                      error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (session.project != null)
                  _Composer(key: ValueKey(session.draftKey), session: session),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _sidebar(BuildContext context) => SizedBox(
    width: 248,
    child: Material(
      color: const Color(0xfff2f3ef),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(22, 24, 20, 28),
            child: Row(
              children: [
                Icon(Icons.blur_on_rounded, size: 24, color: Color(0xff325e57)),
                SizedBox(width: 10),
                Text(
                  'Happen',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 22, right: 12),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'PROJECTS',
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 1.2,
                      color: Colors.black54,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Open project',
                  onPressed: _addProject,
                  icon: const Icon(Icons.create_new_folder_outlined, size: 19),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              children: [
                for (final project in session.projects) ...[
                  ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.only(left: 12),
                    leading: const Icon(Icons.folder_outlined, size: 19),
                    minLeadingWidth: 20,
                    title: Tooltip(
                      message: project.path,
                      child: Text(
                        project.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    onTap: () => _run(() => session.select(project)),
                    trailing: IconButton(
                      tooltip: 'New task in ${project.name}',
                      icon: const Icon(Icons.add, size: 18),
                      onPressed: () => _run(() => session.select(project)),
                    ),
                  ),
                  for (final task in project.tasks)
                    Padding(
                      padding: const EdgeInsets.only(left: 22, bottom: 2),
                      child: ListTile(
                        dense: true,
                        visualDensity: const VisualDensity(vertical: -2),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        selected: session.task == task,
                        selectedTileColor: const Color(0xffe2e7df),
                        title: Text(
                          task.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: task.running
                            ? const SizedBox.square(
                                dimension: 10,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.5,
                                ),
                              )
                            : null,
                        onTap: () => _run(() => session.select(project, task)),
                      ),
                    ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 12, 0),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'PROVIDERS',
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 1,
                      color: Colors.black45,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh provider login status',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _run(session.refreshProviders),
                  icon: const Icon(Icons.refresh, size: 16),
                ),
              ],
            ),
          ),
          for (final provider in session.providers)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 3, 20, 3),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      provider['name'] as String,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  Text(
                    _authLabel(provider['status'] as String),
                    style: TextStyle(
                      fontSize: 11,
                      color:
                          {
                            'signed_in',
                            'refresh_required',
                            'api_key',
                          }.contains(provider['status'])
                          ? const Color(0xff325e57)
                          : Colors.black45,
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 7,
                  color: session.connected
                      ? const Color(0xff567f59)
                      : Colors.orange,
                ),
                const SizedBox(width: 9),
                Text(
                  session.connected ? 'Local' : 'Disconnected',
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'App settings',
                  onPressed: _settings,
                  icon: const Icon(Icons.settings_outlined, size: 18),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _header(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 18),
    child: Row(
      children: [
        Expanded(
          child: Text(
            session.task?.title ?? session.project?.name ?? 'Your workspace',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
        ),
        if (session.project != null)
          TextButton.icon(
            onPressed: () => _run(() => session.select(session.project!)),
            icon: const Icon(Icons.edit_square, size: 16),
            label: const Text('New task'),
          ),
      ],
    ),
  );

  Widget _empty(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.blur_on_rounded, size: 42, color: Color(0xff7f9384)),
          const SizedBox(height: 24),
          Text(
            session.project == null
                ? 'Start with a project'
                : 'What are we working on?',
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 12),
          Text(
            session.project == null
                ? 'Open a folder, then start a task.'
                : 'Each task keeps its own conversation.',
            style: const TextStyle(color: Colors.black54),
          ),
          if (session.project == null) ...[
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _addProject,
              icon: const Icon(Icons.folder_open, size: 18),
              label: const Text('Open project'),
            ),
          ],
        ],
      ),
    ),
  );
}

class _Transcript extends StatefulWidget {
  const _Transcript({super.key, required this.task, required this.onRetry});
  final DesktopTask task;
  final VoidCallback onRetry;

  @override
  State<_Transcript> createState() => _TranscriptState();
}

class _TranscriptState extends State<_Transcript> {
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(_Transcript oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_scroll.hasClients || _scroll.position.extentAfter < 100) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
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
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(24),
              child: SelectableText(error),
            ),
            TextButton(
              onPressed: widget.onRetry,
              child: const Text('Retry loading conversation'),
            ),
          ],
        ),
      );
    }
    final entries = conversation(task);
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: ListView.builder(
          key: PageStorageKey(task.id),
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(32, 28, 32, 20),
          itemCount: entries.length + (task.running ? 1 : 0),
          itemBuilder: (context, index) {
            if (index == entries.length) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Text(
                  'Working…',
                  style: TextStyle(color: Colors.black45),
                ),
              );
            }
            final entry = entries[index];
            if (entry.tool case final tool?) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _ToolRow(key: ValueKey(tool.id), tool: tool),
              );
            }
            return Padding(
              padding: const EdgeInsets.only(bottom: 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.role,
                    style: TextStyle(
                      fontSize: 12,
                      color: entry.role == 'Error'
                          ? Theme.of(context).colorScheme.error
                          : Colors.black45,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    entry.text,
                    style: const TextStyle(fontSize: 15, height: 1.55),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ToolRow extends StatelessWidget {
  const _ToolRow({super.key, required this.tool, this.nested = false});
  final ToolActivity tool;
  final bool nested;

  @override
  Widget build(BuildContext context) {
    final running = tool.status == 'running';
    final failed = tool.status == 'failed';
    final color = failed ? Theme.of(context).colorScheme.error : Colors.black54;
    return ExpansionTile(
      key: PageStorageKey(tool.id),
      initiallyExpanded: !nested,
      dense: true,
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(left: 24, bottom: 8),
      shape: const Border(),
      collapsedShape: const Border(),
      leading: running
          ? const SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            )
          : Icon(
              failed
                  ? Icons.error_outline
                  : tool.status == 'done'
                  ? Icons.check_rounded
                  : Icons.stop_circle_outlined,
              size: 16,
              color: color,
            ),
      title: Text(
        tool.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: color),
      ),
      subtitle: nested
          ? null
          : Text(
              tool.children.isEmpty
                  ? tool.status
                  : '${tool.children.length} calls · ${tool.status}',
              style: TextStyle(fontSize: 11, color: color),
            ),
      children: [
        if (!nested) ...[
          for (final child in tool.children)
            _ToolRow(key: ValueKey(child.id), tool: child, nested: true),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            dense: true,
            shape: const Border(),
            collapsedShape: const Border(),
            title: const Text('Code & output', style: TextStyle(fontSize: 12)),
            children: [_details()],
          ),
        ] else
          _details(),
      ],
    );
  }

  Widget _details() => Align(
    alignment: Alignment.centerLeft,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: SelectableText(
        '${tool.input}${tool.output == null ? '' : '\n\n${tool.output}'}',
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          height: 1.5,
        ),
      ),
    ),
  );
}

class _Composer extends StatefulWidget {
  const _Composer({super.key, required this.session});
  final DesktopSession session;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  late final String _draftKey = widget.session.draftKey;
  late final _text = TextEditingController(
    text: widget.session.drafts[_draftKey] ?? '',
  );

  Future<void> _submit() async {
    final prompt = _text.text;
    try {
      final accepted = await widget.session.send(prompt);
      if (accepted) {
        widget.session.drafts.remove(_draftKey);
        if (mounted && _text.text == prompt) _text.clear();
      }
    } on CancelledException {
      // Application exit owns cancellation.
    }
  }

  Future<void> _stop() async {
    try {
      await widget.session.stop();
    } on CancelledException {
      // Application exit owns cancellation.
    } catch (error) {
      widget.session.showError(error);
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final running = session.task?.running == true;
    final available =
        session.connected &&
        !session.submitting &&
        session.task?.loading != true &&
        session.task?.loadError == null;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 8, 28, 20),
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.enter, meta: true): () {
                if (available && !running) unawaited(_submit());
              },
              const SingleActivator(
                LogicalKeyboardKey.enter,
                control: true,
              ): () {
                if (available && !running) unawaited(_submit());
              },
            },
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xffdaddd5)),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 10, 8),
                child: Column(
                  children: [
                    TextField(
                      controller: _text,
                      enabled: session.connected,
                      minLines: 2,
                      maxLines: 8,
                      onChanged: (value) => session.drafts[_draftKey] = value,
                      decoration: const InputDecoration(
                        hintText: 'Describe a task or ask a question…',
                        border: InputBorder.none,
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: DropdownButtonHideUnderline(
                        child: Wrap(
                          spacing: 16,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Tooltip(
                              message: session.task == null
                                  ? 'Model'
                                  : 'Model is fixed for this task',
                              child: DropdownButton<String>(
                                value:
                                    session.models.any(
                                      (m) => m['id'] == session.modelId,
                                    )
                                    ? session.modelId
                                    : null,
                                isDense: true,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.black87,
                                ),
                                onChanged: available && session.task == null
                                    ? (value) => session.chooseModel(value!)
                                    : null,
                                items: [
                                  for (final model in session.models)
                                    DropdownMenuItem(
                                      value: model['id'] as String,
                                      child: Text(model['id'] as String),
                                    ),
                                ],
                              ),
                            ),
                            Tooltip(
                              message:
                                  session.task == null ||
                                      session.task!.reasoningUpdates
                                  ? 'Reasoning level'
                                  : 'Reasoning is fixed for this task',
                              child: DropdownButton<String>(
                                value: session.reasoning,
                                isDense: true,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.black87,
                                ),
                                onChanged:
                                    available &&
                                        !running &&
                                        (session.task == null ||
                                            session.task!.reasoningUpdates)
                                    ? (value) => session.chooseReasoning(value!)
                                    : null,
                                items: [
                                  for (final level
                                      in session.modelInfo?['reasoning_levels']
                                              as List? ??
                                          [])
                                    DropdownMenuItem(
                                      value: level as String,
                                      child: Text('$level reasoning'),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            session.authenticated
                                ? '⌘ Enter to send'
                                : 'Sign in to the selected provider to send',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.black38,
                            ),
                          ),
                        ),
                        IconButton.filled(
                          tooltip: running ? 'Stop task' : 'Send message',
                          onPressed:
                              available && (running || session.authenticated)
                              ? (running ? _stop : _submit)
                              : null,
                          icon: Icon(
                            running
                                ? Icons.stop_rounded
                                : Icons.arrow_upward_rounded,
                            size: 20,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _authLabel(String status) => switch (status) {
  'signed_in' => 'Signed in',
  'refresh_required' => 'Login saved',
  'api_key' => 'API key set',
  'expired' => 'Login expired',
  'invalid' => 'Check login',
  _ => 'Not signed in',
};
