import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:protocol/protocol.dart';

import 'appearance.dart';
import 'conversation_markdown.dart';
import 'session.dart';
import 'session_export.dart';

/// Port of OpenCode's gui-plugins/context/tab.tsx. Reads the same message model
/// as the transcript, including hidden system and synthetic messages.
class SessionContextWindow extends StatefulWidget {
  const SessionContextWindow({super.key, required this.session, required this.task, this.downloadsDirectory});
  final DesktopSession session;
  final DesktopTask task;
  final Directory? downloadsDirectory;

  @override
  State<SessionContextWindow> createState() => _SessionContextWindowState();
}

class _SessionContextWindowState extends State<SessionContextWindow> {
  final _lifetime = CancellationToken();
  Json? _snapshot;
  String? _error;
  bool _exporting = false;
  bool _loading = false, _loadingEarlier = false;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_changed);
    unawaited(_load());
  }

  void _changed() {
    if (!_loading && !widget.task.running && _snapshot != null && widget.task.through > (_snapshot!['through'] as int)) unawaited(_load());
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    setState(() => _error = null);
    try {
      final snapshot = await widget.session.client.sessionRead('session.context', {
        'sessionID': widget.task.id,
      }, cancellation: _lifetime);
      if (mounted) setState(() => _snapshot = snapshot);
    } on CancelledException { /* Closing the panel cancels its reads. */ }
    catch (error) { if (mounted) setState(() => _error = error.toString()); }
    finally { _loading = false; }
  }

  Future<void> _earlier() async {
    if (_loadingEarlier || _snapshot?['cursor']?['next'] == null) return;
    setState(() => _loadingEarlier = true);
    try {
      final page = await widget.session.client.sessionRead('session.context', {
        'sessionID': widget.task.id, 'cursor': _snapshot!['cursor']['next'],
      }, cancellation: _lifetime);
      if (mounted) {
        setState(() {
          _snapshot = {..._snapshot!, 'data': [...page['data'] as List, ..._snapshot!['data'] as List], 'cursor': page['cursor']};
        });
      }
    } on CancelledException { /* Closing the panel owns this read. */ }
    catch (error) { if (mounted) setState(() => _error = error.toString()); }
    finally { if (mounted) setState(() => _loadingEarlier = false); }
  }

  Future<void> _export() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final messages = <Json>[];
      String? before;
      do {
        final page = await widget.session.client.sessionRead('session.message.list', {
          'sessionID': widget.task.id, 'limit': 200, 'cursor': ?before,
        }, cancellation: _lifetime);
        messages.insertAll(0, (page['data'] as List).map(jsonObject));
        before = page['cursor']?['next'] as String?;
      } while (before != null);
      _lifetime.throwIfCancelled();
      // Messages are the canonical bodies. Context adds accounting and a
      // reference to its base prompt, rather than embedding those bodies again.
      final contextMetadata = _snapshot == null ? null : ({..._snapshot!}
        ..remove('data')..remove('system')..remove('systemMessage')..remove('cursor'));
      final file = await saveSessionExport({
        'info': {'id': widget.task.id, 'title': widget.task.title},
        'messages': messages, 'context': contextMetadata == null ? null : {
          ...contextMetadata,
          if (_snapshot!['systemMessage'] != null) 'systemMessageID': _snapshot!['systemMessage']['id'],
        },
      }, downloadsDirectory: widget.downloadsDirectory, cancellation: _lifetime);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved to ${file.path}')));
    } on CancelledException { /* The caller owns the export lifetime. */ }
    catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not export session: $error')));
    }
    finally { if (mounted) setState(() => _exporting = false); }
  }

  @override
  void dispose() { widget.session.removeListener(_changed); _lifetime.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Material(color: Colors.white, child: _error != null
      ? Center(child: Padding(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, children: [
          SelectableText(_error!), TextButton(onPressed: _load, child: const Text('Retry')),
        ])))
      : _snapshot == null ? const Center(child: CircularProgressIndicator(strokeWidth: 1.5))
      : ListenableBuilder(listenable: widget.session, builder: (context, _) => _content()));

  Widget _content() {
    final snapshot = _snapshot!;
    final byID = {for (final raw in snapshot['data'] as List) raw['id'] as String: jsonObject(raw),
      if (snapshot['systemMessage'] != null) snapshot['systemMessage']['id'] as String: jsonObject(snapshot['systemMessage']),
      ...widget.task.messages};
    final all = byID.values.toList()..sort((a, b) =>
      (a['metadata']?['seq'] as int? ?? 0).compareTo(b['metadata']?['seq'] as int? ?? 0));
    final compaction = all.where((item) => item['type'] == 'compaction' && item['status'] == 'completed')
      .fold<int>(snapshot['compaction'] as int? ?? 0, (seq, item) =>
        (item['metadata']['seq'] as int) > seq ? item['metadata']['seq'] as int : seq);
    final messages = all.where((item) => (item['metadata']?['seq'] as int? ?? 0) > compaction).toList();
    final latest = lastAssistantWithUsage(messages);
    final tokens = latest?['tokens'] as Json?;
    final total = tokens == null ? null : sessionTokenTotal(tokens);
    final limit = snapshot['limit'] as num?;
    final used = total == null || limit == null || limit == 0 ? null : total / limit;
    final model = latest?['model'] ?? snapshot['model'];
    final providers = widget.session.providers.where((provider) => provider['id'] == model?['providerID']);
    final provider = providers.firstOrNull;
    final modelInfo = (provider?['models'] as List? ?? []).where((item) => item['id'] == model?['id']).firstOrNull;
    final system = all.where((item) => item['type'] == 'system').lastOrNull?['text'] as String? ?? snapshot['system'] as String? ?? '';
    final counts = {...jsonObject(snapshot['counts'] ?? {})};
    for (final message in all.where((item) => (item['metadata']?['seq'] as int? ?? 0) > (snapshot['through'] as int))) {
      counts[message['type'] as String] = (counts[message['type']] as int? ?? 0) + 1;
    }
    String number(Object? value) => value is num ? value.round().toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]},') : '—';
    String time(Object? value) => value is int ? DateTime.fromMillisecondsSinceEpoch(value).toLocal().toString().split('.').first : '—';
    final stats = <(String, String)>[
      ('Session', widget.task.title),
      ('Messages', number(counts.values.whereType<num>().fold<num>(0, (a, b) => a + b))),
      ('Provider', provider?['name'] as String? ?? model?['providerID'] as String? ?? '—'),
      ('Model', modelInfo?['name'] as String? ?? model?['id'] as String? ?? '—'),
      ('Context Limit', number(limit)), ('Total Tokens', number(total)),
      ('Usage', used == null ? '—' : '${(used * 100).round()}%'),
      ('Input Tokens', number(tokens?['input'])), ('Output Tokens', number(tokens?['output'])),
      ('Reasoning Tokens', number(tokens?['reasoning'])),
      ('Cache Tokens (read/write)', '${number(tokens?['cache']?['read'])} / ${number(tokens?['cache']?['write'])}'),
      ('User Messages', number(counts['user'])), ('Assistant Messages', number(counts['assistant'])),
      ('Session Created', time(snapshot['created'])), ('Last Activity', time(snapshot['updated'])),
    ];
    return ListView(key: PageStorageKey('context:${widget.task.id}'), padding: const EdgeInsets.fromLTRB(24, 16, 24, 40), children: [
      Row(children: [
        const Expanded(child: Text('Context usage', style: TextStyle(fontSize: 12, color: opencodeMuted))),
        IconButton(tooltip: 'Refresh context', onPressed: _load, icon: const Icon(Icons.refresh_rounded, size: 16)),
      ]),
      LayoutBuilder(builder: (context, bounds) => Wrap(spacing: 16, runSpacing: 16, children: [for (final (label, value) in stats)
        SizedBox(width: bounds.maxWidth >= 464 ? (bounds.maxWidth - 16) / 2 : bounds.maxWidth,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(fontSize: 12, color: opencodeFaint)),
          const SizedBox(height: 4), SelectableText(value, style: const TextStyle(fontSize: 12, color: opencodeInk)),
        ])),
      ])),
      if (used != null) Padding(padding: const EdgeInsets.only(top: 20), child: LinearProgressIndicator(
        value: used.clamp(0, 1).toDouble(), minHeight: 3, color: opencodeMuted, backgroundColor: opencodeLayer)),
      const SizedBox(height: 28),
      if (system.isNotEmpty) ...[
        Row(children: [const Expanded(child: Text('System Prompt', style: TextStyle(fontSize: 12, color: opencodeMuted))),
          ConversationCopyButton(text: system, label: 'Copy system prompt', compact: true)]),
        const SizedBox(height: 8),
        Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: const Color(0xfffafafa),
          border: Border.all(color: opencodeBorder, width: .5), borderRadius: BorderRadius.circular(6)),
          child: ConversationMarkdown(text: system, fontSize: 12, directory: widget.session.project?.path ?? '')),
        const SizedBox(height: 28),
      ],
      _raw('Tools', snapshot['tools'] ?? []),
      _raw('Model settings', snapshot['settings'] ?? {}),
      const SizedBox(height: 20),
      Row(children: [const Expanded(child: Text('Raw messages', style: TextStyle(fontSize: 12, color: opencodeMuted))),
        TextButton.icon(onPressed: _exporting ? null : _export, icon: const Icon(Icons.download_rounded, size: 14),
          label: Text(_exporting ? 'Exporting…' : 'Export session JSON', style: const TextStyle(fontSize: 12)))]),
      if (snapshot['cursor']?['next'] != null) TextButton(onPressed: _loadingEarlier ? null : _earlier,
        child: Text(_loadingEarlier ? 'Loading…' : 'Load earlier context messages')),
      for (final message in messages) _raw('${message['type']} • ${message['id']}', message),
    ]);
  }

  Widget _raw(String title, Object value) => ExpansionTile(
    key: PageStorageKey('context-raw:${widget.task.id}:$title'),
    shape: const Border(), collapsedShape: const Border(), tilePadding: EdgeInsets.zero,
    title: Text(title, style: const TextStyle(fontSize: 12, color: opencodeMuted), maxLines: 1, overflow: TextOverflow.ellipsis),
    children: [_ContextJson(value: value)],
  );
}

class _ContextJson extends StatelessWidget {
  const _ContextJson({required this.value});
  final Object value;
  @override
  Widget build(BuildContext context) => ConversationCode(
    source: const JsonEncoder.withIndent('  ').convert(value), language: 'json');
}
