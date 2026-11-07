import 'package:flutter/material.dart';

// Harness desktop light palette, at its default contrast. Translucent neutrals
// keep the same hierarchy on the canvas, message bubbles and raised surfaces.
const desktopSurface = Color(0xffffffff);
const desktopCanvas = Color(0xffffffff);
const desktopSidebar = Color(0xfff9f9f9);
const desktopForeground = Color(0xff1a1c1f);
const desktopSecondary = Color(0xb11a1c1f);
const desktopTertiary = Color(0x7e1a1c1f);
const desktopBorder = Color(0x141a1c1f);
const desktopBorderSubtle = Color(0x0d1a1c1f);
const desktopBorderStrong = Color(0x1e1a1c1f);
const desktopMuted = Color(0x0d1a1c1f);
const desktopHover = Color(0x0e1a1c1f);
const desktopPressed = Color(0x0a1a1c1f);
const desktopError = Color(0xffc23838);

const desktopConversationWidth = 736.0;
const desktopNewThreadComposerWidth = 800.0;
const desktopControlRadius = 8.0;
const desktopPanelRadius = 12.0;
const desktopProseHeight = 1.625;
const desktopFontFamily = 'Inter';
const desktopMonoFamily = 'IBM Plex Mono';
const desktopDefaultAccent = Color(0xff339cff);

Color? parseDesktopAccent(String value) {
  final hex = value.trim();
  if (!RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(hex)) return null;
  return Color(0xff000000 | int.parse(hex.substring(1), radix: 16));
}

String desktopAccentHex(Color color) =>
  '#${(color.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0')}';

/// Accent is independent of Material's primary color: action buttons stay ink.
@immutable
class DesktopAccent extends ThemeExtension<DesktopAccent> {
  const DesktopAccent(this.color);
  final Color color;

  static DesktopAccent of(BuildContext context) =>
    Theme.of(context).extension<DesktopAccent>() ?? const DesktopAccent(desktopDefaultAccent);

  Color get reference => Color.lerp(desktopForeground, color, .8)!;
  Color get selection => color.withValues(alpha: .24);

  @override
  DesktopAccent copyWith({Color? color}) => DesktopAccent(color ?? this.color);

  @override
  DesktopAccent lerp(covariant DesktopAccent? other, double t) =>
    other == null ? this : DesktopAccent(Color.lerp(color, other.color, t)!);
}

// Project identities are independent of the application accent.
const projectColors = {
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

ThemeData desktopTheme({Color accent = desktopDefaultAccent}) {
  const ink = desktopForeground;
  const surface = desktopSurface;
  const border = desktopBorder;
  const buttonStyle = ButtonStyle(mouseCursor: WidgetStateMouseCursor.clickable);
  final accents = DesktopAccent(accent);
  final scheme = ColorScheme.fromSeed(seedColor: ink, brightness: Brightness.light).copyWith(
    primary: ink, onPrimary: surface,
    secondary: desktopSecondary, onSecondary: surface,
    tertiary: accent, onTertiary: surface,
    surface: surface, onSurface: ink, onSurfaceVariant: desktopSecondary,
    surfaceTint: Colors.transparent,
    surfaceContainerLowest: surface, surfaceContainerLow: desktopSidebar,
    surfaceContainer: desktopMuted, surfaceContainerHigh: desktopHover,
    secondaryContainer: desktopMuted, onSecondaryContainer: ink,
    outline: desktopBorderStrong, outlineVariant: border,
    error: desktopError,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: desktopFontFamily);
  return base.copyWith(
    extensions: [accents],
    scaffoldBackgroundColor: desktopCanvas,
    textTheme: base.textTheme.apply(bodyColor: ink, displayColor: ink).copyWith(
      bodyMedium: const TextStyle(fontFamily: desktopFontFamily, fontSize: 14, height: 1.5, letterSpacing: 0, color: ink),
      bodyLarge: const TextStyle(fontFamily: desktopFontFamily, fontSize: 14, height: desktopProseHeight, letterSpacing: 0, color: ink),
      bodySmall: const TextStyle(fontFamily: desktopFontFamily, fontSize: 12, height: 1.5, letterSpacing: 0, color: ink),
      titleMedium: const TextStyle(fontFamily: desktopFontFamily, fontSize: 14, fontWeight: FontWeight.w500, color: ink),
    ),
    // MaterialApp also installs this in DefaultSelectionStyle for SelectionArea
    // and SelectableText. Never derive selection from the ink button color.
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: ink, selectionColor: accents.selection, selectionHandleColor: accent),
    dividerColor: border,
    splashFactory: NoSplash.splashFactory,
    hoverColor: desktopHover,
    highlightColor: desktopPressed,
    focusColor: accent.withValues(alpha: .12),
    appBarTheme: const AppBarTheme(backgroundColor: surface, surfaceTintColor: Colors.transparent,
      elevation: 0, scrolledUnderElevation: 0, titleTextStyle: TextStyle(
        fontFamily: desktopFontFamily, fontSize: 16, fontWeight: FontWeight.w600, color: ink)),
    textButtonTheme: const TextButtonThemeData(style: buttonStyle),
    filledButtonTheme: const FilledButtonThemeData(style: buttonStyle),
    outlinedButtonTheme: const OutlinedButtonThemeData(style: buttonStyle),
    elevatedButtonTheme: const ElevatedButtonThemeData(style: buttonStyle),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: desktopSecondary)
      .copyWith(mouseCursor: WidgetStateMouseCursor.clickable)),
    checkboxTheme: const CheckboxThemeData(mouseCursor: WidgetStateMouseCursor.clickable),
    radioTheme: const RadioThemeData(mouseCursor: WidgetStateMouseCursor.clickable),
    switchTheme: const SwitchThemeData(mouseCursor: WidgetStateMouseCursor.clickable),
    popupMenuTheme: PopupMenuThemeData(color: surface, surfaceTintColor: Colors.transparent,
      mouseCursor: WidgetStateMouseCursor.clickable,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(desktopPanelRadius),
        side: const BorderSide(color: border))),
    tooltipTheme: TooltipThemeData(decoration: BoxDecoration(color: ink,
      borderRadius: BorderRadius.circular(desktopControlRadius)),
      textStyle: const TextStyle(fontFamily: desktopFontFamily, fontSize: 12, color: surface)),
    inputDecorationTheme: const InputDecorationTheme(border: InputBorder.none, isDense: true),
  );
}
