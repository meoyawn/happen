part of 'transport.dart';

// Unix Process.start has neither an explicit descriptor boundary nor an atomic
// new-process-group option. Do not fork a multithreaded Dart VM or signal its
// inherited process group. posix_spawn establishes both policies before exec.
// SCM_RIGHTS hands the owned socket ends to public dart:io Socket APIs; no SDK
// internals, launcher executable, shell interpolation or polling I/O is used.
class _StdioProcess {
  _StdioProcess(this.pid, this.input, this.output, this.error, this.exited, this.signal, this.dispose);
  final int pid;
  final IOSink input;
  final Stream<List<int>> output, error;
  final Future<void> exited;
  final void Function(int) signal;
  final Future<void> Function() dispose;
  Future<void>? _stopping;
  Future<void> stop() => _stopping ??= () async {
    unawaited(input.close().then<void>((_) {}, onError: (Object _) {}));
    signal(15);
    // The group, not just its wrapper, owns this grace period. Always escalate:
    // the wrapper may exit while an uncooperative descendant retains stdio.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    signal(9);
    try { await exited.timeout(const Duration(seconds: 1)); }
    on TimeoutException { /* Streams must still close if the OS delays reaping. */ }
  }();
}

Future<_StdioProcess> _startStdio(Json config, CancellationToken cancellation) async {
  final command = requiredString(config, 'command'), args = (config['args'] as List? ?? []).cast<String>();
  final environment = mcpEnvironment(config);
  cancellation.throwIfCancelled();
  if ([command, ...args, if (config['cwd'] case final String cwd) cwd, ...environment.keys, ...environment.values]
      .any((value) => value.contains('\u0000'))) {
    throw ArgumentError('MCP process strings must not contain NUL');
  }
  if (!Platform.isMacOS && !Platform.isLinux) {
    final process = await Process.start(command, args, workingDirectory: config['cwd'] as String?,
      environment: environment, includeParentEnvironment: false);
    registerIsolateCleanup('mcp:${process.pid}', {'pid': process.pid});
    final result = _StdioProcess(process.pid, process.stdin, process.stdout, process.stderr, process.exitCode.then<void>((_) {}),
      (signal) => process.kill(signal == 9 ? ProcessSignal.sigkill : ProcessSignal.sigterm),
      () async { unregisterIsolateCleanup('mcp:${process.pid}'); });
    if (cancellation.isCancelled) { await result.stop(); await result.dispose(); cancellation.throwIfCancelled(); }
    return result;
  }
  final descriptors = <int>[], sockets = <RawSocket>[];
  _StdioProcess? result;
  try {
    using((arena) {
      for (var index = 0; index < 3; index++) {
        final pair = arena<Int32>(2);
        if (_stdioSocketPair(1, 1, 0, pair) != 0) throw const McpFailure('Unable to create MCP stdio');
        descriptors.addAll([pair[0], pair[1]]);
        for (final descriptor in [pair[0], pair[1]]) {
          if (_stdioFcntl(descriptor, 2, 1) < 0) throw const McpFailure('Unable to protect MCP stdio descriptors'); // F_SETFD, FD_CLOEXEC
        }
        if (_stdioFcntl(pair[0], 4, Platform.isMacOS ? 4 : 0x800) < 0) throw const McpFailure('Unable to prepare MCP stdio'); // F_SETFL, O_NONBLOCK (parent end only)
      }
    });
    sockets.addAll(await _adoptStdioSockets([descriptors[0], descriptors[2], descriptors[4]], cancellation));
    cancellation.throwIfCancelled();
    final pid = _spawnStdio(command, args, config['cwd'] as String?, environment, [descriptors[1], descriptors[3], descriptors[5]]);
    registerIsolateCleanup('mcp:$pid', {'pid': pid});
    final input = IOSink(_StdioInput(sockets[0]));
    unawaited(input.done.then<void>((_) {}, onError: (Object _) {}));
    result = _StdioProcess(pid, input, _stdioOutput(sockets[1]), _stdioOutput(sockets[2]), _stdioExit(pid),
      (signal) { _stdioKill(-pid, signal); }, () async {
        await Future.wait(sockets.map((socket) => socket.close()));
        unregisterIsolateCleanup('mcp:$pid');
      });
    if (cancellation.isCancelled) { await result.stop(); await result.dispose(); cancellation.throwIfCancelled(); }
    return result;
  } catch (_) {
    await Future.wait(sockets.map((socket) => socket.close()));
    rethrow;
  } finally { for (final descriptor in descriptors) { _stdioClose(descriptor); } }
}

