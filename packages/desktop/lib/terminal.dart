import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:xterm2/xterm.dart';

import 'appearance.dart';

bool get terminalHasFocus =>
  FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<_TerminalView>() != null;

/// Shells belong to a chat or draft tab, independently of the panel's view.
class DesktopTerminals extends ChangeNotifier {
  DesktopTerminals(this.client);
  final AgentClient client;
  final groups = <(String, String?), TerminalGroup>{};
  final _releasing = <Future<void>>{};
  bool _closed = false;
  double height = 280;

  void open((String, String?) scope, String directory, {bool focus = true}) {
    if (_closed) return;
    final group = groups.putIfAbsent(scope, () => TerminalGroup(directory));
    group.visible = true;
    if (focus) group.focusRequest++;
    if (group.sessions.isEmpty) {
      newShell(scope);
    } else {
      notifyListeners();
    }
  }

  void newShell((String, String?) scope) {
    final group = groups[scope];
    if (_closed || group == null) return;
    final shell = TerminalShell(client, group.directory);
    group.sessions.add(shell);
    group.active = shell;
    group.visible = true;
    group.focusRequest++;
    notifyListeners();
  }

  void select((String, String?) scope, TerminalShell shell) {
    final group = groups[scope];
    if (group == null || !group.sessions.contains(shell)) return;
    group.active = shell;
    group.focusRequest++;
    notifyListeners();
  }

  void runScript((String, String?) scope, String directory, String name, String command) {
    if (_closed) return;
    final group = groups.putIfAbsent(scope, () => TerminalGroup(directory));
    final shell = TerminalShell(client, directory, command: command)..title = name;
    group.sessions.add(shell); group.active = shell; group.visible = true; group.focusRequest++;
    notifyListeners();
  }

  void hide((String, String?) scope) {
    final group = groups[scope];
    if (group == null || !group.visible) return;
    group.visible = false;
    notifyListeners();
  }

  void closeShell((String, String?) scope, TerminalShell shell) {
    final group = groups[scope];
    if (group == null || !group.sessions.remove(shell)) return;
    if (group.active == shell) group.active = group.sessions.lastOrNull;
    if (group.sessions.isEmpty) group.visible = false;
    group.focusRequest++;
    unawaited(_release([shell]));
    notifyListeners();
  }

  Future<void> removeTask(String id) => _removeWhere((scope) => scope.$2 == id);
  Future<void> removeProject(String key) => _removeWhere((scope) => scope.$1 == key);

  Future<void> _removeWhere(bool Function((String, String?)) matches) {
    final scopes = groups.keys.where(matches).toList();
    final shells = <TerminalShell>[];
    for (final scope in scopes) {
      shells.addAll(groups.remove(scope)!.sessions);
    }
    final closing = _release(shells);
    if (!_closed && scopes.isNotEmpty) notifyListeners();
    return closing;
  }

  void adoptDraft(String project, String task, {String? draft}) {
    final group = groups.remove((project, draft));
    if (group != null) groups[(project, task)] = group;
  }

  Future<void> _release(Iterable<TerminalShell> shells) {
    // Retain cleanup after removing a tab so quitting drains its remote close.
    final operation = Future.wait(shells.map((shell) => shell.close())).then<void>((_) {});
    _releasing.add(operation);
    unawaited(operation.then<void>((_) { _releasing.remove(operation); }, onError: (Object error, StackTrace stack) {
      _releasing.remove(operation);
      FlutterError.reportError(FlutterErrorDetails(exception: error, stack: stack, library: 'terminal cleanup'));
    }));
    return operation;
  }

  Future<void> close() async {
    _closed = true;
    await _removeWhere((_) => true);
    await Future.wait(_releasing.toList());
  }

