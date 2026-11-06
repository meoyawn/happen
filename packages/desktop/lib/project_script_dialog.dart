import 'package:flutter/material.dart';
import 'package:protocol/protocol.dart';

import 'appearance.dart';
import 'project_actions_state.dart';

class ProjectScriptDialog extends StatefulWidget {
  const ProjectScriptDialog({super.key, required this.controller, this.script});
  final ProjectActionsController controller;
  final ProjectScript? script;
  @override
  State<ProjectScriptDialog> createState() => _ProjectScriptDialogState();
}

class _ProjectScriptDialogState extends State<ProjectScriptDialog> {
  final _lifetime = CancellationToken();
  late final _name = TextEditingController(text: widget.script?.name);
  late final _command = TextEditingController(text: widget.script?.command);
  final _form = GlobalKey<FormState>();
  String? _error;
  @override
  void dispose() { _lifetime.cancel(); _name.dispose(); _command.dispose(); super.dispose(); }

  Future<void> _save({bool remove = false}) async {
    if (!remove && !_form.currentState!.validate()) return;
    final value = widget.controller.state.value;
    final scripts = [for (final script in value.scripts) if (script.id != widget.script?.id) script];
    if (!remove) {
      final script = (id: widget.script?.id ?? newId(), name: _name.text.trim(), command: _command.text.trim());
      final index = widget.script == null ? scripts.length : value.scripts.indexWhere((item) => item.id == widget.script!.id);
      scripts.insert(index.clamp(0, scripts.length), script);
    }
    try {
      await widget.controller.save((opener: value.opener, scripts: scripts), _lifetime);
      if (mounted) Navigator.pop(context);
    } on CancelledException { /* The dialog or session closed. */ }
    catch (error) { if (mounted) setState(() => _error = error.toString()); }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.controller, builder: (context, _) {
    final saving = widget.controller.state is ProjectActionsSaving;
    return Dialog(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: SizedBox(width: 460, child: SingleChildScrollView(padding: const EdgeInsets.all(24),
        child: Form(key: _form, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(widget.script == null ? 'Add project script' : 'Edit project script',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text('Run a saved command in its own project terminal.', style: TextStyle(fontSize: 12, color: opencodeMuted)),
          const SizedBox(height: 20),
          TextFormField(controller: _name, autofocus: true, enabled: !saving, maxLength: 80,
            decoration: const InputDecoration(labelText: 'Name', hintText: 'Start dev server'),
            validator: (value) => value == null || value.trim().isEmpty ? 'Enter a script name' : null),
          const SizedBox(height: 12),
          TextFormField(controller: _command, enabled: !saving, minLines: 3, maxLines: 6, maxLength: 10000,
            style: const TextStyle(fontFamily: 'IBM Plex Mono', fontSize: 12),
            decoration: const InputDecoration(labelText: 'Command', hintText: 'moonx dev'),
            validator: (value) => value == null || value.trim().isEmpty ? 'Enter a command'
              : value.contains('\u0000') ? 'The command contains an invalid character' : null),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 12),
            child: Text(_error!, style: const TextStyle(fontSize: 12, color: Color(0xffc23838)))),
          const SizedBox(height: 24),
          Row(children: [
            if (widget.script != null) TextButton(onPressed: saving ? null : () => _save(remove: true),
              style: TextButton.styleFrom(foregroundColor: const Color(0xffc23838)), child: const Text('Delete script')),
            const Spacer(),
            TextButton(onPressed: saving ? null : () => Navigator.pop(context), child: const Text('Cancel')),
            const SizedBox(width: 8),
            FilledButton(onPressed: saving ? null : _save, child: Text(saving ? 'Saving…' : 'Save script')),
          ]),
        ])))));
  });
}
