import 'package:flutter/material.dart';

enum ConversationStyle { harness, opencode }

/// Presentation only; both styles share the same conversation and composer.
class ConversationAppearance extends InheritedWidget {
  const ConversationAppearance({super.key, required this.style, required super.child});
  final ConversationStyle style;

  static ConversationStyle of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ConversationAppearance>()?.style ?? ConversationStyle.harness;

  @override
  bool updateShouldNotify(ConversationAppearance oldWidget) => style != oldWidget.style;
}

ThemeData desktopTheme() {
  const ink = Color(0xff1a1c1f);
  const border = Color(0xffe8e9eb);
  final scheme = ColorScheme.fromSeed(seedColor: ink, brightness: Brightness.light).copyWith(
    primary: ink, onPrimary: Colors.white,
    secondary: const Color(0xff62666d), onSecondary: Colors.white,
    surface: Colors.white, onSurface: ink, onSurfaceVariant: const Color(0xff777b82),
    surfaceContainerLowest: Colors.white, surfaceContainerLow: const Color(0xfff9f9f9),
    surfaceContainer: const Color(0xfff3f3f4), surfaceContainerHigh: const Color(0xffeeeeef),
    secondaryContainer: const Color(0xffeeeeef), onSecondaryContainer: ink,
    outline: const Color(0xffc7c9cd), outlineVariant: border,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: '.AppleSystemUIFont');
  return base.copyWith(
    scaffoldBackgroundColor: Colors.white,
    textTheme: base.textTheme.apply(bodyColor: ink, displayColor: ink).copyWith(
      bodyMedium: const TextStyle(fontFamily: '.AppleSystemUIFont', fontSize: 14, height: 1.5, letterSpacing: 0, color: ink),
      bodyLarge: const TextStyle(fontFamily: '.AppleSystemUIFont', fontSize: 14, height: 1.625, letterSpacing: 0, color: ink),
      bodySmall: const TextStyle(fontFamily: '.AppleSystemUIFont', fontSize: 12, height: 1.5, letterSpacing: 0, color: ink),
      titleMedium: const TextStyle(fontFamily: '.AppleSystemUIFont', fontSize: 14, fontWeight: FontWeight.w500, color: ink),
    ),
    dividerColor: border,
    splashFactory: NoSplash.splashFactory,
    hoverColor: const Color(0x0d1a1c1f),
    highlightColor: const Color(0x081a1c1f),
    appBarTheme: const AppBarTheme(backgroundColor: Colors.white, surfaceTintColor: Colors.transparent,
      elevation: 0, scrolledUnderElevation: 0, titleTextStyle: TextStyle(
        fontFamily: '.AppleSystemUIFont', fontSize: 16, fontWeight: FontWeight.w600, color: ink)),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: const Color(0xff666a71))),
    popupMenuTheme: PopupMenuThemeData(color: Colors.white, surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: border))),
    tooltipTheme: TooltipThemeData(decoration: BoxDecoration(color: ink, borderRadius: BorderRadius.circular(8)),
      textStyle: const TextStyle(fontFamily: '.AppleSystemUIFont', fontSize: 12, color: Colors.white)),
    inputDecorationTheme: const InputDecorationTheme(border: InputBorder.none, isDense: true),
  );
}

class ConversationStylePicker extends StatelessWidget {
  const ConversationStylePicker({super.key, required this.selected, required this.onSelected});
  final ConversationStyle selected;
  final ValueChanged<ConversationStyle> onSelected;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
    final cards = [for (final style in ConversationStyle.values) Expanded(child: _option(context, style))];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Conversation view', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      const Text('Choose how your conversations look.', style: TextStyle(fontSize: 13, color: Color(0xff777b82))),
      const SizedBox(height: 16),
      if (constraints.maxWidth >= 420)
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [cards[0], const SizedBox(width: 12), cards[1]])
      else ...[
        _option(context, ConversationStyle.harness), const SizedBox(height: 12),
        _option(context, ConversationStyle.opencode),
      ],
    ]);
  });

  Widget _option(BuildContext context, ConversationStyle style) {
    final chosen = selected == style;
    final harness = style == ConversationStyle.harness;
    final radius = BorderRadius.circular(12);
    return Semantics(
      selected: chosen, button: true,
      child: Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: radius, side: BorderSide(
          color: chosen ? const Color(0xff292b30) : const Color(0xffe3e4e7), width: chosen ? 1.5 : 1)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('conversation-style:${style.name}'),
          onTap: () => onSelected(style),
          child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ExcludeSemantics(child: Container(
              height: 112, padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: const Color(0xfff9f9fa), borderRadius: BorderRadius.circular(6)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Align(alignment: Alignment.centerRight, child: Container(
                  width: harness ? 96 : 116, height: harness ? 25 : 20,
                  decoration: BoxDecoration(color: const Color(0xffe9e9ec), borderRadius: BorderRadius.circular(harness ? 14 : 5)),
                )),
                SizedBox(height: harness ? 15 : 11),
                _line(120), const SizedBox(height: 6), _line(85), const Spacer(),
                Container(height: harness ? 24 : 21, decoration: BoxDecoration(color: Colors.white,
                  border: Border.all(color: const Color(0xffdedfe2)), borderRadius: BorderRadius.circular(harness ? 12 : 5))),
              ]),
            )),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: Text(harness ? 'Codex' : 'OpenCode', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600))),
              Icon(chosen ? Icons.radio_button_checked : Icons.radio_button_off, size: 18,
                color: chosen ? const Color(0xff292b30) : const Color(0xffb0b3b9)),
            ]),
            const SizedBox(height: 4),
            Text(harness ? 'Spacious, rounded, familiar. Default.' : 'Compact, precise, focused.',
              style: const TextStyle(fontSize: 12, color: Color(0xff777b82))),
          ])),
        ),
      ),
    );
  }

  Widget _line(double width) => Container(width: width, height: 4,
    decoration: BoxDecoration(color: const Color(0xffd4d6db), borderRadius: BorderRadius.circular(2)));
}
