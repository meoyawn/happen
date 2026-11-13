import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:protocol/protocol.dart';

import 'appearance.dart';
import 'desktop_menu.dart';
import 'machines.dart';
import 'machine_icons.dart';

Future<void> showRemoteEditor(BuildContext context, MachinesController machines, {RemoteMachine? remote}) =>
  showDialog<void>(context: context, builder: (_) => _RemoteEditor(machines: machines, remote: remote));

class RemoteSettings extends StatefulWidget {
  const RemoteSettings({super.key, required this.machines});
  final MachinesController machines;
  @override
  State<RemoteSettings> createState() => _RemoteSettingsState();
}

class _RemoteSettingsState extends State<RemoteSettings> {
  final _lifetime = CancellationToken();
  @override
  void dispose() { _lifetime.cancel(); super.dispose(); }

  Future<void> _edit([RemoteMachine? remote]) => showRemoteEditor(context, widget.machines, remote: remote);

  Future<void> _remove(RemoteMachine remote) async {
    try { await widget.machines.removeRemote(remote.alias, cancellation: _lifetime); }
    on CancelledException { /* Leaving Settings cancels the pending request. */ }
    catch (error) { if (mounted) widget.machines.local.showError(error, title: 'Could not remove server'); }
  }

  Future<void> _chooseIcon(String? alias, MachineIcon icon) async {
    try { await widget.machines.chooseIcon(alias, icon, cancellation: _lifetime); }
    on CancelledException { /* Leaving Settings owns cancellation. */ }
    catch (error) { if (mounted) widget.machines.local.showError(error, title: 'Could not save machine icon'); }
  }

  Widget _environmentMenu(String? alias, String name, RemoteMachine? remote) => DesktopMenuAnchor(
    style: MenuStyle(padding: const WidgetStatePropertyAll(EdgeInsets.all(4)),
      backgroundColor: const WidgetStatePropertyAll(Colors.white),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: desktopBorder)))),
    menuChildren: [
      SubmenuButton(leadingIcon: MachineGlyph(widget.machines.iconFor(alias), size: 16),
        menuChildren: [for (final icon in MachineIcon.values) MenuItemButton(
          leadingIcon: MachineGlyph(icon, size: 16),
          trailingIcon: widget.machines.iconFor(alias) == icon ? const Icon(Icons.check, size: 14) : null,
          onPressed: widget.machines.saving ? null : () => unawaited(_chooseIcon(alias, icon)),
          child: Text(machineIconLabel(icon)))], child: const Text('Icon')),
      if (remote != null) ...[
        MenuItemButton(leadingIcon: const Icon(Icons.edit_outlined, size: 16),
          onPressed: widget.machines.saving ? null : () => unawaited(_edit(remote)), child: const Text('Edit connection')),
        if (widget.machines.state(remote.alias) is MachineFailed)
          MenuItemButton(leadingIcon: const Icon(Icons.refresh, size: 16),
            onPressed: () => unawaited(widget.machines.connect(remote)), child: const Text('Retry now')),
        const Divider(height: 9),
        MenuItemButton(leadingIcon: const Icon(Icons.delete_outline, size: 16, color: desktopError),
          onPressed: widget.machines.saving ? null : () => unawaited(_remove(remote)),
          child: const Text('Remove environment', style: TextStyle(color: desktopError))),
      ],
    ],
    builder: (_, controller, focus) => IconButton(tooltip: 'Environment settings for $name', focusNode: focus,
      onPressed: widget.machines.saving ? null : () => controller.isOpen ? controller.close() : controller.open(),
      padding: EdgeInsets.zero, constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      icon: const Icon(Icons.more_horiz, size: 18, color: desktopSecondary)),
  );

  Widget _environmentRow({required String? alias, required String name, required String transport,
    required String status, required bool connected, String? error, RemoteMachine? remote}) =>
    Padding(key: ValueKey('environment:${alias ?? 'local'}'), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(children: [
        MachineGlyph(widget.machines.iconFor(alias), size: 18, color: desktopSecondary), const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, height: 20 / 13, fontWeight: FontWeight.w500, color: desktopForeground)),
          const SizedBox(height: 2),
          Tooltip(message: error ?? status, child: Row(children: [
            SizedBox.square(dimension: 6, child: DecoratedBox(decoration: BoxDecoration(shape: BoxShape.circle,
              color: connected ? const Color(0xff35805a) : const Color(0xffb68128)))),
            const SizedBox(width: 6),
            Text(status, style: const TextStyle(fontSize: 12, height: 18 / 12, color: desktopSecondary)),
            const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: Text('·', style: TextStyle(color: desktopTertiary))),
            Flexible(child: Text(transport, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, height: 18 / 12, color: desktopTertiary))),
          ])),
        ])),
        const SizedBox(width: 12), _environmentMenu(alias, name, remote),
      ]));

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.machines, builder: (context, _) {
    final machines = widget.machines;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        const Expanded(child: Text('Threads from all environments appear in one sidebar.',
          style: TextStyle(fontSize: 13, color: desktopSecondary))),
        const SizedBox(width: 16),
        FilledButton.icon(onPressed: machines.saving ? null : () => unawaited(_edit()),
          icon: const Icon(Icons.add, size: 16), label: const Text('Add environment')),
      ]),
      const SizedBox(height: 20),
      DecoratedBox(decoration: BoxDecoration(border: Border.all(color: desktopBorder), borderRadius: BorderRadius.circular(10)),
        child: Column(children: [
          _environmentRow(alias: null, name: 'local', transport: 'This computer',
            status: machines.local.connected ? 'Connected' : 'Offline', connected: machines.local.connected),
          for (final remote in machines.hosts) ...[
            const Divider(height: 1),
            Builder(builder: (_) {
              final state = machines.state(remote.alias);
              final connected = state is MachineReady && state.session.connected;
              final status = connected ? 'Connected' : switch (state) {
                MachineConnecting(previous: null) || null => 'Connecting', _ => 'Reconnecting',
              };
              return _environmentRow(alias: remote.alias, name: remote.name, remote: remote,
                transport: 'SSH ${remote.user == null ? '' : '${remote.user}@'}${remote.host}${remote.port == null ? '' : ':${remote.port}'}',
                status: status, connected: connected, error: state is MachineFailed ? '${state.error}' : null);
            }),
          ],
        ])),
      if (machines.discoveryError != null) Padding(padding: const EdgeInsets.only(top: 16),
        child: Text('Could not load environments: ${machines.discoveryError}', style: const TextStyle(color: desktopError))),
    ]);
  });
}

