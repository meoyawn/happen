part of 'oauth.dart';

// Dart's Unix RandomAccessFile.lock uses process-scoped fcntl locks: another
// isolate/owner in the same process can acquire (and release) the first one's
// lock. flock instead owns each independently opened descriptor, as Codex's
// std::fs lock does. Windows FileLock is already handle-scoped.
final _credentialLibc = DynamicLibrary.process();
final _credentialOpen = _credentialLibc.lookupFunction<
  Int32 Function(Pointer<Utf8>, Int32, VarArgs<(Uint32,)>), int Function(Pointer<Utf8>, int, int)>('open');
final _credentialClose = _credentialLibc.lookupFunction<Int32 Function(Int32), int Function(int)>('close');
final _credentialFlock = _credentialLibc.lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>('flock');
final _credentialFchmod = _credentialLibc.lookupFunction<Int32 Function(Int32, Uint32), int Function(int, int)>('fchmod');
final _credentialErrno = _credentialLibc.lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(Platform.isMacOS ? '__error' : '__errno_location');

Future<Future<void> Function()> _acquireCredentialLock(String path, CancellationToken token) async {
  final deadline = TimeoutCancellationToken(const Duration(seconds: 60));
  final waiting = token.merge(deadline);
  RandomAccessFile? windows;
  var descriptor = -1, reportedContention = false;
  Future<void> release() async {
    if (descriptor >= 0) { _credentialClose(descriptor); descriptor = -1; }
    await windows?.close(); windows = null;
  }
  try {
    waiting.throwIfCancelled();
    if (Platform.isWindows) {
      windows = await File(path).open(mode: FileMode.append);
    } else {
      final native = path.toNativeUtf8();
      try {
        // O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC. The descriptor cannot leak
        // to model-reachable children, and creation is private from the outset.
        descriptor = _credentialOpen(native, Platform.isMacOS ? 0x1000302 : 0xa0042, 0x180);
      } finally { malloc.free(native); }
      if (descriptor < 0 || _credentialFchmod(descriptor, 0x180) != 0) throw const McpFailure('Unable to open private MCP credential lock');
    }
    while (true) {
      waiting.throwIfCancelled();
      if (windows != null) {
        try { await windows!.lock(FileLock.exclusive); return release; }
        on FileSystemException catch (error) { if (![11, 13, 35].contains(error.osError?.errorCode)) rethrow; }
      } else {
        final errno = _credentialErrno();
        if (_credentialFlock(descriptor, 6) == 0) return release; // LOCK_EX | LOCK_NB
        if (errno.value == 4) continue; // EINTR
        if (![11, 35].contains(errno.value)) throw const McpFailure('Unable to acquire MCP credential lock');
      }
      if (!reportedContention) { traceInstant('mcp.oauth.lock.contended', category: 'auth'); reportedContention = true; }
      await cancellableDelay(const Duration(milliseconds: 25), waiting);
    }
  } on TimeoutException {
    await release(); throw const McpFailure('Timed out waiting for MCP OAuth credential lock');
  } catch (_) { await release(); rethrow; }
  finally { deadline.cancel(); }
}
