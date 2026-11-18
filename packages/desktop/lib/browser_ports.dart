import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:protocol/protocol.dart';
import 'package:server/dev_servers.dart';

import 'appearance.dart';

sealed class _PortsState {
  const _PortsState(this.servers);
  final List<Json> servers;
}
final class _PortsIdle extends _PortsState { const _PortsIdle() : super(const []); }
final class _PortsLoading extends _PortsState { const _PortsLoading(super.servers); }
final class _PortsReady extends _PortsState { const _PortsReady(super.servers); }
final class _PortsFailed extends _PortsState { const _PortsFailed(super.servers); }

_PortsState _transition(_PortsState current, _PortsState next) => switch ((current, next)) {
  (_PortsIdle() || _PortsReady() || _PortsFailed(), _PortsLoading()) => next,
  (_PortsLoading(), _PortsReady() || _PortsFailed()) => next,
  _ => throw StateError('Invalid browser port discovery transition'),
};

class BrowserPorts extends StatefulWidget {
  const BrowserPorts({super.key, required this.active, required this.onOpen, this.discover = discoverDevServers});
  final bool active;
  final ValueChanged<Uri> onOpen;
  final Future<List<Json>> Function({required CancellationToken cancellation}) discover;
  @override
  State<BrowserPorts> createState() => _BrowserPortsState();
}

class _BrowserPortsState extends State<BrowserPorts> {
  _PortsState _state = const _PortsIdle();
  CancellationToken? _operation;
  Timer? _poll;

  @override
  void initState() { super.initState(); if (widget.active) unawaited(_refresh()); }
  @override
  void didUpdateWidget(BrowserPorts oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.active) { _poll?.cancel(); _operation?.cancel(); }
    else if (!oldWidget.active || oldWidget.discover != widget.discover) { unawaited(_refresh()); }
  }
  @override
  void dispose() { _poll?.cancel(); _operation?.cancel(); super.dispose(); }

  Future<void> _refresh() async {
    _poll?.cancel();
    _operation?.cancel();
    final operation = _operation = CancellationToken();
    if (_state is _PortsLoading) _state = _transition(_state, _PortsReady(_state.servers));
    setState(() => _state = _transition(_state, _PortsLoading(_state.servers)));
    try {
      final servers = await widget.discover(cancellation: operation);
      if (mounted && !operation.isCancelled) setState(() => _state = _transition(_state, _PortsReady(servers)));
    } on CancelledException { /* Hidden and closed tabs stop discovery. */ }
    catch (_) {
      if (mounted && !operation.isCancelled) setState(() => _state = _transition(_state, _PortsFailed(_state.servers)));
    } finally {
      if (mounted && widget.active && !operation.isCancelled) {
        _poll = Timer(const Duration(seconds: 3), () => unawaited(_refresh()));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 460),
    child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(28), children: [
      const Icon(Icons.language_rounded, size: 28, color: desktopTertiary),
      const SizedBox(height: 16),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Text('Local dev servers', style: TextStyle(fontSize: 14, color: desktopSecondary)),
        const SizedBox(width: 8),
        SizedBox.square(dimension: 24, child: _state is _PortsLoading && _state.servers.isEmpty
          ? const Icon(Icons.hourglass_empty_rounded, size: 16, color: desktopTertiary)
          : IconButton(tooltip: 'Refresh local servers', padding: EdgeInsets.zero,
              onPressed: widget.active ? () => unawaited(_refresh()) : null,
              icon: const Icon(Icons.refresh_rounded, size: 16, color: desktopSecondary))),
      ]),
      const SizedBox(height: 8),
      if (_state is _PortsFailed)
        const Text('Could not discover local servers. Try refreshing.', textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: desktopTertiary))
      else if (_state.servers.isEmpty && _state is! _PortsLoading)
        const Text('No web servers found. Start a dev server or enter a URL above.', textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: desktopTertiary)),
      for (final server in _state.servers)
        ListTile(key: ValueKey('browser-port:${server['port']}'), dense: true,
          leading: const Icon(Icons.dns_outlined, size: 18, color: desktopSecondary),
          title: Text(server['url'] as String, style: const TextStyle(fontSize: 12, color: desktopForeground)),
          subtitle: server['processName'] is String ? Text(server['processName'] as String,
            style: const TextStyle(fontSize: 11, color: desktopTertiary)) : null,
          trailing: const Icon(Icons.arrow_forward_rounded, size: 16, color: desktopTertiary),
          onTap: () => widget.onOpen(Uri.parse(server['url'] as String))),
    ])));
}
