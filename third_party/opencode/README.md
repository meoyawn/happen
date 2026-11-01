The Dart session schema, SQLite projection, Flutter conversation presentation,
context inspector, and composer are adapted from OpenCode:

- `packages/schema/src/session-message.ts`, `session-event.ts`, `token-usage.ts`
- `packages/core/src/session/sql.ts`
- `packages/session-ui/src/`
- `packages/gui-plugins/src/context/`
- `packages/app/src/runtime/plugin/side-region.tsx` and `panels.tsx`
- `packages/app/src/session/session-panel-width.ts`
- `packages/app/src/composer/` (editor interactions and completion presentation)
- `packages/ui/src/components/file-icon.tsx` (file and folder associations)
- `packages/ui/src/assets/icons/file-types/` (314 bundled SVG icons)

Source: https://github.com/anomalyco/opencode. Happen retains WebSocket transport,
Flutter rendering, and a separate SQLite database with one writer per session.
The upstream MIT license is included here. Bundled font licenses live beside
the fonts in `packages/desktop/assets/fonts/`.
