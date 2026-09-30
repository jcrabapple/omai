# Omai (ohmypi-android): rules for coding agents

Omai is the Flutter Android client for the ohmypi gateway. The app is named
Omai, never "ohmypi"; Dart package `omai`, app id `us.snakepit.omai`. Read `docs/PLAN.md` first: it
holds the task you are on, the file ownership for that task, and the sources
of truth. The gateway repo is `~/projects/ohmypi-gateway`; its `docs/API.md`
is the wire contract and `web/src/lib/**` is the behaviour spec you port.

## Toolchain

```sh
export PATH="$HOME/development/flutter/bin:$HOME/Android/Sdk/platform-tools:$PATH"
export JAVA_HOME="$HOME/.local/share/jbr"
flutter analyze && flutter test && flutter build apk --debug
```

## Hard rules

- Never read, print, copy, or commit `~/projects/ohmypi-gateway/auth-token`,
  `gateway.env`, or anything under `~/.omp/`, `~/.cloudflared/`, `~/.hermes/`.
  A test script may read `auth-token` at runtime; never echo it or bake it
  into code, fixtures, or logs.
- Never restart, stop, or edit `ohmpi-gateway.service` or
  `cloudflared-ohmypi.service`, and never kill processes you didn't start.
  For live testing run your own gateway:
  `cd ~/projects/ohmypi-gateway && .venv/bin/uvicorn gateway.main:app --host 127.0.0.1 --port 9325`
  and stop it when done. Sessions you create must be DELETEd before you
  finish; never touch sessions you didn't create.
- Don't `git commit`, `git push`, or change branches. The orchestrator
  reviews and commits.
- Don't edit anything in `~/projects/ohmypi-gateway`. Copy fixtures from it
  into `test/fixtures/`; if a fixture contains a home path or user name,
  replace it with `/home/user/...`.
- Only touch the files your task owns (listed in `docs/PLAN.md`). Don't
  refactor unrelated code. Don't edit `docs/PLAN.md` or this file.
- Don't add dependencies unless your task says so. When you do: exact
  version pin in `pubspec.yaml`, one line of justification in `README.md`.

## Conventions

- Dart 3, sound null safety, no `dynamic` except at the JSON boundary,
  narrowed immediately with small typed accessors. No `!` on values that can
  legitimately be null; handle the case.
- `lib/wire`, `lib/transcript`, `lib/stream`, `lib/api` import nothing from
  Flutter. Keep them pure and injectable (clock, random, http client, socket
  factory) so tests are deterministic.
- Riverpod 3: `Notifier`/`AsyncNotifier` + `NotifierProvider`; no codegen,
  no `StateProvider` for anything non-trivial. Widgets read state, actions
  live on notifiers.
- Colors, spacing, radii and text styles come from the theme tokens
  (`lib/theme`). No literal colors or magic dimensions in widgets.
- User-facing copy: plain, short, no em-dashes, no exclamation marks, no
  "Loading..." (use a skeleton or a small progress indicator).
- Accessibility: semantics labels on icon buttons, 48dp touch targets,
  text scales with the system font size, contrast from the tokens.
- When porting from TypeScript, keep function and field names recognisable
  (camelCase is the same in Dart) so the two codebases can be diffed by eye.
  Port the tests too; they are the conformance suite.

## Before you say you're done

- `flutter analyze` reports no issues.
- `flutter test` passes.
- `flutter build apk --debug` succeeds.
- Report exactly which commands you ran and their results, the files you
  created or changed, and anything you could not finish or chose to defer.
  If something failed and you couldn't fix it, say so plainly. Do not
  delete, skip, or weaken tests to make them pass.