  void resize((String, String?) scope, double next, double available) {
    if (next < 160) { hide(scope); return; }
    height = next.clamp(160, math.max(160, available * .5));
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}

class TerminalGroup {
  TerminalGroup(this.directory);
  final String directory;
  final sessions = <TerminalShell>[];
  TerminalShell? active;
  bool visible = false;
  int focusRequest = 0;
}

sealed class _ShellState { const _ShellState(); }
class _Starting extends _ShellState { const _Starting(); }
class _Running extends _ShellState { const _Running(); }
class _Exited extends _ShellState { const _Exited(this.code); final int code; }
class _Failed extends _ShellState { const _Failed(this.message); final String message; }
class _Closing extends _ShellState { const _Closing(); }
class _Closed extends _ShellState { const _Closed(); }

class TerminalShell extends ChangeNotifier {
  TerminalShell(this.client, this.directory, {this.command}) {
    // Subscribe before spawning: output and exit can precede the open reply.
    _events = client.events.stream.listen(_event, onDone: () => _fail('Connection closed. Open a new terminal.'));
    terminal.onOutput = _queueInput;
    terminal.onResize = (columns, rows, _, _) {
      if (columns <= 0 || rows <= 0) return;
      _size = (columns.clamp(1, 1000), rows.clamp(1, 1000));
      _resizeTimer ??= Timer(const Duration(milliseconds: 16), () {
        _resizeTimer = null;
        unawaited(_resize());
      });
    };
    terminal.onTitleChange = (value) { title = value; notifyListeners(); };
    _opening = _open();
  }

  final AgentClient client;
  final id = newId();
  final String directory;
  final String? command;
  final terminal = Terminal(maxLines: 1000,
    platform: Platform.isMacOS ? TerminalTargetPlatform.macos
      : Platform.isWindows ? TerminalTargetPlatform.windows : TerminalTargetPlatform.linux);
  final renderer = TerminalController();
  final scroll = ScrollController();
  final _lifetime = CancellationToken();
  late final Future<void> _opening;
  Future<void>? _closing;
  _ShellState _state = const _Starting();
  (int, int) _size = (80, 24);
  (int, int) _resizedSize = (0, 0);
  late final StreamSubscription<Json> _events;
  Future<void> _writing = Future<void>.value();
  Timer? _ackTimer, _resizeTimer;
  int _sequence = 0, _acknowledged = 0, _queuedInput = 0;
  bool _acknowledging = false, _resizing = false;
  int _views = 0;
  bool _released = false;
  String title = '';
  String? get error => switch (_state) { _Failed(:final message) => message, _ => null };
  int? get exitCode => switch (_state) { _Exited(:final code) => code, _ => null };
  bool get running => _state is _Running;

  void _transition(_ShellState next) {
    final valid = switch ((_state, next)) {
      (_Starting(), _Running() || _Exited() || _Failed() || _Closing()) => true,
      (_Running(), _Exited() || _Failed() || _Closing()) => true,
      (_Exited() || _Failed(), _Closing()) => true,
      (_Closing(), _Closed()) => true,
      _ => false,
    };
    if (!valid) throw StateError('Invalid shell transition: ${_state.runtimeType} to ${next.runtimeType}');
    _state = next;
    notifyListeners();
  }

  Future<Json> _request(String method, Json params) => client.terminalRequest('terminal/$method',
    {'terminalId': id, ...params}, cancellation: _lifetime);

  Future<void> _open() async {
    try {
      await _request('open', {'cwd': directory, 'command': ?command, 'columns': _size.$1, 'rows': _size.$2});
      if (_state is! _Starting) return;
      _transition(const _Running());
      await _resize();
    } on CancelledException { /* close() releases a spawn that raced cancellation. */ }
    catch (error) { _fail(error); }
  }

  Future<void> _resize() async {
    if (_resizing) return;
    _resizing = true;
    try {
      while (running && _resizedSize != _size) {
        final size = _size;
        await _request('resize', {'columns': size.$1, 'rows': size.$2});
        _resizedSize = size;
      }
    } on CancelledException { /* The shell is closing. */ }
    catch (error) { _fail(error); }
    finally { _resizing = false; }
  }

  void _event(Json event) {
    if (_lifetime.isCancelled) return;
    if (!(event['method'] as String? ?? '').startsWith('terminal/')) return;
    if (event['method'] == 'terminal/unavailable') { _fail(event['params']['message'] as String); return; }
    final params = jsonObject(event['params']);
    if (params['terminalId'] != id) return;
    switch (event['method']) {
      case 'terminal/output':
        final sequence = params['sequence'] as int;
        if (sequence <= _sequence) return;
        terminal.write(params['data'] as String);
        _sequence = sequence;
        _ackTimer ??= Timer(const Duration(milliseconds: 16), () {
          _ackTimer = null;
          unawaited(_acknowledge());
        });
      case 'terminal/exited':
        if (_state is _Starting || _state is _Running) _transition(_Exited(params['code'] as int));
      case 'terminal/error': _fail(params['message'] as String);
    }
  }

