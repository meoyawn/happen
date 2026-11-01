import 'package:flutter/material.dart';

import 'appearance.dart';

// OpenCode: app/src/settings/general/interface-mode.tsx and interface-mode.css.
class OpenCodeInterfacePicker extends StatelessWidget {
  const OpenCodeInterfacePicker({super.key, required this.selected, required this.onSelected});
  final OpenCodeLayout selected;
  final ValueChanged<OpenCodeLayout> onSelected;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text('Interface', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
    const SizedBox(height: 12),
    LayoutBuilder(builder: (context, constraints) {
      final columns = constraints.maxWidth >= 684 ? 3 : constraints.maxWidth >= 452 ? 2 : 1;
      final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
      return Wrap(spacing: 12, runSpacing: 12, children: [
        for (final mode in OpenCodeLayout.values)
          SizedBox(width: width, child: _option(mode)),
      ]);
    }),
  ]);

  Widget _option(OpenCodeLayout mode) {
    final checked = mode == selected;
    final title = switch (mode) {
      OpenCodeLayout.top => 'Top tabs',
      OpenCodeLayout.side => 'Side tabs',
      OpenCodeLayout.inbox => 'Inbox',
    };
    final description = switch (mode) {
      OpenCodeLayout.top => 'Browser-style tabs across the top of the window.',
      OpenCodeLayout.side => 'Browser-style tabs in a sidebar.',
      OpenCodeLayout.inbox => 'Every session across your projects, sorted by what needs you next.',
    };
    return Semantics(
      checked: checked, inMutuallyExclusiveGroup: true, label: title,
      child: Material(
        color: const Color(0xfffafafa),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: checked ? opencodeInk : opencodeBorder, width: checked ? 1.5 : .5)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('opencode-layout:${mode.name}'),
          onTap: () => onSelected(mode),
          child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            AspectRatio(aspectRatio: 16 / 9, child: ClipRRect(borderRadius: BorderRadius.circular(6),
              child: CustomPaint(painter: _InterfacePreview(mode, checked)))),
            const SizedBox(height: 12),
            Row(children: [
              Container(width: 14, height: 14, decoration: BoxDecoration(shape: BoxShape.circle,
                border: Border.all(color: checked ? opencodeInk : const Color(0xffb5b5b5), width: checked ? 4 : 1))),
              const SizedBox(width: 8),
              Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: opencodeInk)),
              if (mode == OpenCodeLayout.inbox) ...[
                const SizedBox(width: 6),
                Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(color: const Color(0xffeeeeee), borderRadius: BorderRadius.circular(4)),
                  child: const Text('Experimental', style: TextStyle(fontSize: 11, color: opencodeMuted))),
              ],
            ]),
            Padding(padding: const EdgeInsets.only(left: 22, top: 4),
              child: Text(description, style: const TextStyle(fontSize: 13, height: 1.5, color: opencodeMuted))),
          ])),
        ),
      ),
    );
  }
}

class _InterfacePreview extends CustomPainter {
  const _InterfacePreview(this.mode, this.checked);
  final OpenCodeLayout mode;
  final bool checked;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 240, size.height / 135);
    const fill = Color(0xfff0f0f0), ink = Color(0xffdedede), border = Color(0xffe5e5e5);
    final strong = checked ? const Color(0xff656565) : const Color(0xffcccccc);
    void box(double x, double y, double w, double h, Color color, [double radius = 1.5]) =>
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), Radius.circular(radius)), Paint()..color = color);
    box(0, 0, 240, 135, Colors.white, 6);
    final top = mode == OpenCodeLayout.top ? 21.0 : 0.0;
    final left = mode == OpenCodeLayout.top ? 0.0 : 58.0;
    if (mode == OpenCodeLayout.top) {
      box(0, 0, 240, 21, const Color(0xfff7f7f7), 0);
      for (var i = 0; i < 3; i++) {
        box(6 + i * 55, 4, 51, 13, i == 0 ? fill : const Color(0xfff7f7f7), 2);
        box(10 + i * 55, 8, 5, 5, strong, 1);
        box(19 + i * 55, 9, [29.0, 21.0, 25.0][i], 3, ink);
      }
    } else {
      box(0, 0, 58, 135, const Color(0xfff7f7f7), 0);
      var y = 7.0;
      for (var i = 0; i < 6; i++) {
        if (mode == OpenCodeLayout.inbox && [0, 1, 3].contains(i)) {
          box(7, y, 15, 3, strong);
          y += 8;
        }
        box(4, y, 50, 12, i == 1 ? fill : const Color(0xfff7f7f7), 2);
        box(7, y + 4, 5, 5, mode == OpenCodeLayout.inbox
            ? (i == 0 ? const Color(0xffc79541) : i < 3 ? const Color(0xff6b9b7d) : const Color(0xff7186b7))
            : strong, mode == OpenCodeLayout.inbox ? 3 : 1);
        box(16, y + 5, [29.0, 22.0, 26.0, 18.0, 24.0, 16.0][i], 3, ink);
        y += 15;
      }
    }
    final panel = (240 - left) * .26;
    final mainWidth = 240 - left - panel;
    box(240 - panel, top, panel, 135 - top, const Color(0xfff7f7f7), 0);
    for (var i = 0; i < 5; i++) { box(246 - panel, top + 8 + i * 7, (panel - 12) * [.8, .64, .72, .5, .68][i], 3, ink); }
    for (var i = 0; i < 4; i++) { box(left + mainWidth - 10 - i * 9, top + 6, 6, 6, strong); }
    for (var i = 0; i < 7; i++) { box(left + 8, top + 22 + i * 7, (mainWidth - 16) * [.92, .78, .84, .6, .88, .7, .4][i], 3, ink); }
    box(left + 8, 114, mainWidth - 16, 13, fill, 5);
    for (var i = 0; i < 2; i++) { box(left + mainWidth - 17 - i * 8, 118, 5, 5, strong); }
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(.5, .5, 239, 134), const Radius.circular(6)),
      Paint()..color = border..style = PaintingStyle.stroke..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(_InterfacePreview oldDelegate) => mode != oldDelegate.mode || checked != oldDelegate.checked;
}
