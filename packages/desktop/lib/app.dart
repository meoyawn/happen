import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:macos_file_picker/macos_file_picker.dart';
import 'package:protocol/protocol.dart';

import 'conversation.dart';
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
            title: const Text('Settings'),
            scrollable: true,
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (session.loginSucceeded) ...[
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(color: const Color(0xffe3f1e8), borderRadius: BorderRadius.circular(12)),
                      child: Row(children: [
                        const Icon(Icons.check_circle, color: Color(0xff296748)),
                        const SizedBox(width: 12),
                        Expanded(child: Text('Signed in to ${session.loginProvider == 'gpt' ? 'ChatGPT' : 'OpenCode'}. Your account is connected.')),
                      ]),
                    ),
                    const SizedBox(height: 20),
                  ],
                  const Text('Accounts', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 12),
                  for (final provider in session.selectableProviders) _accountCard(provider),
                  const SizedBox(height: 20),
                  const Text('Default provider', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: session.defaultProviderId,
                    decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                    items: [for (final provider in session.selectableProviders)
                      DropdownMenuItem(value: provider['id'] as String, child: Text(provider['name'] as String))],
                    onChanged: session.connected ? (value) => _run(() => session.chooseProvider(value!)) : null,
                  ),
                  const SizedBox(height: 8),
                  const Text('Used for new tasks. Existing tasks keep their provider.', style: TextStyle(fontSize: 12, color: Colors.black54)),
                  const SizedBox(height: 24),
                  const Text('Messages sent while a task is working', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 12),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'steer', label: Text('Steer')),
                      ButtonSegment(value: 'queue', label: Text('Queue')),
                    ],
                    selected: {session.deliveryMode},
                    onSelectionChanged: (value) => _run(() => session.chooseDeliveryMode(value.single)),
                  ),
                  const SizedBox(height: 8),
                  Text(session.deliveryMode == 'steer'
                      ? 'Guide the current turn at the next model step.'
                      : 'Wait for the current turn to finish, then start the next one.',
                    style: const TextStyle(fontSize: 12, color: Colors.black54)),
                  const SizedBox(height: 24),
                  _archivedTasks(context),
                ],
              ),
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: Text(session.loginSucceeded ? 'Continue' : 'Done'),
              ),
            ],
          ),
        ),
      );
    } finally {
      _settingsOpen = false;
      await _run(session.cancelLogin);
      session.dismissLoginResult();
    }
  }

  Future<void> _signIn(String provider) async {
    final success = await session.signIn(provider, (url) async {
      if (await _desktop.invokeMethod<bool>('openLoginUrl', url) != true) {
        throw StateError('Could not open the browser');
      }
    });
    if (success && mounted) await _desktop.invokeMethod<void>('activate');
  }

  Widget _archivedTasks(BuildContext dialogContext) {
    final archived = [
      for (final project in session.projects)
        for (final task in project.tasks)
          if (task.archived) (project, task),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Archived tasks (${archived.length})', style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        if (archived.isEmpty)
          const Text('No archived tasks.', style: TextStyle(fontSize: 12, color: Colors.black54))
        else ...[
          const Text('Select a task to view its conversation. Restore to continue it.', style: TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 8),
          SizedBox(
            height: (archived.length * 80.0).clamp(80.0, 240.0),
            width: double.maxFinite,
            child: ListView.builder(
              itemCount: archived.length,
              itemBuilder: (context, index) {
                final (project, task) = archived[index];
                return ListTile(
                  key: ValueKey('archived:${task.id}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(task.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Tooltip(message: project.path, child: Text(project.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  onTap: task.archiving ? null : () {
                    Navigator.pop(dialogContext);
                    unawaited(_run(() => session.select(project, task)));
                  },
                  trailing: TextButton(
                    onPressed: session.connected && !task.archiving
                        ? () => _run(() => session.setArchived(task, false))
                        : null,
                    child: Text(task.archiving ? 'Restoring…' : 'Restore'),
                  ),
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _accountCard(Json provider) {
    final id = provider['id'] as String;
    final name = provider['auth'] == 'opencode' ? 'OpenCode' : provider['name'] as String;
    final status = provider['status'] as String;
    final connected = {'signed_in', 'refresh_required', 'api_key'}.contains(status);
    final working = session.signingIn && session.loginProvider == id;
    final available = session.connected && !session.signingIn && session.signingOut == null;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(border: Border.all(color: const Color(0xffdaddd5)), borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
            if (provider['auth'] == 'opencode') const Text('DeepSeek models', style: TextStyle(fontSize: 12, color: Colors.black54)),
          ])),
          Icon(connected ? Icons.check_circle : Icons.circle_outlined, size: 15, color: connected ? const Color(0xff296748) : Colors.black38),
          const SizedBox(width: 6),
          Text(_authLabel(status), style: const TextStyle(fontSize: 12)),
        ]),
        const SizedBox(height: 12),
        if (working) ...[
          Row(children: [
            const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 10),
            Expanded(child: Text(session.loginMessage ?? 'Waiting for your browser…', style: const TextStyle(fontSize: 12))),
          ]),
          if (session.loginCode case final code?) Padding(padding: const EdgeInsets.only(top: 8), child: SelectableText(code, style: const TextStyle(fontFamily: 'monospace', fontSize: 18))),
          Row(children: [
            TextButton(onPressed: session.loginUrl == null ? null : session.openLoginBrowser, child: const Text('Open browser')),
            TextButton(onPressed: () => _run(session.cancelLogin), child: const Text('Cancel')),
          ]),
        ] else if (provider['auth'] == 'api_key')
          const Text('Uses the API key configured on this server.', style: TextStyle(fontSize: 12, color: Colors.black54))
        else
          Wrap(spacing: 8, children: [
            if (!connected)
              FilledButton(onPressed: available ? () => _run(() => _signIn(id)) : null, child: Text('Sign in to $name'))
            else
              OutlinedButton(onPressed: available ? () => session.signOut(id) : null, child: Text(session.signingOut == id ? 'Signing out…' : 'Sign out')),
            if (connected)
              TextButton(onPressed: available ? () => _run(() => _signIn(id)) : null, child: const Text('Switch account')),
          ]),
        if (session.loginProvider == id && session.loginError != null)
          Padding(padding: const EdgeInsets.only(top: 8), child: Text(session.loginError!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12))),
      ]),
    );
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
                      : ConversationTranscript(
                          key: ValueKey(session.task!.id),
                          task: session.task!,
                          directory: session.project!.path,
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
                if (session.task?.archived == true)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: FilledButton.icon(
                      onPressed: () => _run(() => _archiveTask(session.task!, false)),
                      icon: const Icon(Icons.unarchive_outlined),
                      label: const Text('Restore task to continue'),
                    ),
                  )
                else if (session.project != null)
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
                  for (final task in project.tasks.where((task) => !task.archived))
                    _taskTile(project, task),
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
          for (final provider in session.selectableProviders)
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

  Widget _taskTile(Project project, DesktopTask task) => Padding(
    padding: const EdgeInsets.only(left: 22, bottom: 2),
    child: ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 12),
      visualDensity: const VisualDensity(vertical: -2),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      selected: session.task == task,
      selectedTileColor: const Color(0xffe2e7df),
      title: Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (task.running || task.archiving)
          const SizedBox.square(dimension: 10, child: CircularProgressIndicator(strokeWidth: 1.5)),
        PopupMenuButton<String>(
          tooltip: 'Task actions',
          enabled: session.connected && !task.archiving,
          icon: const Icon(Icons.more_horiz, size: 18),
          onSelected: (value) => _run(() => _archiveTask(task, value == 'archive')),
          itemBuilder: (_) => [
            PopupMenuItem(value: task.archived ? 'restore' : 'archive', child: Text(task.archived ? 'Restore task' : 'Archive task')),
          ],
        ),
      ]),
      onTap: () => _run(() => session.select(project, task)),
    ),
  );

  Future<void> _archiveTask(DesktopTask task, bool archived) async {
    await session.setArchived(task, archived);
    if (!mounted) return;
    if (!archived) {
      final project = session.projects.firstWhere((project) => project.tasks.contains(task));
      await session.select(project, task);
    } else {
      ScaffoldMessenger.of(context)..clearSnackBars()..showSnackBar(SnackBar(
        content: const Text('Task archived'),
        duration: const Duration(seconds: 3),
        persist: false,
        action: SnackBarAction(label: 'Undo', onPressed: () => _run(() => _archiveTask(task, false))),
      ));
    }
  }

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

  void _newline() {
    final value = _text.value;
    if (!value.composing.isCollapsed) return;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    _text.value = TextEditingValue(
      text: value.text.replaceRange(selection.start, selection.end, '\n'),
      selection: TextSelection.collapsed(offset: selection.start + 1),
    );
    widget.session.drafts[_draftKey] = _text.text;
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
              const SingleActivator(LogicalKeyboardKey.enter, shift: true): _newline,
              const SingleActivator(
                LogicalKeyboardKey.enter,
                includeRepeats: false,
              ): () {
                if (available) unawaited(_submit());
              },
              const SingleActivator(LogicalKeyboardKey.enter, meta: true): () {
                if (available) unawaited(_submit());
              },
              const SingleActivator(
                LogicalKeyboardKey.enter,
                control: true,
              ): () {
                if (available) unawaited(_submit());
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
                      autofocus: true,
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
                                ? 'Enter to send · Shift+Enter for a new line'
                                : 'Sign in to the selected provider to send',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.black38,
                            ),
                          ),
                        ),
                        if (running)
                          IconButton(
                            tooltip: 'Stop task and clear pending messages',
                            onPressed: available ? _stop : null,
                            icon: const Icon(Icons.stop_rounded, size: 20),
                          ),
                        IconButton.filled(
                          tooltip: running
                              ? (session.deliveryMode == 'steer'
                                    ? 'Steer task'
                                    : 'Queue message')
                              : 'Send message',
                          onPressed: available && session.authenticated
                              ? _submit
                              : null,
                          icon: Icon(
                            running && session.deliveryMode == 'queue'
                                ? Icons.playlist_add
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