// The parent runs this effect after a failed owner exits, before replacement.
// Each Unix PID identifies the dedicated process group created by _spawnStdio.
Future<void> cleanupMcpProcess(Json params, CancellationToken cancellation, void Function(Json) emit) async {
  final child = params['pid'] as int;
  cancellation.throwIfCancelled();
  if (!Platform.isMacOS && !Platform.isLinux) {
    Process.killPid(child, ProcessSignal.sigterm);
    await cancellableDelay(const Duration(milliseconds: 250), cancellation);
    Process.killPid(child, ProcessSignal.sigkill);
    return;
  }
  _stdioKill(-child, 15);
  await cancellableDelay(const Duration(milliseconds: 250), cancellation);
  _stdioKill(-child, 9);
  final status = calloc<Int32>();
  try {
    while (true) {
      cancellation.throwIfCancelled();
      final exited = _stdioWaitpid(child, status, 1);
      if (exited == child || exited < 0 && _stdioErrno().value == 10) return;
      await cancellableDelay(const Duration(milliseconds: 10), cancellation);
    }
  } finally { calloc.free(status); }
}

Stream<List<int>> _stdioOutput(RawSocket socket) {
  final output = StreamController<List<int>>();
  socket.writeEventsEnabled = false;
  final events = socket.listen((event) {
    if (event == RawSocketEvent.read) {
      final bytes = socket.read(65536); if (bytes != null) output.add(bytes);
    } else if (event == RawSocketEvent.readClosed) { socket.readEventsEnabled = false; unawaited(output.close()); }
  }, onError: output.addError, onDone: () { if (!output.isClosed) unawaited(output.close()); });
  output.onPause = () => socket.readEventsEnabled = false;
  output.onResume = () => socket.readEventsEnabled = true;
  output.onCancel = () async { await socket.close(); await events.cancel(); };
  return output.stream;
}

class _StdioInput implements StreamConsumer<List<int>> {
  _StdioInput(this.socket) {
    socket.readEventsEnabled = false; socket.writeEventsEnabled = false;
    events = socket.listen((event) {
      if (event == RawSocketEvent.write) {
        socket.writeEventsEnabled = false;
        final waiter = writable; writable = null; waiter?.complete();
      }
    }, onError: (Object error, StackTrace stack) { failure = error; writable?.completeError(error, stack); writable = null; },
      onDone: () { failure = const McpFailure('MCP stdin closed'); writable?.completeError(failure!); writable = null; });
  }
  final RawSocket socket;
  late final StreamSubscription<RawSocketEvent> events;
  Completer<void>? writable;
  Object? failure;
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final bytes in stream) {
      for (var offset = 0; offset < bytes.length;) {
        if (failure != null) throw failure!;
        final written = socket.write(bytes, offset);
        offset += written;
        if (written == 0) { writable = Completer<void>(); socket.writeEventsEnabled = true; await writable!.future; }
      }
    }
  }
  @override
  Future<void> close() async { socket.shutdown(SocketDirection.send); await events.cancel(); }
}

