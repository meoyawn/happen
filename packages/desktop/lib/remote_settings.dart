import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:protocol/protocol.dart';

import 'appearance.dart';
import 'machines.dart';

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

  Future<void> _edit([RemoteMachine? remote]) => showDialog<void>(context: context,
    builder: (_) => _RemoteEditor(machines: widget.machines, remote: remote));

  Future<void> _remove(RemoteMachine remote) async {
    try { await widget.machines.removeRemote(remote.alias, cancellation: _lifetime); }
    on CancelledException { /* Leaving Settings cancels the pending request. */ }
    catch (error) { if (mounted) widget.machines.local.showError(error, title: 'Could not remove server'); }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.machines, builder: (context, _) {
    final machines = widget.machines;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        const Expanded(child: Text('Threads from all connected servers appear in one sidebar.',
          style: TextStyle(fontSize: 13, color: desktopSecondary))),
        const SizedBox(width: 16),
        FilledButton.icon(onPressed: machines.saving ? null : () => unawaited(_edit()),
          icon: const Icon(Icons.add, size: 16), label: const Text('Connect server')),
      ]),
      const SizedBox(height: 20),
      const ListTile(contentPadding: EdgeInsets.symmetric(horizontal: 12),
        leading: Icon(Icons.computer_outlined, size: 20), title: Text('Local machine'),
        subtitle: Text('Threads are stored on this computer'), trailing: Text('Connected')),
      for (final remote in machines.hosts) ...[
        const Divider(height: 1),
        Builder(builder: (context) {
          final state = machines.state(remote.alias);
          final connected = state is MachineReady && state.session.connected;
          final status = state is MachineConnecting ? 'Connecting…' : connected ? 'Connected'
            : state is MachineFailed ? 'Connection failed' : 'Disconnected';
          return ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            leading: const Icon(Icons.dns_outlined, size: 20),
            title: Text(remote.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
            subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${remote.user == null ? '' : '${remote.user}@'}${remote.host}${remote.port == null ? '' : ':${remote.port}'}',
                style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 4),
              Text(status, style: TextStyle(fontSize: 12, color: state is MachineFailed ? desktopError : desktopSecondary)),
              if (state is MachineFailed) Padding(padding: const EdgeInsets.only(top: 4),
                child: SelectableText('${state.error}', style: const TextStyle(fontSize: 11, color: desktopError))),
            ]),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (state is MachineConnecting)
                TextButton(onPressed: () => machines.cancelConnection(remote.alias), child: const Text('Cancel'))
              else if (!connected)
                TextButton(onPressed: () => unawaited(machines.connect(remote)), child: const Text('Connect')),
              PopupMenuButton<String>(tooltip: 'Server settings', enabled: !machines.saving,
                onSelected: (value) {
                  if (value == 'edit') { unawaited(_edit(remote)); }
                  else { unawaited(_remove(remote)); }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit connection')),
                  PopupMenuItem(value: 'remove', child: Text('Remove connection')),
                ]),
            ]));
        }),
      ],
      if (machines.discoveryError != null) Padding(padding: const EdgeInsets.only(top: 16),
        child: Text('Could not load server settings: ${machines.discoveryError}', style: const TextStyle(color: desktopError))),
      const SizedBox(height: 24),
      const Text('Connections use your SSH config and SSH agent. The Happen server must be installed on the remote machine.',
        style: TextStyle(fontSize: 12, height: 1.5, color: desktopSecondary)),
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
    title: Text(widget.remote == null ? 'Connect SSH server' : 'Edit SSH server'),
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
