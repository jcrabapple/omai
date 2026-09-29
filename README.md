# ohmypi-android

Flutter Android client for the [ohmypi gateway](../ohmypi-gateway). Plan and
task breakdown: `docs/PLAN.md`. Coder rules: `AGENTS.md`.

## Dependencies

Versions pinned exactly in `pubspec.yaml`.

| Package | Why |
|---|---|
| `flutter_riverpod` | State management. Notifiers keep actions out of widgets and are easy to test with overrides. |
| `http` | REST client. Small, `MockClient` makes every error path testable. |
| `flutter_secure_storage` | Gateway token in the Android Keystore, never plain prefs (CLIENTS.md). |
| `shared_preferences` | Non-secret settings: connection list, theme, drafts index. |
| `flutter_markdown_plus` | Markdown rendering for assistant messages. Maintained fork of the archived `flutter_markdown`; pinned to the exact version so rendering stays reproducible. |
| `mocktail` (dev) | Mocks for notifier and client tests. |

## Layout

- `lib/app/` — `MaterialApp` wiring: theme mode (system light = paper, dark =
  the chosen preset), custom accent override, signed-out/signed-in routing,
  the shared `OmpPage` scaffold.
- `lib/theme/` — design tokens. `tokens.dart` is the spacing/radius/type scale
  plus the `OmpTokens` `ThemeExtension`; `presets.dart` ports the four gateway
  presets (terminal, graphite, paper, contrast) from `themes.css` into token
  sets, a Material 3 `ColorScheme` and full `ThemeData` per preset. Widgets
  never use literal colors, only tokens.
- `lib/api/` — pure Dart (no Flutter imports): `models.dart` (tolerant JSON
  models for SessionInfo, SavedSession, CatalogModel, SessionsList),
  `errors.dart` (AuthError, LockedOut, EdgeRefused, GatewayError, Offline) and
  `client.dart` (`GatewayClient`, one typed method per REST endpoint the app
  uses, injectable `http.Client` and timeouts).
- `lib/state/` — Riverpod providers. `connection_store.dart` persists
  connection records in SharedPreferences and tokens in secure storage keyed
  by connection id; `connection_notifier.dart` owns sign in/out and the
  three-legged connection test (healthz, me, WebSocket probe).
- `lib/features/connect/` — the Connect screen: URL and token entry with paste
  helpers, per-failure-class test feedback, sign in.
- `lib/features/home/` — placeholder sessions list (live + saved titles);
  the real grouped list arrives with the sessions task.
