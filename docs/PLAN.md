# ohmypi Android: build plan

Flutter client for the ohmypi gateway (`~/projects/ohmypi-gateway`). It mirrors
the Svelte web dashboard (`web/` in that repo) and is built for the phone
supervision loop: get notified, open, read what the agent is doing, answer an
approval, steer, pocket it.

Roles: orchestrator Opus 5.5 (Hermes session, owns this plan, commits).
Coder glm-5.3-flashx via Nous Portal (Hermes `delegate_task`). Review Gemini
3.8 Flash via `agy`. Coder rules: `AGENTS.md`.

## Decisions (Jason, 2026-09-29)

- **Flutter**, not Capacitor or Kotlin. This departs from the gateway repo's
  `docs/CLIENTS.md` recommendation; everything else in CLIENTS.md still applies.
- **No push in v1.** A foreground service keeps the session WebSocket open only
  while the user follows a running turn (ongoing notification with Stop).
  While it runs, a new approval raises a local notification with Approve / Deny
  actions. FCM or UnifiedPush comes later.
- Single gateway connection in v1, but every persisted key is namespaced by
  connection id from day one (CLIENTS.md rule 6).

## Sources of truth

| What | Where (gateway repo) |
|---|---|
| Wire contract | `docs/API.md`, live `GET /api/openapi.json` |
| Design intent | `docs/DESIGN.md` |
| Client architecture rules | `docs/CLIENTS.md` |
| Behaviour to port | `web/src/lib/**` (pure TS, tested) |
| Conformance fixtures | `web/src/lib/**/__fixtures__/*.json` (trimmed, redacted) |
| Inspiration | this repo, `docs/research/android-inspiration-*.md` |

Porting rule: the web client's `lib/api`, `lib/transcript`, `lib/render/diff2`,
`lib/state/grouping`, `lib/composer/*` are the behaviour spec. Port behaviour
and their tests; do not invent new semantics. When the web code and API.md
disagree, stop and report.

## Stack

- Flutter 3.47 stable, Dart 3.13, Material 3. `~/development/flutter/bin`.
- State: `flutter_riverpod` 3 (Notifier / AsyncNotifier; no codegen).
- HTTP: `package:http`. WebSocket: `dart:io` `WebSocket.connect` (bearer header
  on the upgrade works natively, so no first-message auth needed).
- Secrets: `flutter_secure_storage` (Keystore-backed). Prefs:
  `shared_preferences`.
- Later tasks add (each justified in README.md when added): a markdown
  renderer, a highlighter, a local cache (sqlite or hive), a foreground-service
  plugin, local notifications, share intent receiver.
- minSdk 26, target/compile from Flutter defaults (36). App id
  `us.snakepit.ohmypi`, label "ohmypi".

## Layout

```
lib/
  main.dart               ProviderScope + App
  app/                    MaterialApp, router, theme wiring
  theme/                  tokens + 4 presets ported from web themes.css
  api/                    GatewayClient (http), errors, models (session info, saved, catalog)
  stream/                 SessionStream (WebSocket transport)
  wire/                   omp message/event/UiRequest types, narrow JSON accessors
  transcript/             pure reducer + Item types + diff extraction (no Flutter imports)
  state/                  Riverpod providers: connection, sessions, active session, settings
  features/<name>/        screens and widgets per feature
  platform/               haptics, notifications, foreground service, share intent
test/                     mirrors lib/; fixtures under test/fixtures/
```

`transcript/`, `wire/`, `stream/` and `api/` import nothing from Flutter
(pure Dart, testable with `dart test` semantics via `flutter test`).

## Tasks

Each task: one coder run, then `agy` review, fixes, orchestrator commit.
File ownership is listed so parallel tasks never touch the same files.

### A. Foundation (parallel with C)

Owns `lib/main.dart`, `lib/app/**`, `lib/theme/**`, `lib/api/**`,
`lib/state/connection*.dart`, `lib/features/connect/**`, matching tests.

- Theme: port the four presets (terminal, graphite, paper, contrast) from
  `web/src/styles/themes.css` + spacing/radius/type tokens from `tokens.css`
  into a `ThemeExtension<OmpTokens>` plus a Material 3 `ColorScheme` per
  preset. Custom accent override. Follow-system light/dark picks paper vs the
  chosen dark preset. Tokens only in widgets, never literal colors.
- `GatewayClient`: base URL + bearer token, typed methods for every REST
  endpoint in API.md that v1 uses (health, me, system, sessions list/start/
  get/delete, prompt, abort, state, messages, stats, model, thinking, name,
  commands, events, ui list/answer, catalog/models, skills, usage, rpc).
  Timeouts. Error classes: `AuthError` (confirmed 401 only), `LockedOut`
  (429 on auth), `EdgeRefused` (Cloudflare 400 with an HTML body),
  `GatewayError` (JSON `{error}`), `Offline` (socket/timeout/5xx). Only
  `AuthError` ever signs the user out.