  Future<void> _acknowledge() async {
    if (_acknowledging) return;
    _acknowledging = true;
    try {
      while (!_lifetime.isCancelled && _acknowledged < _sequence) {
        final sequence = _sequence;
        await _request('ack', {'sequence': sequence});
        _acknowledged = sequence;
      }
    } on CancelledException { /* The shell is closing. */ }
    catch (error) { _fail(error); }
    finally { _acknowledging = false; }
  }

  void _queueInput(String text) {
    if (!running || text.isEmpty) return;
    if (_queuedInput + text.length > 1024 * 1024) { _fail('Terminal input queue is full. Open a new terminal.'); return; }
    _queuedInput += text.length;
    _writing = _writing.then((_) async {
      try {
        for (var start = 0; start < text.length;) {
          var end = math.min(start + 16384, text.length);
          if (end < text.length && text.codeUnitAt(end - 1) >= 0xd800 && text.codeUnitAt(end - 1) <= 0xdbff) end--;
          _lifetime.throwIfCancelled();
          if (!running) return;
          await _request('write', {'data': text.substring(start, end)});
          start = end;
        }
      } on CancelledException { /* The shell is closing. */ }
      catch (error) { _fail(error); }
      finally { _queuedInput -= text.length; }
    });
  }

  void _fail(Object failure) {
    if (_state is! _Starting && _state is! _Running) return;
    _transition(_Failed(failure.toString()));
  }

  Future<void> close() {
    if (_closing case final closing?) return closing;
    _transition(const _Closing());
    _lifetime.cancel();
    _ackTimer?.cancel(); _resizeTimer?.cancel();
    terminal.onOutput = null;
    terminal.onResize = null;
    terminal.onTitleChange = null;
    return _closing = _release();
  }

  Future<void> _release() async {
    final cleanup = TimeoutCancellationToken(const Duration(seconds: 10));
    try {
      await _opening;
      await _writing;
      // Use a fresh token: the panel lifetime has already been cancelled.
      await client.terminalRequest('terminal/close', {'terminalId': id}, cancellation: cleanup);
    } on CancelledException { /* Disconnect also releases the server's shells. */ }
    catch (_) { /* A closed connection releases its shells on the server. */ }
    finally {
      cleanup.cancel();
      await _events.cancel();
      _transition(const _Closed());
      _released = true;
      _disposeIfReleased();
    }
  }

  void attach() => _views++;
  void detach() { _views--; _disposeIfReleased(); }

  void _disposeIfReleased() {
    if (!_released || _views != 0) return;
    _released = false;
    scroll.dispose();
    renderer.dispose();
    terminal.dispose();
    super.dispose();
  }
}

class TerminalWorkspace extends StatelessWidget {
  const TerminalWorkspace({super.key, required this.controller, required this.scope, required this.child});
  final DesktopTerminals controller;
  final (String, String?)? scope;
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, bounds) =>
    ListenableBuilder(listenable: controller, child: child, builder: (context, child) {
      final group = controller.groups[scope];
      return Column(children: [
        Expanded(child: child!),
        if (scope != null && group?.visible == true)
          SizedBox(height: math.min(controller.height, bounds.maxHeight * .5),
            child: _TerminalDock(key: ValueKey(scope), controller: controller,
              scope: scope!, group: group!, availableHeight: bounds.maxHeight)),
      ]);
    }));
}

