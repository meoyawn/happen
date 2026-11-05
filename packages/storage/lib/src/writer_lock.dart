part of '../storage.dart';

final _writerLibc = DynamicLibrary.process();
final _writerOpen = _writerLibc.lookupFunction<Int32 Function(Pointer<Utf8>, Int32, VarArgs<(Uint32,)>), int Function(Pointer<Utf8>, int, int)>('open');
final _writerClose = _writerLibc.lookupFunction<Int32 Function(Int32), int Function(int)>('close');
final _writerFlock = _writerLibc.lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>('flock');
final _writerFchmod = _writerLibc.lookupFunction<Int32 Function(Int32, Uint32), int Function(int, int)>('fchmod');
final _writerFdopen = _writerLibc.lookupFunction<Pointer<Void> Function(Int32, Pointer<Utf8>), Pointer<Void> Function(int, Pointer<Utf8>)>('fdopen');
final _writerFcloseAddress = _writerLibc.lookup<NativeFunction<Int32 Function(Pointer<Void>)>>('fclose');
final _writerFclose = _writerFcloseAddress.asFunction<int Function(Pointer<Void>)>();
// As with sqlite3_close_v2's own native finalizer, the return code is ignored
// only on VM finalization. Normal ownership release explicitly calls fclose.
final _writerFinalizer = NativeFinalizer(_writerFcloseAddress.cast());

final class _WriterLease implements Finalizable {
  _WriterLease(this.file) { _writerFinalizer.attach(this, file, detach: this); }
  final Pointer<Void> file;
  bool released = false;
  void release() {
    if (released) return;
    _writerFinalizer.detach(this); _writerFclose(file); released = true;
  }
}

void Function() _acquireWriter(String path, String id) {
  if (Platform.isWindows) {
    final file = File(path).openSync(mode: FileMode.append);
    try { file.lockSync(FileLock.exclusive); return file.closeSync; }
    catch (_) { file.closeSync(); rethrow; }
  }
  return using((arena) {
    // Unlike fcntl/FileLock on Unix, flock belongs to this open description.
    // Another isolate, path alias or failed acquisition cannot release it.
    final descriptor = _writerOpen(path.toNativeUtf8(allocator: arena), Platform.isMacOS ? 0x1000302 : 0xa0042, 0x180);
    if (descriptor < 0) throw StateError('Cannot open the private writer lease for $id');
    if (_writerFchmod(descriptor, 0x180) != 0 || _writerFlock(descriptor, 6) != 0) {
      _writerClose(descriptor); throw StateError('Thread $id already has an active writer');
    }
    final file = _writerFdopen(descriptor, 'r+'.toNativeUtf8(allocator: arena));
    if (file == nullptr) { _writerClose(descriptor); throw StateError('Cannot retain the writer lease for $id'); }
    return _WriterLease(file).release;
  });
}