class _RemoteEditor extends StatefulWidget {
  const _RemoteEditor({required this.machines, this.remote});
  final MachinesController machines;
  final RemoteMachine? remote;
  @override
  State<_RemoteEditor> createState() => _RemoteEditorState();
}

class _RemoteEditorState extends State<_RemoteEditor> {
  final _lifetime = CancellationToken();
  late final _alias = widget.remote?.alias ?? 'remote-${newId()}';
  late final _name = TextEditingController(text: widget.remote?.name ?? '');
  late final _host = TextEditingController(text: widget.remote?.host ?? '');
  late final _user = TextEditingController(text: widget.remote?.user ?? '');
  late final _port = TextEditingController(text: widget.remote?.port?.toString() ?? '');
  late final _identity = TextEditingController(text: widget.remote?.identityFile ?? '');
  late final _projects = TextEditingController(text: widget.remote?.projects.join('\n') ?? '');
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _lifetime.cancel();
    for (final controller in [_name, _host, _user, _port, _identity, _projects]) { controller.dispose(); }
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() { _saving = true; _error = null; });
    try {
      final port = _port.text.trim().isEmpty ? null : int.tryParse(_port.text.trim());
      if (_port.text.trim().isNotEmpty && port == null) throw const FormatException('Enter a valid SSH port');
      await widget.machines.saveRemote(_alias, {
        'name': _name.text, 'host': _host.text, 'user': _user.text, 'port': port,
        'identityFile': _identity.text, 'projects': const LineSplitter().convert(_projects.text),
      }, cancellation: _lifetime);
      if (mounted) Navigator.pop(context);
    } on CancelledException { /* Closing the form owns cancellation. */ }
    catch (error) { if (mounted) setState(() => _error = '$error'); }
    finally { if (mounted) setState(() => _saving = false); }
  }

  Widget _field(String label, TextEditingController controller, {String? hint, int lines = 1}) => Padding(
    padding: const EdgeInsets.only(bottom: 14), child: TextField(controller: controller,
      enabled: !_saving, maxLines: lines, style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(labelText: label, hintText: hint, border: const OutlineInputBorder(),
        isDense: true)));

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.remote == null ? 'Add SSH environment' : 'Edit SSH environment'),
    content: SizedBox(width: 480, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _field('Name', _name, hint: 'Development server'),
        _field('Hostname or SSH alias', _host, hint: 'dev.example.com'),
        Row(children: [Expanded(child: _field('User (optional)', _user)), const SizedBox(width: 12),
          SizedBox(width: 110, child: _field('Port (optional)', _port, hint: '22'))]),
        _field('SSH key path (optional)', _identity, hint: '~/.ssh/id_ed25519'),
        const Text('Leave user, port and key blank to inherit your SSH configuration and agent.',
          style: TextStyle(fontSize: 12, height: 1.5, color: desktopSecondary)),
        const SizedBox(height: 18),
        _field('Workspace directories (optional, one per line)', _projects, hint: '/home/dev/workspace', lines: 3),
        if (_error != null) SelectableText(_error!, style: const TextStyle(fontSize: 12, color: desktopError)),
      ]))),
    actions: [TextButton(onPressed: () { _lifetime.cancel(); Navigator.pop(context); }, child: const Text('Cancel')),
      FilledButton(onPressed: _saving ? null : () => unawaited(_save()),
        child: Text(_saving ? 'Saving…' : widget.remote == null ? 'Save & connect' : 'Save'))],
  );
}