class _TerminalDock extends StatelessWidget {
  const _TerminalDock({super.key, required this.controller, required this.scope,
    required this.group, required this.availableHeight});
  final DesktopTerminals controller;
  final (String, String?) scope;
  final TerminalGroup group;
  final double availableHeight;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: desktopBorder))),
    child: Column(children: [
      MouseRegion(cursor: SystemMouseCursors.resizeUpDown, child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (event) => controller.resize(scope, controller.height - event.delta.dy, availableHeight),
        child: const SizedBox(height: 4, width: double.infinity))),
      SizedBox(height: 32, child: Row(children: [
        const SizedBox(width: 12),
        const Icon(Icons.terminal_outlined, size: 16, color: desktopSecondary),
        const SizedBox(width: 8),
        const Text('Terminal', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
        const SizedBox(width: 12),
        Expanded(child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
          for (final shell in group.sessions)
            ListenableBuilder(listenable: shell, builder: (context, _) => Material(
              color: shell == group.active ? desktopMuted : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              child: InkWell(onTap: () => controller.select(scope, shell), borderRadius: BorderRadius.circular(6),
                mouseCursor: WidgetStateMouseCursor.clickable,
                child: Padding(padding: const EdgeInsets.only(left: 8), child: Row(children: [
                  ConstrainedBox(constraints: const BoxConstraints(maxWidth: 160), child: Text(
                    shell.title.isEmpty ? 'Shell ${group.sessions.indexOf(shell) + 1}' : shell.title,
                    overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Color(0xff50545b)))),
                  _terminalButton('Close terminal', Icons.close, () => controller.closeShell(scope, shell)),
                ]))),
            )),
        ]))),
        _terminalButton('New terminal', Icons.add, () => controller.newShell(scope)),
        _terminalButton('Hide terminal', Icons.keyboard_arrow_down, () => controller.hide(scope)),
        const SizedBox(width: 8),
      ])),
      if (group.active case final shell?)
        Expanded(child: _TerminalView(key: ObjectKey(shell), shell: shell, focusRequest: group.focusRequest)),
    ]),
  );
}

Widget _terminalButton(String label, IconData icon, VoidCallback onPressed) => SizedBox.square(
  dimension: 26, child: IconButton(tooltip: label, onPressed: onPressed, padding: EdgeInsets.zero,
    icon: Icon(icon, size: 14, color: desktopSecondary)));

class _TerminalView extends StatefulWidget {
  const _TerminalView({super.key, required this.shell, required this.focusRequest});
  final TerminalShell shell;
  final int focusRequest;

  @override
  State<_TerminalView> createState() => _TerminalViewState();
}

class _TerminalViewState extends State<_TerminalView> {
  final _focus = FocusNode(debugLabel: 'Integrated terminal');

  @override
  void initState() { super.initState(); widget.shell.attach(); _requestFocus(); }

  @override
  void didUpdateWidget(covariant _TerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusRequest != widget.focusRequest) _requestFocus();
  }

  void _requestFocus() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) _focus.requestFocus();
  });

  @override
  void dispose() { _focus.dispose(); widget.shell.detach(); super.dispose(); }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.shell, builder: (context, _) {
    final shell = widget.shell;
    final status = shell.error ?? (shell.exitCode == null ? null : 'Shell exited (${shell.exitCode})');
    return Column(children: [
      Expanded(child: TerminalView(shell.terminal, controller: shell.renderer, scrollController: shell.scroll,
        focusNode: _focus, readOnly: !shell.running,
        padding: const EdgeInsets.only(left: 16, top: 8, right: 8, bottom: 12),
        textStyle: const TerminalStyle(fontFamily: 'monospace', fontSize: 13, height: 1.2),
        theme: _terminalTheme(DesktopAccent.of(context).selection))),
      if (status != null)
        Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text(status,
          maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: desktopSecondary))),
    ]);
  });
}

TerminalTheme _terminalTheme(Color selection) => TerminalTheme(
  cursor: desktopForeground, selection: selection,
  foreground: desktopForeground, background: Colors.white,
  black: Color(0xff979aa0), white: desktopForeground,
  brightBlack: desktopSecondary, brightWhite: desktopForeground,
  red: Color(0xffe02e2a), brightRed: Color(0xffe02e2a),
  green: Color(0xff00a240), brightGreen: Color(0xff00a240),
  yellow: Color(0xffffc300), brightYellow: Color(0xffffc300),
  blue: Color(0xff339cff), brightBlue: Color(0xff339cff),
  magenta: Color(0xff924ff7), brightMagenta: Color(0xff924ff7),
  cyan: Color(0xff339cff), brightCyan: Color(0xff339cff),
  searchHitBackground: Color(0xffffc300), searchHitBackgroundCurrent: Color(0xffffc300),
  searchHitForeground: desktopForeground,
);
