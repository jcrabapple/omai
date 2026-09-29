# Android Client Inspiration: Conduit & RikkaHub

Research report for the oh-my-pi gateway Flutter client. Sources cited inline; everything below is drawn from the repos' READMEs, build files, docs, and issue trackers.

- Conduit: https://github.com/cogwheel0/conduit — Flutter, ~1.9k stars, GPL-3.0. Native iOS+Android client for Open WebUI, direct OpenAI-compatible/Ollama/OpenRouter endpoints, and self-hosted **Hermes agents** (closest analog to our use case).
- RikkaHub: https://github.com/rikkahub/rikkahub — Kotlin/Jetpack Compose, ~6k stars. Multi-provider LLM chat client with MCP tools, agents, and a proot Linux "Workspace".

---

## 1. Conduit (Flutter — prioritize; we share the stack)

### Features relevant to a chat/agent client
Source: README + `docs/BUILDING.md` (https://github.com/cogwheel0/conduit/blob/main/docs/BUILDING.md)
- **Three connection types** in one app: Open WebUI server, direct provider connections (OpenAI-compatible, Ollama, OpenRouter; keys/headers in secure storage), and **Hermes self-hosted agents**.
- **Hermes agent support is the gold standard for us**: an `hermes/` feature module with "Hermes Agent transport, approvals, scheduled jobs" — i.e., the app already models an agent that runs tools, asks before sensitive steps, and works on a schedule. Exactly our approval/steal flow.
- Token-by-token streaming over WebSocket with a **`BackgroundStreamingService` Android foreground service** so streaming survives backgrounding (README's core motivation: "streaming that drops when the app backgrounds").
- Chat management: search across conversations, folders, pinning, temporary chats, message branching (recursive-CTE active-branch paging in Drift, schema v9).
- Attachments: images (picker + compress), screenshots into prompt, PDFs (pdfrx), file picker; share-intent input via `flutter_sharing_intent`.
- Voice call mode (VAD + record + `flutter_callkit_incoming` for incoming-call UX), on-device and server STT, TTS.
- **Home screen integration**: `quick_actions` (home-screen shortcuts), `home_widget` (Android/iOS home widgets), `flutter_local_notifications` with a notifications "routing and gating" feature module.
- Rich rendering: markdown + syntax highlighting, native Mermaid (vendored packages), KaTeX/flutter_tex math, chart.js in webview, PDF viewer.
- WebSocket terminal feature (xterm) + file browser against the server.
- Notes (Fleather rich-text editor), workspace models/knowledge/prompts/tools, channels with threaded messaging, prompts with variable UI.

### UX patterns worth stealing
- **Adaptive navigation shell**: dedicated `features/navigation/` with "chat shell, drawer, adaptive navigation" — drawer-based conversation list on phones, adaptive (likely split) on large screens.
- **Streaming that never loses your place**: transcript viewport with scroll anchoring, pin-to-top lifecycle, follow-latest modes (`ChatTimelineViewport`, PR #593) — pinned prompts stay put while the response grows. Critical for reading agent tool-activity on a phone.
- **First-launch connection picker**: "choose Open WebUI / direct provider / Hermes" onboarding; nothing forces server sign-in.
- Composer: image/screenshot capture, share-intent prefill ("start a chat from the home screen"), prompt-variable UI, voice input.
- Platform polish: haptics via `gaimon`, wakelock during streaming/voice, quick actions + home widget, native splash themed dark/light, Geist/Geist Mono custom type, `adaptive_platform_ui` for platform-adaptive chrome.
- Reconciliation UX: reopening a chat mid-stream re-syncs from server snapshot + socket resume with gap detection (PR #593) — users never see a stuck "streaming" state.

### Tech stack (pubspec.yaml, https://github.com/cogwheel0/conduit/blob/main/pubspec.yaml)
- Flutter/Dart ≥3.13 (main branch; releases pin 3.9+), Android API 24+, Java 17, AGP 9.
- **State: `flutter_riverpod ^3.1.0` + `riverpod_generator ^4.0.0` + `riverpod_lint`** (codegen providers, freezed models `freezed ^3.2.0` / `json_serializable`).
- **Routing: `go_router ^17.0.0`**.
- **Networking: `dio ^5.9.0`** for API + **`socket_io_client ^3.1.2`** for Open WebUI streaming, `web_socket_channel ^3.0.3` for Hermes/other transports; typed clients `openai_dart ^7.0.1`, `ollama_dart ^2.4.0`.
- **Storage: `drift ^2.34.2` + `drift_flutter`** (SQL local DB, FTS), `hive_ce ^2.14.0`, `shared_preferences`, **`flutter_secure_storage ^10.0.0`** for keys/tokens.
- Markdown/UI: `markdown ^7.3.0`, `flutter_highlight`/`highlight`, `flutter_tex`, vendored `mermaid_flutter` (path deps), `flutter_inappwebview ^6.2.0-beta.3`, `flutter_animate`, `stupid_simple_sheet`.
- Platform: `quick_actions`, `home_widget`, `flutter_local_notifications ^22`, `flutter_sharing_intent`, `share_plus`, `image_picker`, `file_picker`, `record`/`vad`/`audio_session`, `flutter_callkit_incoming`, `connectivity_plus`, `wakelock_plus`, `gaimon` (haptics), `xterm` (terminal), `geolocator`, `just_audio`, `url_launcher`.
- Folder structure (`lib/`): `core/` (auth, routing, models, networking, database/Drift, services) + `features/` (auth, channels, chat, direct_connections, **hermes**, navigation, notes, notifications, profile, prompts, terminal, tools, workspace) + `l10n/` + `shared/` (widgets, theme tokens). Warning from their own docs: `core/services/api_service.dart` grew to ~6000 lines — avoid one god API client; split per endpoint family.

### Complaints / things done poorly (issues)
- **Streaming foreground-service crashes** on server bumps: `ForegroundServiceDidNotStartInTimeException` from `BackgroundStreamingService` broke the app for everyone after an Open WebUI release (https://github.com/cogwheel0/conduit/issues/444). Lesson: the background-streaming service is high-risk, needs strict startForeground discipline and testing against server breaking changes.
- **Streaming-state reconciliation is genuinely hard**: PR #593 ("reconcile streaming chats after reopen", +17k lines) shows reopened chats could get stuck `isStreaming`, lose the streaming tail, double-poll, or finalize unobserved Hermes checkpoints (https://github.com/cogwheel0/conduit/pull/593). Budget real time for "open app → resume in-flight agent run" correctness.
- Voice pipeline fragility: TTS skips responses with large contexts (https://github.com/cogwheel0/conduit/issues/436); on-device STT cuts mid-word on some OEM/Android-16 builds (https://github.com/cogwheel0/conduit/issues/401).
- Tight coupling to server version (each Open WebUI release needs a coordinated app release — they ship "support v0.11.x" releases). For us: version the gateway API defensively.
- Monolithic api_service.dart (~6k lines) acknowledged as a maintainability hazard.

---

## 2. RikkaHub (Kotlin/Compose — patterns to steal, stack differs)

### Features relevant to a chat/agent client
Source: README + CLAUDE.md (https://github.com/rikkahub/rikkahub, https://github.com/rikkahub/rikkahub/blob/master/CLAUDE.md)
- Multi-provider (OpenAI/Google/Anthropic-compatible), custom headers + request bodies, QR-code import/export of provider configs.
- **MCP tool support**; tool-call steps rendered per-message with **interactive approve/deny elements** (`ChatMessageToolStep` with "interactive elements for approval or denial", plus an `AskUserToolStep` for mid-generation user input) — direct precedent for our approvals UI.
- **Assistant system**: per-assistant isolated configs — system prompt, temperature, context size, tools, memory, regex transforms, prompt injections with position/depth options; ChatGPT-like memory; prompt variables (model name, time).
- **UIMessage content-parts model**: text, images, documents, **reasoning parts**, **tool calls/results** with streaming chunk-merging — a clean canonical message model that handles thinking + tool activity natively.
- Message **transformer pipeline** (input/output): ThinkTag→reasoning, templates, OCR, regex, base64→file, document-as-prompt; output transformers have `visualTransform()` for live streaming display and `onGenerationFinish()` for finalization.
- Reasoning budget picker in the composer (OFF/AUTO/LOW…MAX), web-search toggle with service picker (Exa/Tavily/Brave/SearXNG/…), MCP server picker, workspace (proot Linux sandbox) binding — all as composer "ToggleSurface" popovers.
- Message branching, SillyTavern character-card import, translation, TTS/ASR module, embedded Ktor web server exposing the same app on the LAN ("Web access for multi-platform use").
- Multimodal input: images, PDF/DOCX (document parsing module), camera, image viewer with zoom.

### UX patterns worth stealing
- **Adaptive drawer**: `PermanentNavigationDrawer` when width ≥1100dp, `ModalNavigationDrawer` with swipe on phones (https://deepwiki.com/rikkahub/rikkahub/4-core-chat-system) — the canonical Compose answer; replicate in Flutter.
- **Composer as control center**: model chip + per-conversation toggles (reasoning level, web search, MCP tools, workspace) as quick popover surfaces from the input bar. Perfect shape for "steer the agent" from a phone.
- **Per-tool inline UI in the transcript**: each tool call renders as its own step card with approve/deny and ask-user inputs — better than a modal approval dialog for agent activity reading.
- **Reasoning display as first-class message parts** (collapsible reasoning sections, not buried).
- **Share-intent handling** prefills chat with text/files (handled in `ChatPage`).
- Material You dynamic color + dark mode; per-feature model assignment (chat/title/OCR/translate each get a model — nice "cheap model for titles" pattern); toast system (`sonner`); Lucide icon set; QR-code config sharing for zero-typing setup on a phone.

### Tech stack (gradle/libs.versions.toml)
Compose BOM 2026.08.00, Material3 (adaptive + Navigation 3), Kotlin 2.4, **Koin DI**, **Room** (+Paging) + sqlite-vector, **DataStore**, **OkHttp 5 + okhttp-sse** for streaming, Retrofit, kotlinx-serialization, coroutines, WorkManager, Coil 3 (images/svg/gif), JLatexMath + custom markdown renderer fork (com.github.rikkahub:markdown) for high-perf streaming markdown, QuickJS (embedded JS), MCP SDK 0.15.0, Pebble templates, zxing/quickie (QR), termux (proot), Ktor (embedded web), Firebase Crashlytics. Module split: `app` / `ai` (provider SDK abstraction) / `document` / `highlight` / `search` / `speech` / `web` / `common`.

### Complaints / things done poorly (issues)
- **Long-chat scroll-position bugs**: opening a long conversation could land at the top instead of the latest message; fixed with timing rework (#1077, closes #1018). We must handle "land on newest agent activity instantly".
- **Streaming perf on web**, and token-usage stats freezing/jumping during multi-round tool calls (usage settled per-round, wrote early `finishedAt`) (#1059/#1030). Lesson: aggregate usage/rounds at end of the full tool chain, not per chunk.
- **Tool-call argument corruption**: JSON built by string concatenation broke on backslashes and large writes in the Workspace agent — "A simple task becomes an hour-long chunked slog… this app is nice" (issue linked from search; tool-call transport). Lesson: strict JSON encoding + framing/checksums for tool arguments, chunked-transfer errors surfaced clearly.
- **Prompt-injection as separate user message broke Anthropic prompt caching** (#1101) and injection placement UX complaints (#696). Lesson: how you inject context (approvals, steering, system additions) has real token-cost consequences.
- Conversation-search/memory tools returning wrong results (#1488).

---

## Top 10 ideas to steal (ranked for: notify → open → read → approve → steer → pocket)

1. **Per-tool inline activity cards with approve/deny in the transcript** (RikkaHub `ChatMessageToolStep`, Conduit Hermes approvals module) — no modal dialogs; the agent's run is a scrollable list of tool steps you can act on in place.
2. **Resume-in-flight-runs correctly**: server snapshot + socket resume + gap detection on reopen (Conduit PR #593), with a hard guarantee that a chat never sticks in "streaming" — the single biggest engineering risk both apps hit.
3. **Timeline viewport with scroll anchoring + follow-latest** (Conduit `ChatTimelineViewport`): content grows under a pinned position; "jump to latest" chip; open straight to the newest activity, not the top of the chat (RikkaHub bug #1077 shows what happens otherwise).
4. **Notification → deep link into the exact chat/approval**, with a foreground-service streaming notification while a run is active (Conduit's `BackgroundStreamingService` + `flutter_local_notifications` gating) — but build it with Conduit's crash (#444) in mind.
5. **Composer steering chips** (RikkaHub): model chip + quick popovers for reasoning level / tools / MCP — repurpose as per-conversation steering (model, effort, tools on/off) without leaving the keyboard.
6. **Local-first storage with reconciliation** (Conduit 4.0: chats live on-device, Drift DB, server is a sync source) — the app must be readable and even responsive when the gateway is unreachable.
7. **Canonical content-parts message model** (RikkaHub UIMessage: text/reasoning/tool-call/tool-result parts, chunk-merging) — makes streaming, thinking display, and tool rows a rendering problem, not a protocol problem.
8. **Home-screen entry points**: quick actions ("resume last session", "new chat") + home widget showing agent status (Conduit `quick_actions` + `home_widget`) — "pocket it" means one tap from lock screen to answer an approval.
9. **Share-intent + screenshot capture into the composer** (both apps): paste a screenshot or shared text to steer the agent with context.
10. **Secure + zero-typing setup**: keys in secure storage (Conduit), QR export/import of connection configs (RikkaHub) — point your phone's camera at the gateway to onboard.
