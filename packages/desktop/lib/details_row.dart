import 'package:flutter/material.dart';

import 'appearance.dart';

/// T3 Code's panel rows use a shared label edge and separate trailing actions.
class DetailsRow extends StatelessWidget {
  const DetailsRow({super.key, required this.icon, required this.label, this.onPressed, this.trailing, this.tooltip});
  final Widget icon;
  final String label;
  final VoidCallback? onPressed;
  final Widget? trailing;
  final String? tooltip;
  @override
  Widget build(BuildContext context) {
    final row = SizedBox(height: 32, child: Row(children: [
      Expanded(child: TextButton(onPressed: onPressed,
        style: TextButton.styleFrom(foregroundColor: opencodeInk, disabledForegroundColor: opencodeMuted,
          padding: const EdgeInsets.symmetric(horizontal: 10), minimumSize: const Size(0, 32),
          alignment: Alignment.centerLeft, tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
        child: Row(children: [
          IconTheme(data: const IconThemeData(size: 16, color: opencodeFaint),
            child: SizedBox.square(dimension: 16, child: icon)),
          const SizedBox(width: 11),
          Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, height: 1.2))),
        ]))),
      ?trailing,
    ]));
    return tooltip == null ? row : Tooltip(message: tooltip!, child: row);
  }
}

const detailsChevron = Icon(Icons.keyboard_arrow_down_rounded, size: 16, color: opencodeFaint);
final detailsMenuStyle = IconButton.styleFrom(
  minimumSize: const Size(32, 32), maximumSize: const Size(32, 32), padding: EdgeInsets.zero,
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap);
