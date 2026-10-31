import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:macos_file_picker/macos_file_picker.dart';
import 'package:protocol/protocol.dart';
import 'package:desktop_drop/desktop_drop.dart';

import 'conversation.dart';
import 'composer_dictation.dart';
import 'composer_attachments.dart';
import 'dictation.dart';
import 'dictation_controls.dart';
import 'file_autocomplete.dart';
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
      await session.dictation.cancel();
      if (!mounted) return;
      await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (context) => ListenableBuilder(
          listenable: session,
          builder: (context, _) => Scaffold(
            appBar: AppBar(title: const Text('Settings')),
            body: Align(alignment: Alignment.topCenter, child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: SizedBox(
              width: 640,
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
                  const Text('Dictation', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 12),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'live', label: Text('Live')),
                      ButtonSegment(value: 'on_stop', label: Text('On stop')),
                    ],
                    selected: {session.dictationMode},
                    onSelectionChanged: (value) => _run(() => session.chooseDictationMode(value.single)),
                  ),
                  const SizedBox(height: 8),
                  Text(session.dictationMode == 'live'
                      ? 'Show text while you speak. If live dictation is unavailable, transcribe when you stop.'
                      : 'Record first, then insert the transcription when you stop.',
                    style: const TextStyle(fontSize: 12, color: Colors.black54)),
                  const SizedBox(height: 24),
                  _archivedTasks(context),
                  if (session.error case final error?)
                    Padding(padding: const EdgeInsets.only(top: 20), child: SelectableText(error,
                      style: TextStyle(color: Theme.of(context).colorScheme.error))),
                ],
              ),
            ))),
          ),
        ),
      ));
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

  Widget _archivedTasks(BuildContext settingsContext) {
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
                    Navigator.pop(settingsContext);
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
  final _focus = FocusNode();
  final _attachmentLifetime = CancellationToken();
  bool _receivingAttachments = false, _draggingAttachments = false;
  List<ComposerAttachment> get _attachments => widget.session.attachmentDrafts[_draftKey] ?? const [];
  late final _voiceOwner = Object();
  DictationService? _boundVoice;
  ComposerDictationSession? _voiceText;
  bool _finishingVoice = false, _disposing = false;
  DictationService get _voice => widget.session.dictation;
  bool get _ownsVoice => identical(_voice.owner, _voiceOwner);
  bool get _dictating => _ownsVoice && (_voice.active || _finishingVoice);
  DictationUiPhase get _voicePhase => !_ownsVoice ? DictationUiPhase.idle : switch (_voice.phase) {
    DictationPhase.idle => _finishingVoice ? DictationUiPhase.transcribing : DictationUiPhase.idle,
    DictationPhase.starting => DictationUiPhase.starting,
    DictationPhase.recording => DictationUiPhase.recording,
    DictationPhase.transcribing => DictationUiPhase.transcribing,
    DictationPhase.failed => _voice.canRetry ? DictationUiPhase.retry : DictationUiPhase.idle,
  };

  void _bindVoice() {
    if (identical(_boundVoice, _voice)) return;
    _boundVoice?.removeListener(_voiceChanged);
    _boundVoice = _voice;
    _boundVoice!.addListener(_voiceChanged);
  }

  void _voiceChanged() {
    if (!mounted) return;
    if (_ownsVoice && _voice.active) {
      _voiceText?.update(_voice.transcript);
    } else if (_ownsVoice && _voice.canRetry) {
      _voiceText?.pauseForRecovery();
    } else if (!_ownsVoice || !_finishingVoice) {
      _voiceText?.dispose(cancel: true);
      _voiceText = null;
    }
    setState(() {});
  }

  Future<void> _startVoice() async {
    if (_voice.active || _finishingVoice || !widget.session.connected || widget.session.submitting) return;
    _voiceText?.dispose();
    _voiceText = ComposerDictationSession(_text, (range, text) {
      final editorContext = _focus.context;
      if (!_disposing && editorContext != null && editorContext.mounted) {
        Actions.invoke(editorContext, ReplaceTextIntent(_text.value, text, range, SelectionChangedCause.keyboard));
      } else {
        // Navigation may already have detached the editable widget. Restore the
        // saved draft through its controller without looking up widget actions.
        _text.value = TextEditingValue(text: _text.text.replaceRange(range.start, range.end, text),
          selection: TextSelection.collapsed(offset: range.start + text.length));
      }
    });
    _focus.requestFocus();
    await _voice.start(owner: _voiceOwner, liveTranscription: widget.session.dictationMode == 'live',
      onRecordingLimit: () => unawaited(_finishVoice(DictationAction.insert)));
  }

  Future<void> _cancelVoice() async {
    if (!_ownsVoice) return;
    _voiceText?.dispose(cancel: true);
    _voiceText = null;
    await _voice.cancel();
    if (mounted) _focus.requestFocus();
  }

  Future<void> _finishVoice(DictationAction action, {bool retry = false}) async {
    if (!_ownsVoice || _finishingVoice) return;
    setState(() => _finishingVoice = true);
    try {
      final result = retry ? await _voice.retry(action) : await _voice.stop(action);
      if (!mounted || !_ownsVoice || result == null) return;
      final inserted = await _voiceText?.finish(result.text) ?? false;
      if (!mounted || !_ownsVoice || !inserted) return;
      _voiceText?.dispose();
      _voiceText = null;
      _focus.requestFocus();
      if (result.action == DictationAction.send) await _sendPrompt();
    } finally {
      _finishingVoice = false;
      if (mounted) setState(() {});
    }
  }

  @override
  void initState() {
    super.initState();
    _text.addListener(_saveDraft);
  }

  void _saveDraft() {
    if (_text.text.isEmpty) {
      widget.session.drafts.remove(_draftKey);
    } else {
      widget.session.drafts[_draftKey] = _text.text;
    }
  }

  void _addAttachments(List<ComposerAttachment> additions) {
    if (!mounted) return;
    setState(() {
      final draft = widget.session.attachmentDrafts.putIfAbsent(_draftKey, () => []);
      for (final attachment in additions) {
        if (!draft.any((existing) => existing.path == attachment.path)) draft.add(attachment);
      }
    });
    _focus.requestFocus();
  }

  Future<void> _paste(SelectionChangedCause cause) async {
    if (_receivingAttachments || widget.session.submitting || _dictating || !widget.session.connected) return;
    final before = _text.value;
    setState(() => _receivingAttachments = true);
    try {
      final snapshot = await readComposerClipboard(widget.session.attachmentDirectory, _attachmentLifetime);
      if (!mounted) {
        for (final attachment in snapshot.attachments) { await attachment.discard(); }
        return;
      }
      if (snapshot.attachments.isNotEmpty) {
        _addAttachments(snapshot.attachments);
      } else if (_text.text == before.text && snapshot.text != null) {
        final current = _text.value;
        final range = current.selection.isValid ? current.selection : TextSelection.collapsed(offset: current.text.length);
        final editor = _focus.context;
        if (editor != null && editor.mounted) {
          Actions.invoke(editor, ReplaceTextIntent(current, snapshot.text!, range, cause));
        }
      }
    } on CancelledException {
      // Leaving this composer owns the pending native snapshot.
    } catch (error) {
      if (mounted) widget.session.showError(error);
    } finally {
      if (mounted) setState(() => _receivingAttachments = false);
    }
  }

  Future<void> _drop(DropDetails details) async {
    if (_receivingAttachments || widget.session.submitting) return;
    setState(() => _receivingAttachments = true);
    try {
      final attachments = await receiveComposerDrop(details, widget.session.attachmentDirectory, _attachmentLifetime);
      if (mounted) {
        _addAttachments(attachments);
      } else {
        for (final attachment in attachments) { await attachment.discard(); }
      }
    } on CancelledException {
      // The source is released by DropTarget after this operation settles.
    } catch (error) {
      if (mounted) widget.session.showError(error);
    } finally {
      if (mounted) setState(() => _receivingAttachments = false);
    }
  }

  Future<void> _submit() async {
    if (!_text.value.composing.isCollapsed) return;
    if (_dictating) {
      await _finishVoice(DictationAction.send);
      return;
    }
    await _sendPrompt();
  }

  Future<void> _sendPrompt() async {
    if (_receivingAttachments) return;
    final prompt = _text.text;
    final attachments = List<ComposerAttachment>.of(_attachments);
    try {
      final accepted = await widget.session.send(prompt, attachments: attachments);
      if (accepted) {
        if (widget.session.drafts[_draftKey] == prompt) widget.session.drafts.remove(_draftKey);
        final ids = attachments.map((attachment) => attachment.id).toSet();
        widget.session.attachmentDrafts[_draftKey]?.removeWhere((attachment) => ids.contains(attachment.id));
        if (widget.session.attachmentDrafts[_draftKey]?.isEmpty == true) widget.session.attachmentDrafts.remove(_draftKey);
        for (final attachment in attachments) {
          if (attachment.image || !widget.session.client.sharedFilesystem) await attachment.discard();
        }
        if (mounted && _text.text == prompt) _text.clear();
        if (mounted) setState(() {});
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
    _disposing = true;
    _attachmentLifetime.cancel();
    _boundVoice?.removeListener(_voiceChanged);
    _voiceText?.dispose(cancel: true);
    if (_boundVoice != null && identical(_boundVoice!.owner, _voiceOwner)) unawaited(_boundVoice!.cancel());
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _bindVoice();
    final session = widget.session;
    final running = session.task?.running == true;
    final available =
        session.connected &&
        !_receivingAttachments &&
        !session.submitting &&
        session.task?.loading != true &&
        session.task?.loadError == null;
    return DropTarget(
      enabled: session.connected && !session.submitting && !_receivingAttachments,
      acceptedKinds: const {DropItemKind.file, DropItemKind.directory},
      onDrop: _drop,
      onEnter: (_) => setState(() => _draggingAttachments = true),
      onLeave: () { if (mounted) setState(() => _draggingAttachments = false); },
      child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 8, 28, 20),
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape, includeRepeats: false): () {
                if (!_text.value.composing.isCollapsed) return;
                if (_ownsVoice && (_dictating || _voice.phase == DictationPhase.failed)) unawaited(_cancelVoice());
              },
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
            child: Actions(actions: {PasteTextIntent: ComposerPasteAction(
              enabled: session.connected && !session.submitting && !_receivingAttachments && !_dictating, paste: _paste)},
            child: FileAutocomplete(
              controller: _text,
              focusNode: _focus,
              client: session.client,
              cwd: session.project!.path,
              enabled: session.connected && !_dictating,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: _draggingAttachments ? Theme.of(context).colorScheme.primary : const Color(0xffdaddd5),
                    width: _draggingAttachments ? 2 : 1),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 10, 8),
                  child: Column(
                    children: [
                      if (_draggingAttachments) const Padding(padding: EdgeInsets.all(8), child: Text('Drop images or files to attach')),
                      if (_attachments.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 8), child: Align(
                        alignment: Alignment.centerLeft,
                        child: AttachmentRail(attachments: _attachments.map((attachment) => attachment.toJson()).toList(),
                          onRemove: session.submitting ? null : (index) {
                            final removed = _attachments[index];
                            setState(() => widget.session.attachmentDrafts[_draftKey]!.remove(removed));
                            unawaited(removed.discard());
                          }),
                      )),
                      if (_receivingAttachments || session.attachmentStatus != null) Row(children: [
                        const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 8),
                        Expanded(child: Text(session.attachmentStatus ?? 'Adding attachments…', style: const TextStyle(fontSize: 12))),
                        if (session.attachmentStatus != null) IconButton(tooltip: 'Cancel upload', onPressed: session.cancelUpload, icon: const Icon(Icons.close, size: 16)),
                      ]),
                      if (_ownsVoice && _voice.canRetry)
                        Tooltip(message: _voice.error ?? 'Dictation stopped', child: DictationRecoveryRail(
                          phase: DictationRecoveryPhase.failed,
                          onDismiss: () => unawaited(_cancelVoice()),
                          onRetry: () => unawaited(_finishVoice(DictationAction.insert, retry: true)),
                        ))
                      else if (_ownsVoice && _voice.error != null)
                        Semantics(liveRegion: true, child: Row(children: [
                          Expanded(child: Text(_voice.error!, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.error))),
                          if (_voice.microphonePermissionDenied)
                            TextButton(onPressed: _voice.openMicrophoneSettings, child: const Text('Open microphone settings')),
                          IconButton(tooltip: 'Dismiss dictation error', onPressed: _cancelVoice, icon: const Icon(Icons.close, size: 16)),
                        ])),
                      TextField(
                        controller: _text,
                        focusNode: _focus,
                        enabled: session.connected,
                        contextMenuBuilder: (_, state) => composerContextMenu(state, _paste),
                        autofocus: true,
                        minLines: 2,
                        maxLines: 8,
                        decoration: const InputDecoration(
                          hintText: 'Describe a task or use @ to mention a file or folder…',
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
                                    ? 'Reasoning level for your next message'
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
                          if (_dictating) ...[
                            DictationCancelButton(onCancel: () => unawaited(_cancelVoice())),
                            const SizedBox(width: 8),
                          ],
                          Expanded(
                            child: Text(
                              _ownsVoice && _voice.phase == DictationPhase.recording && _voice.liveTranscriptionHint != null
                                  ? _voice.liveTranscriptionHint! : session.authenticated
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
                          if (defaultTargetPlatform == TargetPlatform.macOS) ...[
                            DictationButton(
                              phase: _voicePhase,
                              amplitude: _voice.amplitude,
                              statusHint: _voice.liveTranscriptionHint,
                              enabled: available && (!_voice.active || _ownsVoice),
                              onStart: () => unawaited(_startVoice()),
                              onStop: () => unawaited(_finishVoice(DictationAction.insert)),
                              onCancel: () => unawaited(_cancelVoice()),
                              onRetry: () => unawaited(_finishVoice(DictationAction.insert, retry: true)),
                            ),
                            const SizedBox(width: 8),
                          ],
                          IconButton.filled(
                            tooltip: running
                                ? (session.deliveryMode == 'steer'
                                      ? 'Steer task'
                                      : 'Queue message')
                                : 'Send message',
                            onPressed: available && session.authenticated &&
                                (!_dictating || _voice.phase == DictationPhase.recording && !_finishingVoice)
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
            )),
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
