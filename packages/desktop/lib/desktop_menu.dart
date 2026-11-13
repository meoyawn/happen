import 'package:flutter/material.dart';

/// Gives pointer-opened menus the same keyboard focus as keyboard-opened ones.
class DesktopMenuAnchor extends StatefulWidget {
  const DesktopMenuAnchor({super.key, this.controller, this.style, this.onClose,
    required this.menuChildren, required this.builder});
  final MenuController? controller;
  final MenuStyle? style;
  final VoidCallback? onClose;
  final List<Widget> menuChildren;
  final Widget Function(BuildContext, MenuController, FocusNode) builder;

  @override
  State<DesktopMenuAnchor> createState() => _DesktopMenuAnchorState();
}

class _DesktopMenuAnchorState extends State<DesktopMenuAnchor> {
  final _buttonFocus = FocusNode();
  final _menuEntry = GlobalKey();
  late final _controller = MenuController();

  void _opened() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !(widget.controller ?? _controller).isOpen) return;
      final context = _menuEntry.currentContext;
      if (context != null) FocusScope.of(context).requestFocus();
    });
  }

  @override
  void dispose() { _buttonFocus.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => MenuAnchor(
    controller: widget.controller ?? _controller, childFocusNode: _buttonFocus,
    style: widget.style, onOpen: _opened, onClose: widget.onClose,
    menuChildren: [for (var index = 0; index < widget.menuChildren.length; index++)
      if (index == 0) Builder(key: _menuEntry, builder: (_) => widget.menuChildren.first)
      else widget.menuChildren[index]],
    builder: (context, controller, _) => widget.builder(context, controller, _buttonFocus),
  );
}