final _stdioLibc = DynamicLibrary.process();
final _stdioSocketPair = _stdioLibc.lookupFunction<Int32 Function(Int32, Int32, Int32, Pointer<Int32>), int Function(int, int, int, Pointer<Int32>)>('socketpair');
final _stdioSocket = _stdioLibc.lookupFunction<Int32 Function(Int32, Int32, Int32), int Function(int, int, int)>('socket');
final _stdioConnect = _stdioLibc.lookupFunction<Int32 Function(Int32, Pointer<Uint8>, Uint32), int Function(int, Pointer<Uint8>, int)>('connect');
final _stdioSendmsg = _stdioLibc.lookupFunction<IntPtr Function(Int32, Pointer<Void>, Int32), int Function(int, Pointer<Void>, int)>('sendmsg');
final _stdioClose = _stdioLibc.lookupFunction<Int32 Function(Int32), int Function(int)>('close');
final _stdioKill = _stdioLibc.lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>('kill');
final _stdioFcntl = _stdioLibc.lookupFunction<Int32 Function(Int32, Int32, VarArgs<(Int32,)>), int Function(int, int, int)>('fcntl');
final _stdioWaitpid = _stdioLibc.lookupFunction<Int32 Function(Int32, Pointer<Int32>, Int32), int Function(int, Pointer<Int32>, int)>('waitpid');
final _stdioErrno = _stdioLibc.lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(Platform.isMacOS ? '__error' : '__errno_location');
final _stdioSpawn = _stdioLibc.lookupFunction<Int32 Function(Pointer<Int32>, Pointer<Utf8>, Pointer<Void>, Pointer<Void>, Pointer<Pointer<Utf8>>, Pointer<Pointer<Utf8>>),
  int Function(Pointer<Int32>, Pointer<Utf8>, Pointer<Void>, Pointer<Void>, Pointer<Pointer<Utf8>>, Pointer<Pointer<Utf8>>)>('posix_spawn');
final _stdioActionsInit = _stdioLibc.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('posix_spawn_file_actions_init');
final _stdioActionsDestroy = _stdioLibc.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('posix_spawn_file_actions_destroy');
final _stdioDup = _stdioLibc.lookupFunction<Int32 Function(Pointer<Void>, Int32, Int32), int Function(Pointer<Void>, int, int)>('posix_spawn_file_actions_adddup2');
final _stdioChdir = _stdioLibc.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Utf8>), int Function(Pointer<Void>, Pointer<Utf8>)>('posix_spawn_file_actions_addchdir_np');
final _stdioCloseFrom = _stdioLibc.lookupFunction<Int32 Function(Pointer<Void>, Int32), int Function(Pointer<Void>, int)>('posix_spawn_file_actions_addclosefrom_np');
final _stdioAttrInit = _stdioLibc.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('posix_spawnattr_init');
final _stdioAttrDestroy = _stdioLibc.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('posix_spawnattr_destroy');
final _stdioPgroup = _stdioLibc.lookupFunction<Int32 Function(Pointer<Void>, Int32), int Function(Pointer<Void>, int)>('posix_spawnattr_setpgroup');
final _stdioFlags = _stdioLibc.lookupFunction<Int32 Function(Pointer<Void>, Int16), int Function(Pointer<Void>, int)>('posix_spawnattr_setflags');
final _stdioSigempty = _stdioLibc.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('sigemptyset');
final _stdioSigadd = _stdioLibc.lookupFunction<Int32 Function(Pointer<Void>, Int32), int Function(Pointer<Void>, int)>('sigaddset');
final _stdioSigdefault = _stdioLibc.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Void>), int Function(Pointer<Void>, Pointer<Void>)>('posix_spawnattr_setsigdefault');
final _stdioSigmask = _stdioLibc.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Void>), int Function(Pointer<Void>, Pointer<Void>)>('posix_spawnattr_setsigmask');

