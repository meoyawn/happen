import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart' show readContextSnapshot;

import 'appearance.dart';
import 'code_highlight.dart';
import 'conversation_markdown.dart';
import 'desktop_toast.dart';
import 'inference_request.dart';
import 'session.dart';
import 'session_export.dart';

/// Inspects the inference request built from a frozen agent snapshot.
class SessionContextWindow extends StatefulWidget {
  const SessionContextWindow({super.key, required this.session, required this.task, this.downloadsDirectory, this.onAttached});
  final DesktopSession session;
  final DesktopTask task;
  final Directory? downloadsDirectory;
  final VoidCallback? onAttached;

  @override
  State<SessionContextWindow> createState() => _SessionContextWindowState();
}

class _SessionContextWindowState extends State<SessionContextWindow> {
  final _lifetime = CancellationToken();
  Json? _snapshot;
  String? _error;
  bool _exporting = false;
  bool _loading = false;
  bool _traceLoading = false;
  Map<String, int>? _traceCounts;
  String? _traceError;
  bool _messagesExpanded = true;
  final _expanded = <String>{};

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_changed);
    unawaited(_load());
    unawaited(_loadTraceStatus());
  }

  void _changed() {
    if (!_loading && _snapshot != null && widget.task.through > (_snapshot!['through'] as int)) unawaited(_load());
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    final through = widget.task.through;
    setState(() => _error = null);
    try {
      final snapshot = await readContextSnapshot(widget.session.client, widget.task.id, cancellation: _lifetime);
      if (mounted) setState(() => _snapshot = snapshot);
    } on CancelledException { /* Closing the panel cancels its reads. */ }
    catch (error) { if (mounted) setState(() => _error = error.toString()); }
    finally {
      _loading = false;
      if (mounted) unawaited(_loadTraceStatus());
      if (mounted && widget.task.through > through) _changed();
    }
  }

  Future<void> _loadTraceStatus() async {
    if (_traceLoading || !widget.task.tracing) return;
    _traceLoading = true;
    try {
      final store = await widget.session.tracing;
      final results = await Future.wait([
        widget.session.client.traceStatus(widget.task.id, cancellation: _lifetime),
        store.status(widget.task.id, cancellation: _lifetime),
      ]);
      final counts = <String, int>{};
      for (final result in results) {
        for (final entry in jsonObject(result['categories']).entries) {
          counts[entry.key] = (counts[entry.key] ?? 0) + (entry.value as int);
        }
      }
      if (mounted) setState(() { _traceCounts = counts; _traceError = null; });
    } on CancelledException { /* The panel owns its reads. */ }
    catch (error) { if (mounted) setState(() => _traceError = error.toString()); }
    finally { _traceLoading = false; }
  }

  Future<void> _export({bool trace = false, bool attach = false}) async {
    final snapshot = _snapshot;
    if (_exporting || trace && !widget.task.tracing || !trace && snapshot == null) return;
    setState(() => _exporting = true);
    final destination = attach ? Directory('${widget.session.attachmentDirectory}/${newId()}')
      : widget.downloadsDirectory;
    var attached = false;
    try {
      final file = trace ? await saveSessionTrace(widget.session.client, await widget.session.tracing,
        title: widget.task.title, sessionID: widget.task.id,
        downloadsDirectory: destination, cancellation: _lifetime)
        : await saveSessionExport(inferenceRequest(snapshot!),
          title: '${widget.task.title}-context', sessionID: widget.task.id,
          downloadsDirectory: destination, cancellation: _lifetime);
      if (attach) {
        _lifetime.throwIfCancelled();
        final owner = widget.session.projects.where((project) => project.tasks.contains(widget.task)).firstOrNull;
        widget.session.attachExportToNewSession(file, owner: owner, ownedDirectory: destination!.path);
        attached = true;
        widget.onAttached?.call();
      } else {
        final path = file.absolute.path;
        await Clipboard.setData(ClipboardData(text: path));
        if (mounted) {
          showDesktopToast(context, trace ? 'End-to-end trace exported' : 'LLM context exported',
            description: 'Path copied to clipboard: $path', type: DesktopToastType.success);
        }
      }
    } on CancelledException { /* The caller owns the export lifetime. */ }
    catch (error) {
      if (mounted) {
        showDesktopToast(context, 'Could not export ${trace ? 'session trace' : 'LLM context'}',
          type: DesktopToastType.error, description: '$error');
      }
    }
    finally {
      if (attach && !attached && await destination!.exists()) await destination.delete(recursive: true);
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  void dispose() { widget.session.removeListener(_changed); _lifetime.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Material(color: Colors.white, child: Column(children: [
    _exports(),
    const Divider(height: 1, color: opencodeBorder),
    Expanded(child: _error != null
      ? Center(child: Padding(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, children: [
          SelectableText(_error!), TextButton(onPressed: _load, child: const Text('Retry')),
        ])))
      : _snapshot == null ? const Center(child: CircularProgressIndicator(strokeWidth: 1.5))
      : ListenableBuilder(listenable: widget.session, builder: (context, _) => _content())),
  ]));

  Widget _exports() => Padding(padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _exportRow('LLM context', enabled: _snapshot != null, trace: false),
      _exportRow('End-to-end trace', enabled: widget.task.tracing, trace: true),
      if (!widget.task.tracing) const Padding(padding: EdgeInsets.only(right: 8, bottom: 4),
        child: Text('Tracing was not enabled for this session.',
          style: TextStyle(fontSize: 11, color: opencodeFaint))),
      if (_traceError != null) Padding(padding: const EdgeInsets.only(right: 8, top: 4),
        child: Text(_traceError!, style: const TextStyle(fontSize: 11, color: Colors.red))),
      if (_traceCounts case final counts?) Padding(padding: const EdgeInsets.only(right: 8, bottom: 4),
        child: Text('Events: ${counts['http'] ?? 0} HTTP · ${counts['websocket'] ?? 0} WebSocket · ${counts['sqlite'] ?? 0} SQLite',
          style: const TextStyle(fontSize: 11, color: opencodeFaint))),
    ]));

  Widget _exportRow(String label, {required bool enabled, required bool trace}) => Row(children: [
    Expanded(child: Text(label, style: const TextStyle(fontSize: 12, color: opencodeMuted))),
    if (trace) IconButton(tooltip: 'Refresh session trace counts', visualDensity: VisualDensity.compact,
      onPressed: _traceLoading || !enabled ? null : _loadTraceStatus, icon: const Icon(Icons.refresh, size: 16)),
    Tooltip(message: 'Export $label JSON and copy its absolute path',
      child: TextButton.icon(onPressed: _exporting || !enabled ? null : () => _export(trace: trace),
        style: TextButton.styleFrom(foregroundColor: opencodeMuted, padding: const EdgeInsets.symmetric(horizontal: 6),
          textStyle: const TextStyle(fontSize: 11)),
        icon: const Icon(Icons.file_download_outlined, size: 16),
        label: Text(_exporting ? 'Exporting…' : 'Export & copy path'))),
    IconButton(tooltip: 'Attach $label to new session', visualDensity: VisualDensity.compact,
      onPressed: _exporting || !enabled ? null : () => _export(trace: trace, attach: true),
      icon: const Icon(Icons.add_comment_outlined, size: 16)),
  ]);

  Widget _content() {
    final snapshot = _snapshot!;
    final request = inferenceRequest(snapshot);
    final inputField = request.containsKey('input') ? 'input' : 'messages';
    final input = (request[inputField] as List).map(jsonObject).toList();
    final settings = {...request}..remove(inputField)..remove('tools');
    final tokens = snapshot['tokens'] as Json?;
    final total = tokens == null ? null : sessionTokenTotal(tokens);
    final limit = snapshot['limit'] as num?;
    final used = total == null || limit == null || limit == 0 ? null : total / limit;
    final model = snapshot['model'];
    final providers = widget.session.providers.where((provider) => provider['id'] == model?['providerID']);
    final provider = providers.firstOrNull;
    final modelInfo = (provider?['models'] as List? ?? []).where((item) => item['id'] == model?['id']).firstOrNull;
    final system = (snapshot['instructions'] as String? ?? '').trim();
    final counts = <String, int>{};
    for (final item in input) {
      if (item['role'] case final String role) counts[role] = (counts[role] ?? 0) + 1;
    }
    String number(Object? value) => value is num ? value.round().toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]},') : '—';
    String time(Object? value) {
      if (value is! int || value == 0) return '—';
      final date = DateTime.fromMillisecondsSinceEpoch(value).toLocal();
      final labels = MaterialLocalizations.of(context);
      return '${labels.formatShortDate(date)}, ${labels.formatTimeOfDay(TimeOfDay.fromDateTime(date))}';
    }
    final stats = <(String, String)>[
      ('Session', widget.task.title),
      ('Context items', number(input.length)),
      ('Provider', provider?['name'] as String? ?? model?['providerID'] as String? ?? '—'),
      ('Model', modelInfo?['name'] as String? ?? model?['id'] as String? ?? '—'),
      ('Context Limit', number(limit)), ('Total Tokens', number(total)),
      ('Usage', used == null ? '—' : '${(used * 100).round()}%'),
      ('Input Tokens', number(tokens?['input'])), ('Output Tokens', number(tokens?['output'])),
      ('Reasoning Tokens', number(tokens?['reasoning'])),
      ('Cache Tokens (read/write)', '${number(tokens?['cache']?['read'])} / ${number(tokens?['cache']?['write'])}'),
      ('User Messages', number(counts['user'] ?? 0)), ('Assistant Messages', number(counts['assistant'] ?? 0)),
      ('Session Created', time(snapshot['created'])), ('Last Activity', time(snapshot['updated'])),
    ];
    final desktop = MediaQuery.sizeOf(context).width >= 768;
    final inset = desktop ? 24.0 : 16.0, gap = desktop ? 40.0 : 24.0;
    return LayoutBuilder(builder: (context, bounds) => CustomScrollView(
      key: PageStorageKey('context:${widget.task.id}'), slivers: [
      SliverPadding(padding: EdgeInsets.fromLTRB(inset, 16, inset, gap), sliver: SliverToBoxAdapter(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Wrap(spacing: 16, runSpacing: 16, children: [for (final (label, value) in stats)
            SizedBox(width: bounds.maxWidth >= 512 ? (bounds.maxWidth - inset * 2 - 16) / 2 : bounds.maxWidth - inset * 2,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: const TextStyle(fontSize: 12, height: 4 / 3, color: opencodeFaint)),
                const SizedBox(height: 4), SelectableText(value, style: const TextStyle(
                  fontSize: 12, height: 4 / 3, fontWeight: FontWeight.w500, color: opencodeInk)),
              ])),
          ]),
          if (system.isNotEmpty) ...[
            SizedBox(height: gap),
            ExpansionTile(
              key: PageStorageKey('context-system:${widget.task.id}'),
              shape: const Border(), collapsedShape: const Border(), tilePadding: EdgeInsets.zero,
              minTileHeight: 32, childrenPadding: const EdgeInsets.only(top: 8),
              title: Row(children: [const Expanded(child: Text('System Prompt',
                style: TextStyle(fontSize: 12, color: opencodeFaint))),
                ConversationCopyButton(text: system, label: 'Copy system prompt', compact: true)]),
              children: [Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(color: const Color(0xfffafafa),
                  border: Border.all(color: opencodeBorder), borderRadius: BorderRadius.circular(6)),
                child: ConversationMarkdown(text: system, fontSize: 12, directory: widget.session.project?.path ?? ''))]),
          ],
          SizedBox(height: gap),
          _raw('Tools', request['tools'] as List? ?? <Object?>[]),
          _raw('Model settings', settings),
        ]))),
      SliverPadding(padding: EdgeInsets.fromLTRB(inset, 0, inset, 8), sliver: SliverToBoxAdapter(
        child: Row(children: [Expanded(child: InkWell(
          mouseCursor: WidgetStateMouseCursor.clickable,
          onTap: () => setState(() => _messagesExpanded = !_messagesExpanded),
          child: Semantics(button: true, expanded: _messagesExpanded, child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(children: [const Expanded(child: Text('Raw messages', maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: opencodeFaint))),
              const SizedBox(width: 8), Icon(_messagesExpanded ? Icons.expand_less : Icons.expand_more,
                size: 16, color: opencodeFaint)]))))),
          if (_exporting) const SizedBox.square(dimension: 12,
            child: CircularProgressIndicator(strokeWidth: 1.5))]))),
      if (_messagesExpanded) for (var index = 0; index < input.length; index++)
          SliverPadding(padding: EdgeInsets.symmetric(horizontal: inset), sliver: _message(input[index],
            id: input[index]['id'] as String? ?? '$inputField[$index]',
            label: index == 0 && system.isNotEmpty && {'system', 'developer'}.contains(input[index]['role'])
              ? 'System Prompt' : null,
            first: index == 0, last: index == input.length - 1)),
      SliverToBoxAdapter(child: SizedBox(height: gap)),
    ]));
  }

  Widget _raw(String title, Object value) => ExpansionTile(
    key: PageStorageKey('context-raw:${widget.task.id}:$title'),
    shape: const Border(), collapsedShape: const Border(), tilePadding: EdgeInsets.zero,
    title: Text(title, style: const TextStyle(fontSize: 12, color: opencodeMuted), maxLines: 1, overflow: TextOverflow.ellipsis),
    minTileHeight: 32,
    childrenPadding: const EdgeInsets.all(12),
    // The text's scroll offset must not share the tile's expanded-state key.
    children: [_ContextJson(key: const PageStorageKey('json-selection'), value: value)],
  );

  Widget _message(Json item, {required String id, String? label, required bool first, required bool last}) {
    final expanded = _expanded.contains(id);
    final radius = BorderRadius.vertical(top: first ? const Radius.circular(8) : Radius.zero,
      bottom: last && !expanded ? const Radius.circular(8) : Radius.zero);
    return SliverMainAxisGroup(key: ValueKey(id), slivers: [
      PinnedHeaderSliver(child: SizedBox(height: 32,
        child: Material(color: Colors.white, shape: RoundedRectangleBorder(borderRadius: radius,
          side: const BorderSide(color: opencodeBorder)), clipBehavior: Clip.antiAlias,
          child: InkWell(mouseCursor: WidgetStateMouseCursor.clickable, onTap: () => setState(() {
            if (expanded) { _expanded.remove(id); } else { _expanded.add(id); }
          }), child: Semantics(button: true, expanded: expanded, child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              Expanded(child: Text.rich(TextSpan(children: [
                TextSpan(text: '${item['role'] ?? item['type']} '),
                TextSpan(text: '• ${label == null ? '' : '$label • '}$id', style: const TextStyle(color: opencodeMuted)),
              ]), maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: opencodeInk))),
              const SizedBox(width: 12),
              const Icon(Icons.unfold_more_rounded, size: 16, color: opencodeFaint),
            ]))))))),
      if (expanded) SliverToBoxAdapter(child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.white,
          border: const Border(left: BorderSide(color: opencodeBorder), right: BorderSide(color: opencodeBorder),
            bottom: BorderSide(color: opencodeBorder)),
          borderRadius: last ? const BorderRadius.vertical(bottom: Radius.circular(8)) : null),
        child: _ContextJson(key: PageStorageKey('json-selection:$id'), value: item))),
    ]);
  }
}

class _ContextJson extends StatelessWidget {
  const _ContextJson({super.key, required this.value});
  final Object value;
  @override
  Widget build(BuildContext context) => SelectableText.rich(
    highlightedCode(const JsonEncoder.withIndent('  ').convert(value), language: 'json'),
    style: const TextStyle(fontFamily: 'IBM Plex Mono', fontSize: 12, height: 2, color: opencodeInk));
}
