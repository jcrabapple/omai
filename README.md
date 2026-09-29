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
| `fake_async` (dev) | Virtual time for polling and timer tests. Already in the graph via `flutter_test`; declared directly so the import is lint-clean. |

### Android-native (Task F): no new packages, deliberately

The foreground service, notifications, share intent, shortcuts and adaptive
icon are all plain Kotlin + manifest declarations (`KeepaliveService.kt`,
`KeepaliveActionReceiver.kt`, `MainActivity.kt`), behind one MethodChannel
(`us.snakepit.ohmypi/native`) and the Dart-side `KeepaliveSurface` interface
(`lib/native/`). Evaluated alternatives, both rejected to keep the dependency
graph unchanged:

- `flutter_foreground_task`: one plugin cannot also post the separate
  high-priority approval notifications the plan needs, its TaskHandler
  documentation has changed isolation semantics across major versions
  (v6-v10), and the service is a process keep-alive only, about 150 lines of
  boring Kotlin we fully own.
- `flutter_local_notifications`: would add a plugin (plus its manifest
  merge) for posting and action-routing the service/channel code above
  already does.

Foreground-service type is `dataSync`: the service exists so a live session
stream (a running agent turn) keeps flowing in the background, which is the
textbook data-sync case. `remoteMessaging` is for chat apps replying to
notifications; `specialUse` requires a Play-policy justification for
something no listed type covers. The Android 15 6h/day `dataSync` budget is
not a practical limit: the service only runs while a turn is active and is
stopped when the turn ends, the user taps Stop, or the app returns to the
foreground.

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
