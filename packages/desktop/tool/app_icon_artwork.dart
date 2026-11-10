// Invoked by generate_app_icons.dart in a headless Flutter engine.
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

const _ink = Color(0xff26332a), _lime = Color(0xffb8f38a);
const _release = [Color(0xff303a31), Color(0xff19221c)];
const _debug = [Color(0xffffdc8c), Color(0xffeda93f)];
const _debugInk = Color(0xff483011);

Future<void> main() async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
    final (source, fontBytes) = await Isolate.run(() => (
      File('assets/app-icons/happen-mark.svg').readAsStringSync(), File('assets/fonts/Inter.ttf').readAsBytesSync()));
    final mark = await vg.loadPicture(SvgStringLoader(source.replaceAll('currentColor', '#ffffff')), null);
    try {
      for (final (name, debug) in [('AppIcon', false), ('AppIconDebug', true)]) {
        for (final size in [16, 32, 64, 128, 256, 512, 1024]) {
          await _png('macos/Runner/Assets.xcassets/$name.appiconset/app_icon_$size.png', size, size,
            (canvas) => _tile(canvas, mark.picture, Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
              debug: debug, dock: true));
        }
      }
      for (final scale in [1, 2]) {
        await _png('macos/Runner/Assets.xcassets/HappenStatus.imageset/status${scale == 1 ? '' : '@${scale}x'}.png',
          18 * scale, 18 * scale, (canvas) {
            canvas.scale(scale.toDouble());
            _mark(canvas, mark.picture, const Rect.fromLTWH(-2, -2, 22, 22), const Color(0xff000000));
          });
      }
      // A full tile at sidebar sizes: no Dock padding or lighting detail.
      final sidebar = source.replaceFirst('viewBox="0 0 100 100">', 'viewBox="0 0 100 100">\n'
        '  <rect width="100" height="100" rx="22" fill="#233027"/>\n'
        '  <g transform="translate(-4 -4) scale(1.08)">')
        .replaceAll('currentColor', '#b8f38a').replaceFirst('</svg>', '  </g>\n</svg>');
      await _writeText('assets/app-icons/happen-sidebar.svg', sidebar);
      final font = FontLoader('Inter')..addFont(Future.value(ByteData.sublistView(fontBytes)));
      await font.load();
      await _png('design/icon-preview.png', 1440, 960, (canvas) => _preview(canvas, mark.picture));
    } finally { mark.picture.dispose(); }
    exit(0);
  } catch (error, stack) {
    stderr.writeln('$error\n$stack');
    exit(1);
  }
}

void _mark(Canvas canvas, ui.Picture mark, Rect rect, Color color) {
  canvas.save();
  canvas.translate(rect.left, rect.top);
  canvas.scale(rect.width / 100, rect.height / 100);
  canvas.saveLayer(const Rect.fromLTWH(0, 0, 100, 100),
    Paint()..colorFilter = ColorFilter.mode(color, BlendMode.srcIn));
  canvas.drawPicture(mark);
  canvas.restore();
  canvas.restore();
}

void _tile(Canvas canvas, ui.Picture mark, Rect rect, {bool debug = false, bool dock = false}) {
  final tile = dock ? rect.deflate(rect.width * 100 / 1024) : rect;
  final shape = RRect.fromRectAndRadius(tile, Radius.circular(tile.width * (dock ? 185 / 824 : .22)));
  final paint = Paint();
  if (dock) {
    paint.shader = ui.Gradient.linear(tile.topLeft, tile.bottomRight, debug ? _debug : _release);
  } else { paint.color = const Color(0xff233027); }
  canvas.drawRRect(shape, paint);
  _mark(canvas, mark, dock ? tile : tile.inflate(tile.width * .04), debug ? _debugInk : _lime);
}

Future<void> _png(String path, int width, int height, void Function(Canvas) draw) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  // Render each size from vector geometry, supersampling the smallest assets.
  final scale = width < 128 ? 4 : 1;
  canvas.scale(scale.toDouble());
  draw(canvas);
  final picture = recorder.endRecording();
  var image = await picture.toImage(width * scale, height * scale);
  picture.dispose();
  try {
    if (scale > 1) {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawImageRect(image, Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..filterQuality = FilterQuality.high);
      final downsample = recorder.endRecording();
      final resized = await downsample.toImage(width, height);
      image.dispose(); image = resized; downsample.dispose();
    }
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    await _writeBytes(path, bytes);
  } finally { image.dispose(); }
}

