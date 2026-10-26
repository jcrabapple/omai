# Omai

Omai is an Android client for [ohmypi-gateway](https://github.com/jcrabapple/ohmypi-gateway),
the HTTP/WebSocket gateway over oh-my-pi (`omp`). It puts a terminal agent on your phone: sign
in to your own gateway with a URL and token, watch sessions stream, answer approvals, send
follow-ups, and get a notification when a turn needs you.

Because it talks only to the gateway's public API, it needs no root, no SSH client, and no
knowledge of where `omp` is installed. The gateway stays on your desktop; the phone reaches it
through whatever tunnel you already use.

- App id `us.snakepit.omai` (debug builds install side by side as `.debug`)
- Pairs with the gateway's `docs/API.md`; this repo's build plan is in `docs/PLAN.md`
- MIT licensed, unaffiliated with oh-my-pi: see [NOTICE.md](NOTICE.md)

## What it does

- **Connections**: one or more gateways, each with its own token; the token lives in the
  Android Keystore via `flutter_secure_storage`, never in plain preferences. Sign-in runs a
  three-legged check (health, identity, WebSocket probe) and reports which leg failed.
- **Sessions**: live sessions grouped the way the web client groups them, plus saved
  transcripts you can resume.
- **Session view**: streaming transcript with markdown, tool cards, plans, and diffs;
  approvals appear inline and block the turn until you answer.
- **Composer**: text, queued follow-ups, image attachments from camera or library, and the
  gateway's model and thinking-level switches.
- **Command palette and search** across sessions.
- **Themes**: the four gateway presets (terminal, graphite, paper, contrast) plus a custom
  accent, matching the web client's tokens.
- **Keep-alive**: a `dataSync` foreground service (plain Kotlin, no plugin) that keeps a live
  stream flowing while the app is backgrounded, with notification actions and app shortcuts.
  It stops when the turn ends, you tap Stop, or the app returns to the foreground.

## Build

Requires Flutter (stable, Dart 3.13+) and the Android SDK.

```sh
flutter pub get
flutter test          # ~900 unit and widget tests, no device needed
flutter analyze
flutter run           # debug build on a connected device
```

Release builds sign with `android/key.properties` (`storeFile`, `keyAlias`, `storePassword`,
`keyPassword`), which is gitignored along with `**/*.jks`. Without it, Gradle builds an
unsigned release; the app itself never embeds a key.

Debug builds allow cleartext only to `127.0.0.1`, `localhost` and `10.0.2.2`, so
`adb reverse tcp:9325 tcp:9325` can point the app at a test gateway. Release builds keep
cleartext disabled.

## Dependencies

Versions pinned exactly in `pubspec.yaml`; `pubspec.lock` is committed.

| Package | Why |
|---|---|
| `flutter_riverpod` | State management. Notifiers keep actions out of widgets and are easy to test with overrides. |
| `http` | REST client. Small, `MockClient` makes every error path testable. |
| `flutter_secure_storage` | Gateway token in the Android Keystore, never plain prefs. |
| `shared_preferences` | Non-secret settings: connection list, theme, drafts index. |
| `flutter_markdown_plus` | Markdown rendering for assistant messages. Maintained fork of the archived `flutter_markdown`; pinned to the exact version so rendering stays reproducible. |
| `image_picker` | Photo library and camera attachments in the composer; the platform photo picker needs no permissions on API 33+. |
| `mocktail` (dev) | Mocks for notifier and client tests. |
| `fake_async` (dev) | Virtual time for polling and timer tests. Already in the graph via `flutter_test`; declared directly so the import is lint-clean. |

### Android-native, no extra packages, deliberately

The foreground service, notifications, share intent, shortcuts and adaptive icon are plain
Kotlin plus manifest declarations (`KeepaliveService.kt`, `KeepaliveActionReceiver.kt`,
`MainActivity.kt`), behind one MethodChannel (`us.snakepit.omai/native`) and the Dart-side
`KeepaliveSurface` interface (`lib/native/`). Evaluated alternatives, both rejected to keep the
dependency graph unchanged:

- `flutter_foreground_task`: one plugin cannot also post the separate high-priority approval
  notifications this app needs, its TaskHandler isolation semantics have changed across major
  versions (v6-v10), and the service is a process keep-alive only, about 150 lines of boring
  Kotlin we fully own.
- `flutter_local_notifications`: would add a plugin (plus its manifest merge) for posting and
  action-routing the service and channel code above already does.

Foreground-service type is `dataSync`: the service exists so a live session stream (a running
agent turn) keeps flowing in the background, which is the textbook data-sync case.
`remoteMessaging` is for chat apps replying to notifications; `specialUse` requires a Play
policy justification for something no listed type covers. The Android 15 six-hours-a-day
`dataSync` budget is not a practical limit, because the service only runs while a turn is
active.

## Layout

- `lib/app/` — `MaterialApp` wiring: theme mode (system light = paper, dark = the chosen
  preset), custom accent override, signed-out/signed-in routing, the shared `OmpPage` scaffold.
- `lib/theme/` — design tokens. `tokens.dart` is the spacing/radius/type scale plus the
  `OmpTokens` `ThemeExtension`; `presets.dart` ports the gateway presets into token sets, a
  Material 3 `ColorScheme` and full `ThemeData` per preset. Widgets never use literal colors.
- `lib/api/` — pure Dart (no Flutter imports): tolerant JSON models, a typed error hierarchy
  (auth, lockout, edge refusal, offline), and `GatewayClient` with one method per REST
  endpoint, an injectable `http.Client` and explicit timeouts.
- `lib/stream/` — the session stream client and its scheduler: reconnect with backoff,
  cursor-based resume through the gateway's event backlog, reducer-friendly frame batches.
- `lib/state/` — Riverpod providers: connections (secure storage keyed by connection id),
  sessions, active session, settings.
- `lib/features/` — one directory per surface: `connect`, `sessions`, `session`,
  `new_session`, `palette`, `search`, `settings`.
- `lib/native/` — the Dart side of the MethodChannel and the keep-alive surface.
- `android/` — Kotlin service, receiver, activity, manifest, shortcuts, adaptive icon.
- `test/` — unit and widget tests, including manifest assertions (INTERNET present in release,
  no cleartext enabled, launcher labels) that fail the build if the Android surface regresses.

## License

MIT. See [LICENSE](LICENSE).
