import 'dart:typed_data';
import 'package:protocol/protocol.dart';
typedef BrowserFile = ({String name, String path, bool image});
typedef BrowserClipboard = ({String? text, List<BrowserFile> files});
void Function() listenBrowserPaste({required bool Function() accepts,
  required CancellationToken Function() cancellation, required void Function(Future<BrowserClipboard>) receive}) => () {};
Future<BrowserClipboard> readBrowserClipboard(CancellationToken cancellation) => throw UnsupportedError('Browser clipboard');
Future<List<BrowserFile>> pickBrowserFiles(CancellationToken cancellation) => throw UnsupportedError('Browser file picker');
Future<String> storeBrowserFile(Uint8List bytes, String name, CancellationToken cancellation) => throw UnsupportedError('Browser files');
Future<Uint8List> readBrowserFile(String path, CancellationToken cancellation) => throw UnsupportedError('Browser files');
Future<Uint8List> readBrowserImage(String path, CancellationToken cancellation) => throw UnsupportedError('Browser images');
Future<List<Json>> prepareBrowserImages(List<Json> attachments, {required CancellationToken cancellation}) => throw UnsupportedError('Browser images');
Future<void> deleteBrowserFile(String path) async {}
Future<String> copyBrowserFile(String path, CancellationToken cancellation) => throw UnsupportedError('Browser files');
void downloadBrowserFile(Uint8List bytes, String name) => throw UnsupportedError('Browser downloads');