int _spawnStdio(String command, List<String> args, String? cwd, Map<String, String> environment, List<int> descriptors) => using((arena) {
  // These libc types are opaque pointer-sized objects on Darwin and bounded
  // structs on glibc/musl. Aligned over-allocation leaves their layout to libc.
  final actions = arena<Uint64>(128).cast<Void>(), attributes = arena<Uint64>(128).cast<Void>();
  void check(int status) { if (status != 0) throw ProcessException(command, args, 'Unable to launch MCP stdio', status); }
  check(_stdioActionsInit(actions));
  var initialized = false;
  try {
    check(_stdioAttrInit(attributes)); initialized = true;
    if (cwd != null) check(_stdioChdir(actions, cwd.toNativeUtf8(allocator: arena)));
    for (final (index, descriptor) in descriptors.indexed) { check(_stdioDup(actions, descriptor, index)); }
    if (Platform.isLinux) check(_stdioCloseFrom(actions, 3));
    check(_stdioPgroup(attributes, 0)); // POSIX_SPAWN_SETPGROUP: child PID is our group, never the host's.
    final signals = arena<Uint64>(16).cast<Void>();
    check(_stdioSigempty(signals)); check(_stdioSigadd(signals, 13)); check(_stdioSigdefault(attributes, signals)); // SIGPIPE
    check(_stdioSigempty(signals)); check(_stdioSigmask(attributes, signals));
    check(_stdioFlags(attributes, 2 | 4 | 8 | (Platform.isMacOS ? 0x4000 : 0))); // group, SIGDEF, SIGMASK, CLOEXEC_DEFAULT
    Pointer<Pointer<Utf8>> strings(List<String> values) {
      final result = arena<Pointer<Utf8>>(values.length + 1);
      for (final (index, value) in values.indexed) { result[index] = value.toNativeUtf8(allocator: arena); }
      return result;
    }
    final pid = arena<Int32>(), env = strings(environment.entries.map((e) => '${e.key}=${e.value}').toList());
    var status = 2, denied = false;
    final candidates = command.contains('/') ? [command] : [for (final path in (environment['PATH'] ?? '/usr/bin:/bin').split(':')) '${path.isEmpty ? '.' : path}/$command'];
    for (final program in candidates) {
      status = _stdioSpawn(pid, program.toNativeUtf8(allocator: arena), actions, attributes, strings([command, ...args]), env);
      if (status == 8) { // ENOEXEC: execvp's executable-text fallback, still inside the same descriptor/group boundary.
        status = _stdioSpawn(pid, '/bin/sh'.toNativeUtf8(allocator: arena), actions, attributes, strings(['/bin/sh', program, ...args]), env);
        check(status); return pid.value;
      }
      if (status == 0) return pid.value;
      if (status == 13) denied = true;
      if (![2, 13, 20].contains(status)) break;
    }
    check(denied && [2, 20].contains(status) ? 13 : status);
    throw StateError('Unreachable MCP spawn result');
  } finally { if (initialized) _stdioAttrDestroy(attributes); _stdioActionsDestroy(actions); }
});

Future<void> _stdioExit(int pid) {
  final result = Completer<void>(), status = calloc<Int32>();
  Timer? timer;
  void poll() {
    final errno = _stdioErrno(), exited = _stdioWaitpid(pid, status, 1);
    // Dart's process service may reap a native child via waitpid(-1) first.
    // ECHILD also means this PID is no longer ours; no exit code is fabricated.
    if (exited == pid || exited < 0 && errno.value == 10) {
      timer?.cancel(); calloc.free(status); result.complete();
    }
  }
  timer = Timer.periodic(const Duration(milliseconds: 20), (_) => poll());
  return result.future;
}

final class _StdioIovec extends Struct {
  external Pointer<Uint8> data;
  @Size() external int length;
}
final class _StdioDarwinMessage extends Struct {
  external Pointer<Void> name;
  @Uint32() external int nameLength;
  external Pointer<_StdioIovec> vectors;
  @Int32() external int vectorCount;
  external Pointer<Uint8> control;
  @Uint32() external int controlLength;
  @Int32() external int flags;
}
final class _StdioLinuxMessage extends Struct {
  external Pointer<Void> name;
  @Uint32() external int nameLength;
  external Pointer<_StdioIovec> vectors;
  @Size() external int vectorCount;
  external Pointer<Uint8> control;
  @Size() external int controlLength;
  @Int32() external int flags;
}

