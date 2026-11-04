import 'dart:convert';

import 'package:crypto/crypto.dart';

// Codex client.rs: prompt-only base instructions are rebuilt, so their identity
// is UUIDv5(namespace=UUIDv5(OID, thread_id), name=visible instructions).
// Retain only the latest pair; continuations share that baseline and identity.
({String thread, String text, String id})? _instructions;

String instructionsId(String threadId, String text) {
  final previous = _instructions;
  if (previous != null && previous.thread == threadId && previous.text == text) return previous.id;
  final namespace = _v5(_bytes('6ba7b812-9dad-11d1-80b4-00c04fd430c8'), threadId);
  final id = _v5(namespace, text).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  final value = 'msg_${id.substring(0, 8)}-${id.substring(8, 12)}-${id.substring(12, 16)}-${id.substring(16, 20)}-${id.substring(20)}';
  _instructions = (thread: threadId, text: text, id: value);
  return value;
}

List<int> _bytes(String id) {
  final compact = id.replaceAll('-', '');
  return [for (var index = 0; index < compact.length; index += 2) int.parse(compact.substring(index, index + 2), radix: 16)];
}

List<int> _v5(List<int> namespace, String name) {
  final bytes = sha1.convert([...namespace, ...utf8.encode(name)]).bytes.take(16).toList();
  bytes[6] = bytes[6] & 0x0f | 0x50;
  bytes[8] = bytes[8] & 0x3f | 0x80;
  return bytes;
}