- Models: `SessionInfo`, `SavedSession`, `CatalogModel`, `SessionsList` with
  tolerant `fromJson` (unknown fields ignored, missing optional fields null).
  `pendingUi` stays `List<Map<String, Object?>>` until C's `UiRequest` lands.
- Connection: store `{id, url, label}` in prefs and the token in secure
  storage keyed by connection id. Connect screen: URL + token fields, paste
  helpers, "Test connection" that checks `/healthz`, `GET /api/me`, AND opens
  a WebSocket to a throwaway check (see note) so a broken WS leg fails the
  test. Clear copy for each failure class.
  Note: WS test = open `/omp-ws/<gwId>` of any live session if one exists,
  else report "HTTP OK, WebSocket not verified (no live session)"; do not
  start sessions from the connection test.
- App shell: signed-out -> Connect; signed-in -> placeholder home listing
  live + saved session titles (proves the client end to end).
- Tests: client against `MockClient` (every error class), model parsing
  against `test/fixtures/session-info.json` and `sessions-list.json`
  (copy from gateway `web/src/lib/api/__fixtures__/` and derive a trimmed
  sessions list with fake paths), theme token completeness per preset.

### B. Transport (after A)

Owns `lib/stream/**`, `test/stream/**`.

Port `web/src/lib/api/stream.ts` (read it fully, and its tests) to Dart:
states connecting/live/retrying/offline/gone, seq dedupe + cursor, full-jitter
backoff (1s base, 30s cap), stable-open rule (5s after auth_ok before the
attempt counter resets), 60s watchdog, `auth_ok.gap` -> resync with events held
until `rebase(lastEventSeq)` (15s hold timeout), close codes 4401 signed out /
4404 gone / 4408 reconnect / 4429 lockout (60s), app lifecycle: close on
`paused`, reconnect on `resumed`, resync if paused > 5 min. Injectable socket
factory, clock and random for tests. Port every stream test case.

### C. Transcript reducer (parallel with A)

Owns `lib/wire/**`, `lib/transcript/**`, `test/wire/**`, `test/transcript/**`,
`test/fixtures/transcript/**`.

Port `web/src/lib/transcript/{types,reducer,blocks,changes}.ts`, the
`UiRequest`/`isBlockingUi` bits of `lib/api/types.ts`, `lib/composer/send.ts`
(`sendNote`) and `lib/render/diff2.ts` (`parseOmpDiff`, `extractFiles`) to
pure Dart. Immutable items (final fields + `copyWith`), sealed `Item` class.
Copy the web fixtures from `web/src/lib/transcript/__fixtures__/` and port
every case in the web `__tests__` for those modules. The conformance property
that must hold: feeding a turn's `/messages` history and the same turn's live
events through the reducer yields equal items (ignoring `raw` and timing).

### D1. Sessions list + session view (after A, B, C)

Attention-grouped list (port `lib/state/grouping.ts`): Needs you / Ready for
review / Running / Idle / History by day. Rows: title, cwd basename, status
glyph, relative time; amber dot outranks spinner. Pull to refresh, stale-first
cache. Session screen: header (name, model, context meter, cost), transcript
with user bubbles right, assistant full width markdown, collapsed thinking
("thought for 12s"), tool activity rows grouped and expandable, notices,
command output with ANSI colors, skill chip, jump-to-latest pill, auto-follow
only when at bottom. Open sequence exactly per API.md (info -> messages ->
socket `after=lastEventSeq`).

### D2. Composer + approvals + new session (after D1)

Composer: auto-grow, send button (Enter = newline on touch), while running a
split action Steer / Queue / Stop, per-session drafts that survive app kill
and session death, durable send (keep text until ack; failure shows retry).
Approval takeover replaces the composer: title + exact command, one 48dp
button per option, confirm Yes/No, input/editor text, "1 of N", haptic on
answer, `ui_resolved` clears it. New session sheet: cwd (recent list),
model, thinking, approval mode; resume from history (`resumeFrom`,
`alreadyLive`, `cwdFallback` notice). Rename, stop session.

### E. Power layer (after D2)

`/` slash menu from `/commands` with fuzzy filter; model picker (catalog
cached on device) and thinking chip; plan panel + ribbon (`todoPhases`);
diff view for edit/write results + per-session Changes page; message
actions (copy, inspect raw JSON, retry via `/retry`); image attach (camera,
gallery, paste) through the prompt `images` field; search across sessions
(titles) in a palette sheet; settings: appearance (preset, accent, density,
text size), connection, models, skills, usage (read-only views).

