# Android Client Research: Hermes Relay & "Hermes Go"

Researched 2026-09-29 for the omp-gateway Flutter Android client (sessions, streaming transcript, tool-call rows, approvals, slash commands, model picker).

**Bottom line up front:** Hermes Relay is real, mature, and heavily documented (188★, Kotlin + Jetpack Compose, MIT). **"Hermes Go" does not exist as an Android client for Hermes Agent.** I could not find it on GitHub, the Play Store, the hermes-agent docs, or community announcements. The name belongs to several *unrelated* projects that pollute search results — none is a mobile agent client:

- [LAI-755/hermes-go](https://github.com/LAI-755/hermes-go) — a **desktop browser-UI server wrapper** around Hermes Agent (Python server on :3000 + React UI, zero-config installer, setup wizard, OpenClaw migration). You could open it in a phone browser, but it is not an Android app.
- [wangkj123/HermesGo](https://github.com/wangkj123/HermesGo) — a portable **Windows** bundle of Hermes Agent with a launcher.
- [hermesgo.ai](https://www.hermesgo.ai/) — a third-party **managed cloud hosting** service for Hermes Agent.
- [Harsh-2909/hermes-go](https://github.com/Harsh-2909/hermes-go) — a Go **agent framework**, unrelated.
- One hermes-agent GitHub issue ([#89995](https://github.com/nousresearch/hermes-agent/issues/89995)) mentions "Hermes Go" in a list of gateway clients, but no repo or store listing for a mobile app by that name is discoverable — likely a misreference or vaporware.

Everything below therefore covers **Hermes Relay in depth**, plus brief design notes from the hermes-go browser UI where relevant.

---

## 1. Hermes Relay (hermes-relay.dev / Codename-11/hermes-relay)

Sources: [hermes-relay.dev](https://hermes-relay.dev/), [docs](https://hermes-relay.dev/docs/), [GitHub README](https://github.com/Codename-11/hermes-relay), [relay-server.md](https://github.com/Codename-11/hermes-relay/blob/main/docs/relay-server.md), [release v1.4.9](https://github.com/Codename-11/hermes-relay/releases/tag/android-v1.4.9).

### Feature list

- **Streaming chat** — rides vanilla Hermes, preferring the dashboard gateway (`/api/ws`, live thinking) when signed in, falling back to API-server SSE. Live markdown, **tool-call cards**, session history, searchable command palette, file attachments, quote-in-reply, conversation share, and **send-while-streaming queuing**.
- **Sessions** — full session history browsing; native Git workspace view with upstream session context.
- **Manage** — the full Hermes dashboard rebuilt native: model picker from provider catalog, API key management (write-only, masked, rate-limited reveal), profile editing including `SOUL.md`, skills browse/install/update.
- **Voice** — hands-free via server-configured providers; Relay-paired adds per-profile voice and an opt-in realtime agent with background task handoff. Voice-in-chat and full hands-free modes.
- **Notifications** — Relay plugin forwards server events; opt-in Notification Companion lets the agent triage/route the phone's own notifications.
- **Device Control (sideload only)** — agent reads/acts on screen (tap, type, swipe, clipboard, macros); guarded by blocklists (banking/2FA), destructive-verb confirmation, idle auto-disable, full activity log.
- **Multi-Connection + profiles** — pair multiple Hermes servers (home/work, dev/prod), one-tap switch; overlay a profile's model + SOUL.md per chat.
- **Petdex** — floating companion widget; optional "make Hermes your Android assistant."
- **Stats for Nerds** — local-only TTFT, token usage, stream health, peak-time charts.
- **i18n** — full catalogs for 6+ languages; app themes and avatars/skins.
- **No approvals UI** for agent tool calls specifically — approvals live in Hermes' smart-approval system server-side; the phone is a chat/steering surface, not an approval inbox.

### UX/design patterns worth stealing

1. **Capability card at end of onboarding** — the connect wizard probes everything and prints a plain table: Chat / Manage / Voice / Direct API / Relay, each "ready / unavailable / paired." Turns connection debugging into a checklist.
2. **"A diagnosis, not just a red dot"** — unreachable server produces an actual explanation.
3. **Two-tier trust via release tracks** — Play build is conservative; sideload APK unlocks privileged features, with an in-app one-tap update banner when behind.
4. **Route roaming** — LAN at home, Tailscale/public URL away; app tests routes and switches automatically (Settings → Gateways → Routes).
5. **One QR configures everything** — dashboard URL, API server, and relay URL in a single payload, without merging their auth models; plain-text values always printed alongside for manual fallback.
6. **Send-while-streaming queuing** — you never wait for a turn to finish to type the next instruction.
7. **Tool-call cards** in the transcript rather than raw dumps.

### Tech stack

- Android app: **Kotlin + Jetpack Compose** (Gradle 8.13), minSdk 26 (Android 8.0+).
- Server side: Python + aiohttp WSS relay server, Hermes plugin (35 `android_*` + 25 `desktop_*` tools), Astro/VitePress docs, GitHub Actions CI per component.

### Connection / auth / background behavior

- **Primary path is the upstream Hermes Dashboard/Gateway (:9119)** — one sign-in covers chat, sessions, Manage, voice, inbound files. The API server (:8642, SSE + key) is an automatic fallback / headless-compat route. Optional Relay WSS (:8767) adds terminal, phone-control, media, relay voice.
- **Pairing**: QR from `hermes pair`, `/hermes-relay-pair` slash command, dashboard "Connect mobile app" tokenless QR, a `hermes-relay://pair?payload=…` invite URL, or URL + 6-char manual code. Codes are one-shot, 10-minute TTL; failed codes are cleared so a stale QR can't loop.
- **Security**: Android Keystore session storage (StrongBox-preferred), TOFU cert pinning, per-channel time-bound grants, user-chosen session TTL, loopback-only pairing registration endpoint, HTTPS-required bearer auth off-loopback.
- **Background/alive**: remote access is delegated to **Tailscale (recommended)** or Secure Link (one pinned TLS origin) rather than push notifications or a foreground-service tunnel. The Relay CLI daemon does keep a background WSS tool-router alive on desktop machines.

### Weaknesses / complaints

- Only 29 open issues / 188 stars — small community, single dominant maintainer (Codename-11, ~2375 commits); bus-factor risk.
- Complexity sprawl: three endpoints (dashboard / API server / relay), two release tracks, sideload-vs-Play capability matrix — the docs spend enormous effort explaining which surface handles what. An omp client should pick **one** connection model.
- Feature set is much broader than a coding-agent client needs (Device Control, SMS/dialing, notification companion) — most of it irrelevant to the "watch a coding agent, approve, steer" job.
- No push/APNs-style notification channel for agent events; if the app is closed you depend on Hermes' own messaging gateways.
- No approval-prompt UX (Hermes resolves approvals server-side) — a gap our omp client can own.

---

## 2. "Hermes Go" (browser-UI wrapper, for reference)

[LAI-755/hermes-go](https://github.com/LAI-755/hermes-go) is the closest real thing, and it is a **desktop server**, not a mobile client. Stealable bits only:

- **Zero-config onboarding wizard** as a first-class product: installer auto-installs Python/Hermes/deps, then a browser setup wizard (provider pick, model switch with one click, English/中文) ends in your first conversation. For our app: the pairing + first-chat flow should be one continuous wizard with no dead ends.
- **Strict separation from the host agent**: an independent server that proxies `/api/*` to the gateway and never modifies Hermes code, so upstream upgrades never break it. Our Flutter client should likewise depend only on documented gateway API surfaces, not internals.
- Dashboard with usage stats, memory management, skills browser, cron management — the "manage" surface pattern, already better executed natively in Hermes Relay.

Design notes on a **phone** (not native app patterns): nothing specific; the React UI targets desktop browsers. Not a source of mobile UX.

---

## Top 10 ideas to steal (ranked for: get notified → open → read → approve → steer → pocket)

1. **Approval-first notifications.** Hermes Relay has no approval inbox; that's our core differentiator. FCM/high-priority notification per pending approval, tap → approval card with the exact command/diff, one-thumb Approve/Deny + reason. (Gap found in Relay; pattern informed by [relay-server.md](https://github.com/Codename-11/hermes-relay/blob/main/docs/relay-server.md).)
2. **Capability card onboarding** ([README](https://github.com/Codename-11/hermes-relay)): after connect, show a probe-result table — Sessions / Streaming / Tool events / Approvals / Model picker — each ✓/✗ with a fix hint. Also gives you a permanent Diagnostics screen.
3. **One-QR pairing with printed fallback**: QR carries gateway URL + token; the same screen always shows copyable host + 6-char code for camera-less setups. One-shot, short-TTL codes, clear on auth failure.
4. **Tool-call activity rows, not dumps** ([README features](https://github.com/Codename-11/hermes-relay)): collapsed card per tool call — icon, one-line summary ("bash: npm test"), expand to full input/output. Streamed deltas update in place.
5. **Send-while-streaming queuing** ([README](https://github.com/Codename-11/hermes-relay)): never disable the composer mid-turn; queue steering messages.
6. **Route roaming with auto-failover** ([README quick start](https://github.com/Codename-11/hermes-relay)): store multiple routes per server (LAN IP, Tailscale IP, public URL); probe and switch silently. "Diagnosis, not red dot" on failure.
7. **Command palette + slash-command autocomplete** ([README features](https://github.com/Codename-11/hermes-relay)): a searchable palette covering `/`-commands, model switch, session switch — essential on a phone where typing slashes is tedious.
8. **Live "thinking" via gateway websocket first, SSE fallback** ([README](https://github.com/Codename-11/hermes-relay), [relay-server.md](https://github.com/Codename-11/hermes-relay/blob/main/docs/relay-server.md)): Relay's transport preference order (dashboard `/api/ws` → SSE) is the right resilience model for our transcript stream.
9. **Keystore + TOFU + time-bound grants** ([README security](https://github.com/Codename-11/hermes-relay)): StrongBox-preferred session storage, pin on first connect, per-channel expiring grants with user-chosen TTL. Cheap to implement, big trust win.
10. **Stats for Nerds** ([README](https://github.com/Codename-11/hermes-relay)): local-only TTFT, tokens/sec, stream-health charts. Tiny feature, huge credibility with the exactly-the-users-we-have audience — and it doubles as connection debugging.

**Explicitly do NOT copy:** Device Control / screen-reading, notification companion, SMS/dialing, Petdex — orthogonal to the coding-agent job and the source of most of Relay's complexity.
