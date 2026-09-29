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
| `mocktail` (dev) | Mocks for notifier and client tests. |
