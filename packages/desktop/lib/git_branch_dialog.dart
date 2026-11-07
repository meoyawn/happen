import 'package:flutter/material.dart';
import 'package:protocol/protocol.dart';

import 'appearance.dart';
import 'git_actions_state.dart';

typedef BranchSelection = ({String branch, bool create});

class GitBranchDialog extends StatefulWidget {
  const GitBranchDialog({super.key, required this.controller});
  final GitActionsController controller;
  @override
  State<GitBranchDialog> createState() => _GitBranchDialogState();
}

class _GitBranchDialogState extends State<GitBranchDialog> {
  final _lifetime = CancellationToken();
  final _search = TextEditingController(), _name = TextEditingController();
  late Future<List<GitBranch>> _branches;
  @override
  void initState() { super.initState(); _branches = widget.controller.branches(_lifetime); }
  @override
  void dispose() { _lifetime.cancel(); _search.dispose(); _name.dispose(); super.dispose(); }
  void _choose(String branch, {bool create = false}) =>
    Navigator.pop(context, (branch: branch, create: create));

  @override
  Widget build(BuildContext context) => Dialog(
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    child: SizedBox(width: 440, child: Padding(padding: const EdgeInsets.all(20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Expanded(child: Text('Switch branch', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600))),
          IconButton(tooltip: 'Close branch picker', onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close_rounded, size: 18)),
        ]),
        TextField(controller: _search, autofocus: true, onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(hintText: 'Search branches', prefixIcon: Icon(Icons.search_rounded, size: 18))),
        const SizedBox(height: 12),
        Flexible(child: SizedBox(height: 260, child: FutureBuilder<List<GitBranch>>(future: _branches, builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('${snapshot.error}', style: const TextStyle(fontSize: 12, color: desktopSecondary)),
              TextButton(onPressed: () => setState(() => _branches = widget.controller.branches(_lifetime)), child: const Text('Retry')),
            ]));
          }
          if (!snapshot.hasData) { return const Center(child: CircularProgressIndicator(strokeWidth: 2)); }
          final query = _search.text.toLowerCase();
          final branches = snapshot.data!.where((branch) => branch.name.toLowerCase().contains(query)).toList();
          if (branches.isEmpty) return const Center(child: Text('No matching branches', style: TextStyle(color: desktopSecondary)));
          return ListView.builder(itemCount: branches.length, itemBuilder: (context, index) {
            final branch = branches[index], current = widget.controller.state.repository?.branch == branches[index].name && !branches[index].remote;
            return ListTile(dense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: Icon(branch.remote ? Icons.cloud_outlined : Icons.call_split_rounded, size: 17, color: desktopTertiary),
              title: Text(branch.name, style: const TextStyle(fontSize: 13)),
              trailing: current ? const Icon(Icons.check_rounded, size: 17) : null,
              enabled: !current, onTap: () => _choose(branch.ref));
          });
        }))),
        const Divider(height: 24),
        TextField(controller: _name, onChanged: (_) => setState(() {}),
          onSubmitted: (name) { if (name.trim().isNotEmpty) _choose(name.trim(), create: true); },
          decoration: const InputDecoration(labelText: 'New branch name', hintText: 'feature/my-change')),
        const SizedBox(height: 16),
        Align(alignment: Alignment.centerRight, child: FilledButton.icon(
          onPressed: _name.text.trim().isEmpty ? null : () => _choose(_name.text.trim(), create: true),
          icon: const Icon(Icons.add_rounded, size: 16), label: const Text('Create branch'))),
      ]))));
}
