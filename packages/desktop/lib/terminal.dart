import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_pty2/flutter_pty2.dart';
import 'package:protocol/protocol.dart';
import 'package:xterm2/xterm.dart';

import 'terminal_process.dart';

/// Shells belong to a chat or project draft, independently of the panel's view.
class DesktopTerminals extends ChangeNotifier {
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
    final shell = TerminalShell(group.directory);
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
    _release([shell]);
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

  void adoptDraft(String project, String task) {
    final group = groups.remove((project, null));
    if (group != null) groups[(project, task)] = group;
  }

  Future<void> _release(Iterable<TerminalShell> shells) {
    // close() stops input and kills synchronously; retain its asynchronous
    // native cleanup so quitting also drains already-closed tabs.
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

class TerminalShell extends ChangeNotifier {
  TerminalShell(this.directory) {
    terminal.onOutput = (text) => unawaited(_write(text, _lifetime));
    terminal.onResize = (columns, rows, _, _) {
      if (columns <= 0 || rows <= 0) return;
      _size = PtySize(columns: columns, rows: rows);
      if (running) _pty?.resize(_size);
    };
    terminal.onTitleChange = (value) { title = value; notifyListeners(); };
    _opening = _open(_lifetime);
    unawaited(_opening.catchError((Object error) { _fail(error); }));
  }

  final String directory;
  final terminal = Terminal(maxLines: 1000,
    platform: Platform.isMacOS ? TerminalTargetPlatform.macos
      : Platform.isWindows ? TerminalTargetPlatform.windows : TerminalTargetPlatform.linux);
  final renderer = TerminalController();
  final scroll = ScrollController();
  final _lifetime = CancellationToken();
  late final Future<void> _opening;
  Future<void>? _closing;
  PtySession? _pty;
  PtySize _size = const PtySize(columns: 80, rows: 24);
  StreamSubscription<String>? _output;
  int _views = 0;
  bool _released = false;
  String title = '';
  String? error;
  int? exitCode;
  bool get running => _pty != null && exitCode == null && error == null && !_lifetime.isCancelled;

  Future<void> _open(CancellationToken cancellation) async {
    try {
      final shell = Platform.environment['SHELL'] ?? (Platform.isWindows ? 'powershell.exe' : '/bin/bash');
      // Do not abandon an in-flight spawn on cancellation: take ownership of
      // its eventual handle and close it before completing this operation.
      final pty = _pty = await Pty.spawn(PtySpawnOptions(executable: shell,
        arguments: Platform.isWindows ? const ['-NoLogo'] : const ['-il'],
        workingDirectory: directory,
        size: _size,
        environment: PtyEnvironment.inherit(overrides: const {'TERM': 'xterm-256color'}, remove: {
          ...Platform.environment.keys.where((key) => key.startsWith('MOON_')),
          'TERMINFO', 'TERMINFO_DIRS',
        }),
      ));
      if (cancellation.isCancelled) { _kill(pty); await pty.close(); return; }
      pty.resize(_size);
      _output = pty.utf8Output().listen(
        (text) { if (!cancellation.isCancelled) terminal.write(text); },
        onError: (Object error) => _fail(error),
      );
      notifyListeners();
      unawaited(_watchExit(pty, cancellation).catchError((Object error) { _fail(error); }));
    } catch (error) {
      _fail(error);
      await _pty?.close();
    }
  }

  Future<void> _write(String text, CancellationToken cancellation) async {
    if (!running) return;
    try {
      await _pty!.input.writeUtf8(text).asCancellable(cancellation);
    } on CancelledException {
      // Native close cancels queued writes as well as this observer.
    } catch (error) { _fail(error); }
  }

  Future<void> _watchExit(PtySession pty, CancellationToken cancellation) async {
    try {
      final exit = await pty.processExit.asCancellable(cancellation);
      exitCode = switch (exit) { PtyExitCode(:final code) => code, PtySignalExit(:final signal) => -signal };
      notifyListeners();
      await pty.done.asCancellable(cancellation);
      await pty.close();
    } on CancelledException {
      // The owner is awaiting close(), including native workers and handles.
    } catch (error) {
      _fail(error);
      await pty.close();
    }
  }

  void _fail(Object failure) {
    if (_lifetime.isCancelled) return;
    error = failure.toString();
    notifyListeners();
  }

  Future<void> close() {
    if (_closing case final closing?) return closing;
    _lifetime.cancel();
    terminal.onOutput = null;
    terminal.onResize = null;
    terminal.onTitleChange = null;
    if (_pty != null && exitCode == null) { _kill(_pty!); }
    return _closing = _release();
  }

  void _kill(PtySession pty) {
    // Capture background jobs before the shell can exit and orphan them.
    // Windows's native PTY backend contains the tree in a Job Object.
    try { killTerminalProcessTree(pty.pid); }
    catch (error, stack) {
      FlutterError.reportError(FlutterErrorDetails(exception: error, stack: stack, library: 'terminal process cleanup'));
    }
    finally {
      try { pty.kill(); } on PtyException { /* close() still drains native cleanup. */ }
    }
  }

  Future<void> _release() async {
    try {
      await _opening;
    } finally {
      try { await _pty?.close(); }
      finally {
        await _output?.cancel();
        _released = true;
        _disposeIfReleased();
      }
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
    decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: Color(0xffe8e9eb)))),
    child: Column(children: [
      MouseRegion(cursor: SystemMouseCursors.resizeUpDown, child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (event) => controller.resize(scope, controller.height - event.delta.dy, availableHeight),
        child: const SizedBox(height: 4, width: double.infinity))),
      SizedBox(height: 32, child: Row(children: [
        const SizedBox(width: 12),
        const Icon(Icons.terminal_outlined, size: 16, color: Color(0xff656971)),
        const SizedBox(width: 8),
        const Text('Terminal', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
        const SizedBox(width: 12),
        Expanded(child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
          for (final shell in group.sessions)
            ListenableBuilder(listenable: shell, builder: (context, _) => Material(
              color: shell == group.active ? const Color(0xfff2f3f5) : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              child: InkWell(onTap: () => controller.select(scope, shell), borderRadius: BorderRadius.circular(6),
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
    icon: Icon(icon, size: 14, color: const Color(0xff777b82))));

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
        theme: _terminalTheme)),
      if (status != null)
        Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text(status,
          maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Color(0xff777b82)))),
    ]);
  });
}

const _terminalTheme = TerminalTheme(
  cursor: Color(0xff1a1c1f), selection: Color(0x1a000000),
  foreground: Color(0xff1a1c1f), background: Colors.white,
  black: Color(0xff979aa0), white: Color(0xff1a1c1f),
  brightBlack: Color(0xff777b82), brightWhite: Color(0xff1a1c1f),
  red: Color(0xffe02e2a), brightRed: Color(0xffe02e2a),
  green: Color(0xff00a240), brightGreen: Color(0xff00a240),
  yellow: Color(0xffffc300), brightYellow: Color(0xffffc300),
  blue: Color(0xff339cff), brightBlue: Color(0xff339cff),
  magenta: Color(0xff924ff7), brightMagenta: Color(0xff924ff7),
  cyan: Color(0xff339cff), brightCyan: Color(0xff339cff),
  searchHitBackground: Color(0xffffc300), searchHitBackgroundCurrent: Color(0xffffc300),
  searchHitForeground: Color(0xff1a1c1f),
);
