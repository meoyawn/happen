import 'package:flutter/material.dart';

/// Keep actions in the row's layout while revealing them on hover or focus.
class SidebarHover extends StatefulWidget {
  const SidebarHover({super.key, required this.builder});
  final Widget Function(BuildContext, bool) builder;

  @override
  State<SidebarHover> createState() => _SidebarHoverState();
}

class _SidebarHoverState extends State<SidebarHover> {
  bool _hovered = false, _focused = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: Focus(onFocusChange: (value) => setState(() => _focused = value),
      child: widget.builder(context, _hovered || _focused || MediaQuery.of(context).navigationMode == NavigationMode.directional)),
  );
}

/// Sidebar rows include a 30 logical pixel hit area.
class SidebarItem extends StatelessWidget {
  const SidebarItem({super.key, required this.child, this.onTap, this.selected = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 8)});
  final Widget child;
  final VoidCallback? onTap;
  final bool selected;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? const Color(0x0e1a1c1f) : Colors.transparent,
    borderRadius: BorderRadius.circular(10),
    child: InkWell(
      onTap: onTap, borderRadius: BorderRadius.circular(10),
      hoverColor: const Color(0x0e1a1c1f), highlightColor: Colors.transparent,
      child: SizedBox(height: 30, child: Padding(padding: padding, child: child)),
    ),
  );
}
