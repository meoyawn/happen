import 'package:flutter/material.dart';

class RemoteProjectDialog extends StatefulWidget {
  const RemoteProjectDialog({super.key});

  @override
  State<RemoteProjectDialog> createState() => _RemoteProjectDialogState();
}

class _RemoteProjectDialogState extends State<RemoteProjectDialog> {
  final _path = TextEditingController(text: '~/workspace');

  @override
  void dispose() {
    // The dialog remains mounted during its closing animation after pop returns.
    _path.dispose();
    super.dispose();
  }

  void _open() => Navigator.pop(context, _path.text.trim());

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Open remote project'),
    content: SizedBox(width: 440, child: TextField(controller: _path, autofocus: true,
      decoration: const InputDecoration(labelText: 'Folder on the remote machine'),
      onSubmitted: (_) => _open())),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: _open, child: const Text('Open')),
    ],
  );
}