Future<List<RawSocket>> _adoptStdioSockets(List<int> descriptors, CancellationToken cancellation) async {
  final folder = await Directory.systemTemp.createTemp('mcp-stdio-');
  RawServerSocket? server;
  RawSocket? receiver;
  StreamSubscription<RawSocketEvent>? reader;
  var sender = -1;
  final adopted = <RawSocket>[];
  try {
    final path = '${folder.path}/io';
    server = await RawServerSocket.bind(InternetAddress(path, type: InternetAddressType.unix), 0);
    final incoming = server.first.then((socket) async {
      // Cancellation may win before accept is delivered. The eventual accepted
      // handle still needs an owner even when its waiter has already stopped.
      if (cancellation.isCancelled) await socket.close();
      return socket;
    });
    sender = _stdioSocket(1, 1, 0);
    if (sender < 0 || _stdioFcntl(sender, 2, 1) < 0) throw const McpFailure('Unable to adopt MCP stdio');
    using((arena) {
      final name = utf8.encode(path), address = arena<Uint8>(110);
      if (name.length > (Platform.isMacOS ? 103 : 107)) throw const McpFailure('MCP stdio socket path is too long');
      if (Platform.isMacOS) { address[0] = name.length + 3; address[1] = 1; } else { address.cast<Uint16>().value = 1; }
      address.asTypedList(110).setRange(2, name.length + 2, name);
      if (_stdioConnect(sender, address, name.length + 3) != 0) throw const McpFailure('Unable to connect MCP stdio');
      final vector = arena<_StdioIovec>(); vector.ref..data = arena<Uint8>()..length = 1;
      final header = Platform.isMacOS ? 12 : 16, size = Platform.isMacOS ? 24 : 32;
      final control = arena<Uint8>(size), bytes = ByteData.sublistView(control.asTypedList(size));
      if (Platform.isMacOS) bytes.setUint32(0, header + 12, Endian.host); else bytes.setUint64(0, header + 12, Endian.host);
      bytes.setInt32(header - 8, Platform.isMacOS ? 0xffff : 1, Endian.host); bytes.setInt32(header - 4, 1, Endian.host); // SOL_SOCKET, SCM_RIGHTS
      for (final (index, descriptor) in descriptors.indexed) { bytes.setInt32(header + index * 4, descriptor, Endian.host); }
      Pointer<Void> message;
      if (Platform.isMacOS) {
        final native = arena<_StdioDarwinMessage>(); native.ref..vectors = vector..vectorCount = 1..control = control..controlLength = size; message = native.cast();
      } else {
        final native = arena<_StdioLinuxMessage>(); native.ref..vectors = vector..vectorCount = 1..control = control..controlLength = size; message = native.cast();
      }
      if (_stdioSendmsg(sender, message, Platform.isMacOS ? 0x80000 : 0x4000) != 1) throw const McpFailure('Unable to transfer MCP stdio');
    });
    receiver = await incoming.asCancellable(cancellation);
    receiver.writeEventsEnabled = false;
    final received = Completer<void>();
    reader = receiver.listen((event) {
      if (event != RawSocketEvent.read) return;
      final message = receiver!.readMessage(); if (message == null) return;
      try {
        for (final control in message.controlMessages) { for (final handle in control.extractHandles()) { adopted.add(handle.toRawSocket()); } }
        if (!received.isCompleted) received.complete();
      } catch (error, stack) { if (!received.isCompleted) received.completeError(error, stack); }
    }, onError: (Object error, StackTrace stack) { if (!received.isCompleted) received.completeError(error, stack); });
    await received.future.asCancellable(cancellation);
    if (adopted.length != 3) throw const McpFailure('Incomplete MCP stdio transfer');
    return adopted;
  } catch (_) { await Future.wait(adopted.map((socket) => socket.close())); rethrow; }
  finally {
    await receiver?.close(); await reader?.cancel(); await server?.close(); if (sender >= 0) _stdioClose(sender);
    await folder.delete(recursive: true);
  }
}
