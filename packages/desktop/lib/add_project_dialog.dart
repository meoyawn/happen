import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:macos_file_picker/macos_file_picker.dart';
import 'package:protocol/protocol.dart';

import 'add_project_state.dart';
import 'appearance.dart';
import 'machine_icons.dart';
import 'machines.dart';
import 'remote_settings.dart';
import 'session.dart';

typedef _Choice = ({String id, String title, String description, Widget icon, VoidCallback? select});

class AddProjectDialog extends StatefulWidget {
  const AddProjectDialog({super.key, required this.session, this.machines, this.location});
  final DesktopSession session;
  final MachinesController? machines;
  final ProjectLocation? location;

  @override
  State<AddProjectDialog> createState() => _AddProjectDialogState();
}

class _AddProjectDialogState extends State<AddProjectDialog> {
  late final _controller = AddProjectController(location: widget.location);
  final _input = TextEditingController();
  final _scroll = ScrollController();
  late final _focus = FocusNode(onKeyEvent: _key);
  Timer? _debounce;
  String? _selected, _inputError;
  bool _pickingFolder = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_changed);
    if (widget.location != null) _navigate(() {});
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.removeListener(_changed);
    _controller.dispose();
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    if (_controller.state case final ProjectSaved result) {
      Navigator.pop(context, result);
    } else { setState(() {}); }
  }

  void _navigate(VoidCallback action) {
    _debounce?.cancel();
    action();
    final state = _controller.state;
    _input.text = switch (state) {
      ProjectLocation(:final source, :final remoteUrl) => source == ProjectSource.folder ? '~/'
        : '~/${remoteUrl == null ? 'new-project' : projectCloneName(remoteUrl)}',
      _ => '',
    };
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
    setState(() { _selected = null; _inputError = null; });
    if (state is ProjectLocation) _browse();
    _focus.requestFocus();
  }

  void _browse() {
    final location = projectLocation(_controller.state);
    if (location == null || _controller.busy) return;
    var query = _input.text;
    if (location.source != ProjectSource.folder) {
      final slash = query.lastIndexOf(RegExp(r'[/\\]'));
      query = slash < 0 ? '~/' : query.substring(0, slash + 1);
    }
    unawaited(_controller.browse(query));
  }

  void _edited(String value) {
    _controller.editLocation();
    setState(() { _selected = null; _inputError = null; });
    _debounce?.cancel();
    if (projectLocation(_controller.state) != null) {
      _debounce = Timer(const Duration(milliseconds: 120), _browse);
    }
  }

  Future<void> _addMachine() async {
    await showRemoteEditor(context, widget.machines!);
    if (mounted) _focus.requestFocus();
  }

  Future<void> _pickFolder() async {
    final location = projectLocation(_controller.state);
    if (_pickingFolder || _controller.busy || location == null ||
        !location.machine.session.client.sharedFilesystem) { return; }
    setState(() => _pickingFolder = true);
    try {
      final paths = await MacosFilePicker().pick(MacosFilePickerMode.folder,
        allowsMultiple: false, dialogTitle: location.source == ProjectSource.folder ? 'Add project' : 'Choose destination folder');
      try {
        if (!mounted || paths == null || paths.isEmpty || !identical(projectLocation(_controller.state), location)) return;
        if (location.source != ProjectSource.folder) {
          _enterFolder(paths.first.path, '/');
          return;
        }
        _input.text = paths.first.path;
        _input.selection = TextSelection.collapsed(offset: _input.text.length);
        _edited(_input.text);
        _browse();
        _focus.requestFocus();
      } finally {
        for (final path in paths ?? <MacosFilePickerPath>[]) { await path.release(); }
      }
    } catch (error) {
      if (mounted) setState(() => _inputError = '$error');
    } finally {
      if (mounted) setState(() => _pickingFolder = false);
    }
  }

  Widget _icon(IconData icon) => Icon(icon, size: 16, color: desktopSecondary);

  List<_Choice> get _choices {
    final state = _controller.state;
    bool matches(String value) => _input.text.trim().toLowerCase().split(RegExp(r'\s+'))
      .every(value.toLowerCase().contains);
    if (state is ProjectMachines) {
      final machines = widget.machines;
      final local = machines?.local ?? widget.session;
      return [
        if (matches('local this device ${local.machineName}'))
          (id: 'local', title: 'This device', description: local.connected ? 'Local folders and repositories' : 'Disconnected',
            icon: MachineGlyph(machines?.iconFor(null) ?? MachineIcon.laptop, size: 16, color: desktopSecondary),
            select: local.connected ? () => _navigate(() => _controller.chooseMachine((alias: null, name: 'This device', session: local))) : null),
        for (final host in machines?.hosts ?? <RemoteMachine>[])
          if (matches('${host.name} ${host.host} ${host.alias}'))
            for (final machine in [machines!.sessions.where((machine) => machine.alias == host.alias && machine.session.connected).firstOrNull])
              (id: host.alias, title: host.name,
                description: machine != null ? host.host : switch (machines.state(host.alias)) {
                  MachineFailed(:final error) => 'Disconnected · $error',
                  MachineConnecting() => 'Connecting…',
                  _ => 'Disconnected',
                },
                icon: MachineGlyph(machines.iconFor(host.alias), size: 16, color: desktopSecondary),
                select: machine == null ? null : () => _navigate(() => _controller.chooseMachine(machine))),
        if (machines != null)
          (id: 'add-machine', title: 'Add SSH machine…', description: 'Connect another computer or server',
            icon: _icon(Icons.add), select: () => unawaited(_addMachine())),
      ];
    }
    if (state is ProjectSources) {
      return [
        for (final (source, title, description, icon) in [
          (ProjectSource.create, 'New project', 'Start a new Git repository', Icons.create_new_folder_outlined),
          (ProjectSource.folder, 'Local folder', 'Browse a folder on ${state.machine.name}', Icons.folder_open_outlined),
          (ProjectSource.git, 'Git URL', 'Clone from a remote URL', Icons.link),
          (ProjectSource.github, 'GitHub repository', 'Clone owner/repository or a GitHub URL', Icons.code),
        ])
          if (matches('$title $description'))
            (id: source.name, title: title, description: description, icon: _icon(icon),
              select: () => _navigate(() => _controller.chooseSource(source))),
      ];
    }
    if (_controller.folders case ProjectFoldersReady(:final result) when state is ProjectLocation) {
      final separator = result['separator'] as String;
      return [
        if (result['directory'] != result['parent'])
          (id: 'parent', title: '..', description: 'Parent folder', icon: _icon(Icons.drive_folder_upload_outlined),
            select: () => _enterFolder(result['parent'] as String, separator)),
        for (final folder in (result['folders'] as List).map(jsonObject))
          (id: folder['path'] as String, title: folder['name'] as String,
            description: folder['path'] as String, icon: _icon(Icons.folder_outlined),
            select: () => _enterFolder(folder['path'] as String, separator)),
      ];
    }
    return [];
  }

  void _enterFolder(String path, String separator) {
    _controller.editLocation();
    final location = projectLocation(_controller.state)!;
    final leaf = _input.text.split(RegExp(r'[/\\]')).last;
    final name = leaf.isEmpty ? location.remoteUrl == null ? 'new-project' : projectCloneName(location.remoteUrl!) : leaf;
    _input.text = '$path${path.endsWith(separator) ? '' : separator}${location.source == ProjectSource.folder ? '' : name}';
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
    setState(() { _selected = null; _inputError = null; });
    _debounce?.cancel();
    _browse();
    _focus.requestFocus();
  }

  int _activeIndex(List<_Choice> choices) {
    final selected = choices.indexWhere((choice) => choice.id == _selected && choice.select != null);
    return selected >= 0 ? selected : choices.indexWhere((choice) => choice.select != null);
  }

  void _move(int offset) {
    final choices = _choices;
    var index = _activeIndex(choices);
    if (index < 0) return;
    do { index = (index + offset) % choices.length; } while (choices[index].select == null);
    setState(() => _selected = choices[index].id);
    if (_scroll.hasClients) {
      final top = index * 48.0;
      final position = _scroll.position;
      final target = top < position.pixels ? top : top + 48 > position.pixels + position.viewportDimension
        ? top + 48 - position.viewportDimension : position.pixels;
      _scroll.jumpTo(target.clamp(0.0, position.maxScrollExtent));
    }
  }

  void _activate() {
    if (!_input.value.composing.isCollapsed || _controller.busy) return;
    if (_controller.state is ProjectRepository || _controller.state is ProjectSaveFailed) { _submit(); return; }
    final choices = _choices;
    final index = _activeIndex(choices);
    if (index >= 0) { choices[index].select?.call(); }
    else if (projectLocation(_controller.state) != null) { _submit(); }
  }

  void _submit() {
    if (_controller.busy || !_input.value.composing.isCollapsed) return;
    if (_controller.state is ProjectRepository) {
      try { _navigate(() => _controller.repository(_input.text)); }
      on FormatException catch (error) { setState(() => _inputError = error.message); }
    } else if (projectLocation(_controller.state) != null) {
      unawaited(_controller.submit(_input.text));
    }
  }

  void _close() {
    if (_controller.busy) { _controller.cancel(); }
    else { Navigator.pop(context); }
  }

  bool get _atStart => widget.location == null ? _controller.state is ProjectMachines
    : _controller.state is! ProjectSaveFailed;

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if (!_input.value.composing.isCollapsed) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.enter && (keyboard.isMetaPressed || keyboard.isControlPressed)) {
      if (event is KeyDownEvent) _submit();
      return KeyEventResult.handled;
    }
    if (keyboard.isMetaPressed || keyboard.isControlPressed || keyboard.isAltPressed || keyboard.isShiftPressed) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown: _move(1);
      case LogicalKeyboardKey.arrowUp: _move(-1);
      case LogicalKeyboardKey.enter:
        if (event is KeyDownEvent) _activate();
      case LogicalKeyboardKey.escape:
        if (event is KeyDownEvent) _close();
      case LogicalKeyboardKey.backspace:
        if (_input.text.isNotEmpty || _atStart || _controller.busy) return KeyEventResult.ignored;
        if (event is KeyDownEvent) _navigate(_controller.back);
      default: return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  String get _submitLabel => switch (_controller.state) {
    ProjectRepository() => 'Continue',
    ProjectSaveFailed(:final preparedPath) when preparedPath != null => 'Add project',
    _ when widget.location != null => 'Clone to ${widget.location!.machine.name}',
    _ => switch (projectLocation(_controller.state)?.source) {
      ProjectSource.folder => 'Add project', ProjectSource.create => 'Create project', _ => 'Clone',
    },
  };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.machines, widget.session]),
    builder: (context, _) {
      final state = _controller.state;
      final location = projectLocation(state);
      final machine = switch (state) {
        ProjectSources(:final machine) || ProjectRepository(:final machine) => machine,
        _ => location?.machine,
      };
      final placeholder = switch (state) {
        ProjectMachines() => 'Choose a machine…',
        ProjectSources() => 'Add project…',
        ProjectRepository(:final source) => source == ProjectSource.github ? 'Enter owner/repository or GitHub URL…' : 'Enter Git repository URL…',
        _ => location?.source == ProjectSource.folder ? 'Folder on ${machine?.name}…' : 'Choose a destination folder…',
      };
      final choices = _choices;
      final active = _activeIndex(choices);
      final mac = defaultTargetPlatform == TargetPlatform.macOS;
      final canSubmit = state is ProjectRepository || state is ProjectLocation || state is ProjectSaveFailed;
      return PopScope(canPop: !_controller.busy, child: CallbackShortcuts(bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _close,
        SingleActivator(LogicalKeyboardKey.enter, meta: mac, control: !mac): _submit,
      }, child: Dialog(
        key: const ValueKey('add-project-dialog'), alignment: Alignment.topCenter,
        insetPadding: EdgeInsets.fromLTRB(16, (MediaQuery.sizeOf(context).height * .1).clamp(48.0, double.infinity), 16, 24),
        backgroundColor: Colors.white, surfaceTintColor: Colors.transparent,
        elevation: 16, shadowColor: const Color(0x33000000),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: desktopBorder, width: .5)),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(width: 576, child: ConstrainedBox(constraints: BoxConstraints(maxHeight: widget.location == null ? 420 : 500),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (widget.location != null) Padding(padding: const EdgeInsets.fromLTRB(16, 14, 8, 0),
              child: Row(children: [
                const Icon(Icons.download_outlined, size: 16, color: desktopSecondary), const SizedBox(width: 8),
                const Expanded(child: Text('Add to another machine', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500))),
                IconButton(tooltip: _controller.busy ? 'Cancel clone' : 'Close', onPressed: _close,
                  icon: const Icon(Icons.close, size: 16), constraints: const BoxConstraints.tightFor(width: 28, height: 28), padding: EdgeInsets.zero),
              ])),
            if (widget.location != null) Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 2), child: Text(
              'Destination folder on ${widget.location!.machine.name}', style: const TextStyle(fontSize: 12, color: desktopSecondary))),
            Padding(padding: const EdgeInsets.all(6), child: Row(children: [
              if (widget.location == null || !_atStart) IconButton(tooltip: _atStart ? 'Close' : 'Back',
                onPressed: _controller.busy ? null : _atStart ? _close : () => _navigate(_controller.back),
                icon: const Icon(Icons.arrow_back, size: 16, color: desktopSecondary),
                constraints: const BoxConstraints.tightFor(width: 32, height: 32), padding: EdgeInsets.zero)
              else const SizedBox(width: 10),
              Expanded(child: TextField(key: const ValueKey('add-project-input'), controller: _input,
                focusNode: _focus, autofocus: true,
                readOnly: _controller.busy || state is ProjectSaveFailed && state.preparedPath != null,
                style: TextStyle(fontSize: 13, height: 20 / 13, color: desktopForeground,
                  fontFamily: location == null ? null : desktopMonoFamily),
                decoration: InputDecoration(hintText: placeholder, hintStyle: const TextStyle(color: desktopTertiary),
                  contentPadding: const EdgeInsets.symmetric(vertical: 10)),
                onChanged: _edited)),
              if (canSubmit) Padding(padding: const EdgeInsets.only(left: 6), child: OutlinedButton(
                key: const ValueKey('add-project-submit'), onPressed: _input.text.trim().isEmpty ? null : _submit,
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 28), textStyle: const TextStyle(fontSize: 11)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [Text(_submitLabel), const SizedBox(width: 6),
                  _KeyHint(state is ProjectRepository ? '↵' : mac ? '⌘ ↵' : 'Ctrl ↵')]))),
              if (!canSubmit) const _KeyHint('esc'),
              const SizedBox(width: 6),
            ])),
            const Divider(height: 1, thickness: .5, color: desktopBorder),
            if (machine != null) Padding(padding: const EdgeInsets.fromLTRB(16, 10, 16, 2), child: Row(children: [
              MachineGlyph(widget.machines?.iconFor(machine.alias) ?? MachineIcon.laptop, size: 13, color: desktopSecondary),
              const SizedBox(width: 6), Expanded(child: Text(machine.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: desktopSecondary))),
              if (location != null && machine.session.client.sharedFilesystem)
                TextButton.icon(key: const ValueKey('add-project-file-picker'),
                  onPressed: _pickingFolder || _controller.busy || state is ProjectSaveFailed && state.preparedPath != null
                    ? null : () => unawaited(_pickFolder()),
                  style: TextButton.styleFrom(minimumSize: const Size(0, 28), padding: const EdgeInsets.symmetric(horizontal: 8),
                    textStyle: const TextStyle(fontSize: 12)),
                  icon: const Icon(Icons.folder_open_outlined, size: 14),
                  label: Text(_pickingFolder ? 'Choosing…' : 'Choose folder…')),
            ])),
            if (location?.remoteUrl case final url?) Padding(padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
              child: Row(children: [_icon(Icons.link), const SizedBox(width: 8), Expanded(child: Text(url,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: desktopSecondary)))])),
            if (state is ProjectMachines || state is ProjectSources || state is ProjectLocation)
              Padding(padding: const EdgeInsets.fromLTRB(16, 10, 16, 4), child: Text(
                state is ProjectMachines ? 'Machines' : state is ProjectSources ? 'Sources' : 'Folders',
                style: const TextStyle(fontSize: 12, color: desktopSecondary))),
            if (choices.isNotEmpty) Flexible(child: ListView.builder(controller: _scroll, shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(6, 0, 6, 6), itemCount: choices.length,
              itemBuilder: (context, index) => _row(choices[index], index == active))),
            if (_controller.busy) Padding(padding: const EdgeInsets.all(16), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 1.5)),
              const SizedBox(width: 10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(state is ProjectSaving ? state.label : 'Cancelling…', style: const TextStyle(fontSize: 13)),
                if (state is ProjectSaving && state.output != null) Padding(padding: const EdgeInsets.only(top: 8),
                  child: Text(state.output!, maxLines: 4, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontFamily: desktopMonoFamily, fontSize: 11, color: desktopSecondary))),
              ])),
            ])),
            if (state is ProjectRepository) const Padding(padding: EdgeInsets.all(16), child: Text(
              'The repository will be cloned on the selected machine using its Git credentials.',
              style: TextStyle(fontSize: 12, color: desktopSecondary))),
            if (state is ProjectLocation && _controller.folders is ProjectFoldersLoading)
              const Padding(padding: EdgeInsets.all(16), child: Text('Loading folders…', style: TextStyle(fontSize: 12, color: desktopSecondary))),
            if (_controller.folders case ProjectFoldersFailed(:final message) when state is ProjectLocation)
              Padding(padding: const EdgeInsets.all(16), child: Row(children: [
                Expanded(child: Text(message, style: const TextStyle(fontSize: 12, color: desktopSecondary))),
                const SizedBox(width: 8), TextButton(onPressed: _browse, child: const Text('Retry')),
              ])),
            if (_controller.folders case ProjectFoldersReady(:final result) when state is ProjectLocation) ...[
              if ((result['folders'] as List).isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(
                location?.source == ProjectSource.folder ? 'No matching folders. Enter a folder path to add it.' : 'A new folder will be created at this path.',
                style: const TextStyle(fontSize: 12, color: desktopSecondary))),
              if (result['truncated'] == true) const Padding(padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Text('Showing 200 folders. Type a path to narrow the list.', style: TextStyle(fontSize: 11, color: desktopTertiary))),
            ],
            if (state is ProjectSaveFailed || _inputError != null) Padding(padding: const EdgeInsets.all(16),
              child: Text(_inputError ?? (state as ProjectSaveFailed).message,
                style: const TextStyle(fontSize: 12, color: desktopError))),
            if (choices.isEmpty && (state is ProjectMachines || state is ProjectSources))
              const Padding(padding: EdgeInsets.all(24), child: Text('No matches.', style: TextStyle(fontSize: 13, color: desktopSecondary))),
            const Divider(height: 1, thickness: .5, color: desktopBorder),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9), child: Row(children: [
              const _KeyHint('↑ ↓'), const SizedBox(width: 6),
              const Text('Navigate', style: TextStyle(fontSize: 11, color: desktopTertiary)),
              const SizedBox(width: 14), const _KeyHint('↵'), const SizedBox(width: 6),
              Text(state is ProjectLocation ? 'Browse' : 'Select', style: const TextStyle(fontSize: 11, color: desktopTertiary)),
              const Spacer(), const _KeyHint('esc'), const SizedBox(width: 6),
              Text(_controller.busy ? 'Cancel' : 'Close', style: const TextStyle(fontSize: 11, color: desktopTertiary)),
            ])),
          ]))),
      )));
    },
  );

  Widget _row(_Choice choice, bool selected) => Padding(padding: const EdgeInsets.symmetric(vertical: 1),
    child: Material(color: selected ? desktopHover : Colors.transparent, borderRadius: BorderRadius.circular(6),
      child: InkWell(key: ValueKey('add-project:${choice.id}'), onTap: choice.select,
        canRequestFocus: false, borderRadius: BorderRadius.circular(6),
        onHover: (hover) { if (hover && choice.select != null && _selected != choice.id) setState(() => _selected = choice.id); },
        child: Opacity(opacity: choice.select == null ? .45 : 1, child: SizedBox(height: 46,
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Row(children: [
            choice.icon, const SizedBox(width: 8), Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(choice.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, height: 18 / 13, color: desktopForeground)),
                Text(choice.description, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, height: 16 / 12, color: desktopTertiary)),
              ])),
            if (choice.select != null) const Icon(Icons.chevron_right, size: 14, color: desktopTertiary),
          ]))),
        )),
    ));
}

class _KeyHint extends StatelessWidget {
  const _KeyHint(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Container(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
    decoration: BoxDecoration(border: Border.all(color: desktopBorder, width: .5), borderRadius: BorderRadius.circular(4)),
    child: Text(label, style: const TextStyle(fontSize: 10, height: 1, color: desktopTertiary)));
}
