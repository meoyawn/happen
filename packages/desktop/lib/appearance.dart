import 'package:flutter/material.dart';

// T3 Code: --chat-content-max-width and the default light palette.
const conversationWidth = 736.0;
const conversationCanvas = Color(0xfffcfcfc);
const conversationForeground = Color(0xff27272a);
const conversationSecondary = Color(0xff71717b);
const conversationSurface = Color(0xfff4f4f5);
const conversationOutline = Color(0xffe4e4e7);
const conversationAccent = Color(0xff1b4ed8);
const newThreadComposerWidth = 800.0;
const opencodeInk = Color(0xff161616);
const opencodeMuted = Color(0xff5c5c5c);
const opencodeFaint = Color(0xff808080);
const opencodeLayer = Color(0xfff2f2f2);
const opencodeBorder = Color(0x1a000000);

// OpenCode: ui/src/styles/tokens/theme.css, light project-avatar tokens.
const opencodeProjectColors = {
  'orange': (background: Color(0xffee7330), border: Color(0xffd16427)),
  'yellow': (background: Color(0xffe7af36), border: Color(0xffcb9f34)),
  'cyan': (background: Color(0xff0096b8), border: Color(0xff007d9b)),
  'green': (background: Color(0xff2eaf5a), border: Color(0xff198b43)),
  'red': (background: Color(0xffd92e3c), border: Color(0xffb82d35)),
  'pink': (background: Color(0xffe4429e), border: Color(0xffc83d8b)),
  'blue': (background: Color(0xff3250df), border: Color(0xff2c47c8)),
  'purple': (background: Color(0xff623be2), border: Color(0xff5230c2)),
  'gray': (background: Color(0xff5c5c5c), border: Color(0xff3a3a3a)),
};

ThemeData conversationTheme(ThemeData base) => base.copyWith(
  colorScheme: base.colorScheme.copyWith(
    primary: conversationAccent, onPrimary: Colors.white,
    surface: conversationCanvas, onSurface: conversationForeground,
    onSurfaceVariant: conversationSecondary, outlineVariant: conversationOutline,
    surfaceContainer: conversationSurface,
  ),
  textTheme: base.textTheme.apply(bodyColor: conversationForeground, displayColor: conversationForeground),
  dividerColor: conversationOutline,
);

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
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: 'Inter');
  return base.copyWith(
    scaffoldBackgroundColor: Colors.white,
    textTheme: base.textTheme.apply(bodyColor: ink, displayColor: ink).copyWith(
      bodyMedium: const TextStyle(fontFamily: 'Inter', fontSize: 14, height: 1.5, letterSpacing: 0, color: ink),
      bodyLarge: const TextStyle(fontFamily: 'Inter', fontSize: 14, height: 1.625, letterSpacing: 0, color: ink),
      bodySmall: const TextStyle(fontFamily: 'Inter', fontSize: 12, height: 1.5, letterSpacing: 0, color: ink),
      titleMedium: const TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.w500, color: ink),
    ),
    dividerColor: border,
    splashFactory: NoSplash.splashFactory,
    hoverColor: const Color(0x0d1a1c1f),
    highlightColor: const Color(0x081a1c1f),
    appBarTheme: const AppBarTheme(backgroundColor: Colors.white, surfaceTintColor: Colors.transparent,
      elevation: 0, scrolledUnderElevation: 0, titleTextStyle: TextStyle(
        fontFamily: 'Inter', fontSize: 16, fontWeight: FontWeight.w600, color: ink)),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: const Color(0xff666a71))),
    popupMenuTheme: PopupMenuThemeData(color: Colors.white, surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: border))),
    tooltipTheme: TooltipThemeData(decoration: BoxDecoration(color: ink, borderRadius: BorderRadius.circular(8)),
      textStyle: const TextStyle(fontFamily: 'Inter', fontSize: 12, color: Colors.white)),
    inputDecorationTheme: const InputDecorationTheme(border: InputBorder.none, isDense: true),
  );
}