// Keep worker closures outside scopes containing unsendable engine objects.
Future<void> _writeText(String path, String text) => Isolate.run(() => File(path).writeAsStringSync(text));
Future<void> _writeBytes(String path, Uint8List bytes) => Isolate.run(() {
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes);
});

void _text(Canvas canvas, String text, Offset offset, double size, {Color color = _ink, FontWeight weight = FontWeight.w400}) {
  final painter = TextPainter(text: TextSpan(text: text, style: TextStyle(fontFamily: 'Inter',
    fontSize: size, height: 1.2, color: color, fontWeight: weight)), textDirection: TextDirection.ltr)..layout();
  painter.paint(canvas, offset);
  painter.dispose();
}

void _panel(Canvas canvas, Rect rect, Color color, [double radius = 20]) =>
  canvas.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)), Paint()..color = color);

void _preview(Canvas canvas, ui.Picture mark) {
  const white = Color(0xffffffff), muted = Color(0xff758077), paper = Color(0xfff1f3ed);
  canvas.drawColor(paper, BlendMode.src);
  _text(canvas, 'Happen / Relay', const Offset(52, 40), 42, weight: FontWeight.w600);
  _text(canvas, 'Two corners. One recognizable gesture.', const Offset(54, 99), 19, color: muted);
  _panel(canvas, const Rect.fromLTWH(44, 158, 462, 584), white);
  _text(canvas, 'Dock', const Offset(74, 186), 18, weight: FontWeight.w600);
  _tile(canvas, mark, const Rect.fromLTWH(91, 223, 368, 368), dock: true);
  _text(canvas, 'Release', const Offset(74, 640), 17, weight: FontWeight.w600);
  _text(canvas, 'Lime on deep green', const Offset(74, 673), 16, color: muted);
  _tile(canvas, mark, const Rect.fromLTWH(372, 632, 72, 72), dock: true);

  _panel(canvas, const Rect.fromLTWH(530, 158, 866, 214), white);
  _text(canvas, 'Menu bar', const Offset(560, 186), 18, weight: FontWeight.w600);
  for (final (y, dark) in [(232.0, false), (295.0, true)]) {
    final foreground = dark ? white : _ink;
    _panel(canvas, Rect.fromLTWH(560, y, 806, 49), dark ? const Color(0xff26312a) : paper, 10);
    _text(canvas, 'File     Edit     View     Window', Offset(582, y + 15), 14, color: foreground);
    _mark(canvas, mark, Rect.fromLTWH(1146, y + 13, 22, 22), foreground);
    _text(canvas, 'Tue 10 Nov  10:24', Offset(1192, y + 15), 13, color: foreground);
  }

  _panel(canvas, const Rect.fromLTWH(530, 396, 866, 346), white);
  _text(canvas, 'Sidebar', const Offset(560, 424), 18, weight: FontWeight.w600);
  for (final (x, dark) in [(560.0, false), (973.0, true)]) {
    final foreground = dark ? const Color(0xffdfe5dc) : _ink;
    final secondary = dark ? const Color(0xff95a193) : muted;
    _panel(canvas, Rect.fromLTWH(x, 468, 393, 174), dark ? const Color(0xff202722) : const Color(0xfff5f6f2), 14);
    _tile(canvas, mark, Rect.fromLTWH(x + 20, 488, 20, 20));
    _text(canvas, 'happen', Offset(x + 56, 487), 17, color: secondary, weight: FontWeight.w500);
    _text(canvas, '34m', Offset(x + 336, 489), 15, color: secondary);
    _text(canvas, 'Design the Happen icon', Offset(x + 20, 534), 22, color: foreground);
    _text(canvas, 'master', Offset(x + 20, 585), 17, color: secondary);
  }
  _text(canvas, 'Same mark, tightly framed for small sizes.', const Offset(560, 681), 16, color: muted);

  _panel(canvas, const Rect.fromLTWH(44, 766, 1352, 150), white);
  _text(canvas, 'Small-size check', const Offset(74, 790), 15, color: muted);
  var x = 74.0;
  for (final size in [16.0, 18.0, 20.0, 24.0, 32.0]) {
    _mark(canvas, mark, Rect.fromLTWH(x - size / 9, 831 - size / 9, size * 11 / 9, size * 11 / 9), _ink);
    _text(canvas, '${size.toInt()} px', Offset(x, 879), 11, color: muted);
    x += 98;
  }
  _tile(canvas, mark, const Rect.fromLTWH(876, 789, 104, 104), dock: true, debug: true);
  _text(canvas, 'Debug', const Offset(1008, 803), 18, weight: FontWeight.w600);
  _text(canvas, 'Amber tile / dark mark', const Offset(1008, 840), 16, color: muted);
}