E1 (plan panel, diffs/Changes, message actions, stats for nerds) shipped.
E2 is split in two parallel tasks with disjoint files. Neither touches
`lib/features/sessions/sessions_screen.dart` or `lib/app/app.dart`'s
MaterialApp wiring beyond what is listed; the orchestrator wires the entry
points (app-bar search icon, overflow "Settings") after both land.

**E2a. Settings + diagnostics.** Owns `lib/features/settings/**`,
`lib/state/appearance_store.dart`, `lib/app/app.dart` (replace the
placeholder `DarkPresetNotifier`/`AccentOverrideNotifier` with the persisted
store; MaterialApp `theme`/`darkTheme`/`themeMode`/`builder`), `lib/theme/**`
(density + text size plumbing only), tests under `test/features/settings/**`
and `test/state/appearance_store_test.dart`. Pages, ported from
`web/src/components/settings/*`: Appearance (preset cards, follow system,
accent swatches from `web/src/lib/state/accents.ts` + theme default, density,
text size), Connection (`/api/system` rows, signed-in method from `/api/me`,
sign out with confirm), Diagnostics (health, auth, WebSocket leg, omp
version, catalog reachable; each row pass/fail/unknown with a fix hint;
re-runnable), Models (catalog list with search, read-only), Skills, Usage
(ANSI report via `lib/render/ansi.dart`, refresh). Public entry:
`SettingsScreen({SettingsPage? initial})` + `enum SettingsPage`.

**E2b. Search palette + image attach.** Owns `lib/palette/**`,
`lib/features/palette/**`, `lib/composer/images.dart`,
`lib/features/session/composer.dart`, `lib/features/session/image_tray.dart`,
`lib/state/session_controller.dart` (send/retry with images only),
`pubspec.yaml` + `README.md` (dependency `image_picker`), Android manifest
entries image_picker needs, tests under `test/palette/**`,
`test/features/palette/**`, `test/composer/images_test.dart`,
`test/features/session/composer_test.dart`. Palette: port
`web/src/lib/palette/{fuzzy,palette}.ts` minus desktop-only items (shortcuts,
theme toggle, slash); items = actions (New session, Next session that needs
you, Settings pages), live sessions, history; ranking tests ported. Public
entry: `showPaletteSheet(context, {required PaletteActions actions})` with
actions injected. Images: gallery (multi) + camera via `image_picker`,
Gboard/keyboard image insertion via `contentInsertionConfiguration`; rules
from `web/src/lib/composer/images.ts` (max 4, png/jpeg/webp/gif, 5 MB);
downscale camera/gallery picks so a phone photo fits; thumbnail tray with
remove; images-only send allowed; a failed send keeps its images for Retry.

### F. Android native (after D2, parallel with E where files don't overlap)

Foreground service (type `dataSync` or `remoteMessaging`, whichever Play
policy fits; justify) that holds the socket for sessions the user is
following while a turn runs; ongoing notification "Running: <title>, 3m" with
Stop; ends when the turn ends. Local notification on new blocking dialog while
the service runs, with Approve / Deny actions answered via REST without
opening the app; tapping opens the session. Share intent (text/URL) -> new
prompt sheet. Launcher shortcut "Needs you". Adaptive icon.

### Folded in from the inspiration research

Assigned to the task that owns the surface:

- D1: open a session at the newest activity, never the top (RikkaHub bug
  #1077). A session can never stick in "streaming": `agent_end`, a resync, or
  `isStreaming:false` in fresh info always clears it (Conduit's biggest
  reliability bug class).
- D1: live activity line in the header while running (current tool, elapsed)
  so a six-minute turn never reads as a hang.
- E: diagnostics page (Relay's capability card): health, auth, WS leg, omp
  version, catalog reachable, each with a fix hint. Reused after connect.
- E: "Stats for nerds" in session info: TTFT, tokens/sec, stream reconnects.
- F: launcher quick actions (New session, Needs you) and a home-screen
  widget showing the needs-you count, later.
- Later (needs gateway work, not v1): QR pairing (URL + token) shown by the
  dashboard's Settings > Connection; multiple routes per connection (LAN,
  tunnel) with failover.

## Verification per task

- `flutter analyze` clean, `flutter test` green, `flutter build apk --debug`
  succeeds.
- From D1 on: install on the `test_api36` emulator, launch, drive the flow
  against a gateway test instance on 127.0.0.1:9325 (emulator reaches host
  loopback via `10.0.2.2`), `adb logcat` has no crash. Screenshots saved to
  `docs/screens/` for review.
- `agy` review of the diff; fixes; re-review when findings were substantive.
