# Desktop design system

`lib/appearance.dart` owns the shared palette, type families, layout tokens and
Flutter component theme. The neutral colors follow harness/client's desktop
light palette: white content, an off-white sidebar, dark ink, and translucent
foreground, border and interaction tones. Keep these alpha colors translucent
so they work on both the canvas and message surfaces.

Use `Theme.of(context).textTheme` for typography and the semantic `desktop…`
tokens for custom painting and component geometry. The conversation, navigation,
settings, menus and file views share this theme. Project identity colors and
syntax highlighting have separate meanings and keep their own palettes.

Material's primary color is ink. Filled action buttons, including Send, stay
black when the accent changes. `DesktopAccent.of(context)` supplies the user's
accent, a darker reference color for links, and a translucent selection fill.
Use it for custom editors and focus borders; do not infer accent from
`ColorScheme.primary` or add a local selection color.

`desktopTheme` sets `TextSelectionThemeData`, which MaterialApp also forwards to
`DefaultSelectionStyle`. This keeps SelectionArea, selectable code and ordinary
text fields consistent. Inline code backgrounds stay translucent because
Flutter paints span backgrounds over selection.

Settings → Appearance offers accent presets, a custom `#RRGGBB` value and Reset.
The session owns `AppearanceController`; its immutable states distinguish
loading, committed color, pending write, failure and close. SQLite is an effect,
and the theme changes only after the write commits. Closing cancels pending
operations and ignores late completions. No schema migration is needed: the
accent uses the existing settings store.

Check widgets offscreen. `test/appearance_test.dart` exercises rendered selection,
black buttons, the custom color setting, persistence after reopening, validation
and reset. Use Dart MCP hot reload and read-only runtime probes for the live app.
