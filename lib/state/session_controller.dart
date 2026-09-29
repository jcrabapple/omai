// The open session: info, transcript, stream and approvals state, ported
// from web/src/lib/state/active.svelte.ts (send/approve actions are D2).
//
// Load order matters. `info` is fetched before `messages` so
// `info.lastEventSeq` is never newer than the history; any event in between
// is replayed on top and the reducer treats replays as no-ops. After a
// resync the stream holds events until we `rebase` it.
//
// HARD RULE (from the D1 research): the session can never stick in
// 'running'. Three clear paths, all wired: the agent_end event (the reducer
// clears it), a resync (the fresh snapshot's isStreaming decides), and fresh
// info reporting isStreaming:false (setInfo clears it).

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/client.dart';
import '../api/errors.dart';
import '../api/models.dart' show SessionInfo, rawMapList;
import '../composer/slash.dart' show SlashCommand;
import '../stream/scheduler.dart';
import '../stream/session_stream.dart';
import '../transcript/reducer.dart';
import '../wire/wire.dart' show OmpEvent, UiRequest;
import 'connection_notifier.dart';
import 'reviewed_store.dart';
import 'sessions_store.dart';

enum SessionPhase { idle, loading, ready, gone, error }

/// Live activity line for the header: the current tool and when the turn
/// started. Null between turns.
class ActivitySummary {
  const ActivitySummary({required this.toolName, required this.turnStartedAt});

  final String toolName;

  /// Epoch ms of the agent_start that opened the current turn.
  final int turnStartedAt;

  @override
  bool operator ==(Object other) =>
      other is ActivitySummary &&
      other.toolName == toolName &&
      other.turnStartedAt == turnStartedAt;

  @override
  int get hashCode => Object.hash(toolName, turnStartedAt);
}

/// Everything the session screen renders, one immutable snapshot.
class SessionState {
  SessionState({
    required this.gwId,
    this.phase = SessionPhase.idle,
    this.error,
    this.info,
    TranscriptState? transcript,
    this.connection =
        const StreamStatus(state: StreamState.offline, retryAt: null),
    this.wsError,
    this.stats,
    this.commands = const [],
    this.slashCommands = const [],
    this.queued = 0,
    this.activity,
  }) : transcript = transcript ?? emptyTranscript();

  final String gwId;
  final SessionPhase phase;
  final String? error;
  final SessionInfo? info;
  final TranscriptState transcript;

  /// Socket status (connecting / live / retrying / offline / gone).
  final StreamStatus connection;

  /// Set when omp reports a websocket-level error. Cleared on the next send.
  final String? wsError;

  /// Last /stats payload (cost, tokens); optional, may stay null.
  final Map<String, Object?>? stats;

  /// Slash commands from /commands.
  final List<String> commands;

  /// The same commands with their full shape (source, description, aliases,
  /// input hint), for the slash menu. Kept next to [commands] so existing
  /// consumers of the name list keep working.
  final List<SlashCommand> slashCommands;

  /// Messages omp is holding for after the current turn (from /state).
  final int queued;

  final ActivitySummary? activity;

  /// Blocking dialogs omp is waiting on (for the approval takeover UI).
  List<UiRequest> get pendingUi => transcript.pendingUi;

  /// Between agent_start and agent_end. Never sticks: see the module header.
  bool get running => transcript.running;

  SessionState copyWith({
    SessionPhase? phase,
    String? error,
    bool clearError = false,
    SessionInfo? info,
    TranscriptState? transcript,
    StreamStatus? connection,
    String? wsError,
    bool clearWsError = false,
    Map<String, Object?>? stats,
    List<String>? commands,
    List<SlashCommand>? slashCommands,
    int? queued,
    ActivitySummary? activity,
    bool clearActivity = false,
  }) {
    return SessionState(
      gwId: gwId,
      phase: phase ?? this.phase,
      error: clearError ? null : (error ?? this.error),
      info: info ?? this.info,
      transcript: transcript ?? this.transcript,
      connection: connection ?? this.connection,
      wsError: clearWsError ? null : (wsError ?? this.wsError),
      stats: stats ?? this.stats,
      commands: commands ?? this.commands,
      slashCommands: slashCommands ?? this.slashCommands,
      queued: queued ?? this.queued,
      activity: clearActivity ? null : (activity ?? this.activity),
    );
  }
}

/// Re-export for consumers so they don't import the wire module for the type.
typedef UiRequestView = UiRequest;

/// Everything the controller needs to reach the gateway and the socket,
/// injected so tests run against fakes.
class SessionEnv {
  const SessionEnv({
    required this.client,
    required this.baseUrl,
    required this.token,
    required this.socketFactory,
    required this.scheduler,
  });

  final GatewayClient client;
  final String baseUrl;
  final String token;
  final SocketFactory socketFactory;
  final Scheduler scheduler;
}

/// Default environment for the active connection. Throws when not signed in.
final sessionEnvProvider = FutureProvider<SessionEnv>((ref) async {
  final connection = ref.watch(connectionNotifierProvider);
  final active = connection.active;
  if (active == null) {
    throw const Offline('Not signed in.');
  }
  final token = await ref.watch(tokenStoreProvider).read(active.id);
  if (token == null || token.isEmpty) {
    throw const Offline('Not signed in.');
  }
  final client = ref.watch(gatewayClientFactoryProvider)(active.url, token);
  return SessionEnv(
    client: client,
    baseUrl: active.url,
    token: token,
    socketFactory: ioSocketFactory,
    scheduler: const SystemScheduler(),
  );
});

final sessionControllerProvider = NotifierProvider.autoDispose.family<
    SessionController, SessionState, String>(SessionController.new);

/// One open session, keyed by gateway session id. The id arrives through the
/// constructor (Riverpod 3 family without codegen); `build` kicks off the
/// open sequence.
class SessionController extends Notifier<SessionState> {
  SessionController(this.gwId);

  /// The gateway session id this controller owns.
  final String gwId;

  int _generation = 0;
  SessionStream? _stream;
  Timer? _statsTimer;

  // Pending, coalesced events (see [enqueue]).
  final List<({OmpEvent event, int at})> _pendingEvents = [];
  bool _flushScheduled = false;

  @override
  SessionState build() {
    ref.onDispose(_teardown);
    final gen = ++_generation;
    unawaited(_open(gwId, gen));
    return SessionState(gwId: gwId, phase: SessionPhase.loading);
  }

  // ----------------------------------------------------------------- open

  Future<void> _open(String gwId, int gen) async {
    SessionEnv env;
    try {
      env = await ref.read(sessionEnvProvider.future);
    } catch (e) {
      if (gen != _generation || !ref.mounted) return;
      state = state.copyWith(
        phase: SessionPhase.error,
        error: e is GatewayClientError ? e.message : 'Could not open the session',
      );
      return;
    }
    try {
      final snap = await _snapshot(env, gwId);
      if (gen != _generation || !ref.mounted) return;
      _applySnapshot(snap.$1, snap.$2);
      state = state.copyWith(phase: SessionPhase.ready, clearError: true);
      _startStream(env, gwId, snap.$1.lastEventSeq, gen);
      unawaited(_loadCommands(env, gwId, gen));
      unawaited(_refreshStats(env, gwId, gen));
      unawaited(_refreshQueued(env, gwId, gen));
    } catch (e) {
      if (gen != _generation || !ref.mounted) return;
      if (e is GatewayError && e.status == 404) {
        state = state.copyWith(phase: SessionPhase.gone, clearError: true);
        // The session is gone: take it out of the rail immediately.
        ref.read(sessionsStoreProvider.notifier).remove(gwId);
        return;
      }
      if (e is AuthError) {
        // A confirmed 401 signs the user out.
        unawaited(
            ref.read(connectionNotifierProvider.notifier).signOut());
      }
      state = state.copyWith(
        phase: SessionPhase.error,
        error: e is GatewayClientError
            ? e.message
            : 'Could not open the session',
      );
    }
  }

  /// (info, messages) fetched in that order; see the module header.
  Future<(SessionInfo, List<Map<String, Object?>>)> _snapshot(
      SessionEnv env, String gwId) async {
    final info = await env.client.sessionInfo(gwId);
    final raw = await env.client.messages(gwId);
    return (info, rawMapList(raw['messages']));
  }

  void _applySnapshot(SessionInfo info, List<Map<String, Object?>> messages) {
    _setInfo(info);
    _dispatch(HistoryInput(messages, streaming: info.isStreaming));
    _dispatch(PendingUiInput(_uiRequests(info.pendingUi)));
  }

  // ---------------------------------------------------------------- stream

  void _startStream(SessionEnv env, String gwId, int after, int gen) {
    final stream = SessionStream(
      gwId: gwId,
      baseUrl: env.baseUrl,
      token: env.token,
      after: after,
      socketFactory: env.socketFactory,
      scheduler: env.scheduler,
      handlers: StreamHandlers(
        onEvent: (event, seq) {
          if (gen == _generation) _enqueue(event);
        },
        onControl: (frame) {
          if (gen == _generation) _onControl(frame);
        },
        onState: (status) {
          if (gen == _generation) {
            state = state.copyWith(connection: status);
          }
        },
        onResync: (_) => unawaited(_resync(env, gwId, gen)),
        onSignedOut: () {
          if (!ref.mounted) return;
          // Close code 4401: the token was rejected. Sign out.
          unawaited(
              ref.read(connectionNotifierProvider.notifier).signOut());
        },
        onGone: () {
          if (gen != _generation || !ref.mounted) return;
          state = state.copyWith(
              phase: SessionPhase.gone, clearError: true, clearActivity: true);
          ref.read(sessionsStoreProvider.notifier).remove(gwId);
        },
      ),
    );
    _stream = stream;
    stream.start();
  }

  void _onControl(Map<String, Object?> frame) {
    final type = frame['type'];
    if (type == 'auth_ok') {
      final session = frame['session'];
      if (session is Map) {
        final info =
            SessionInfo.fromJson(Map<String, dynamic>.from(session));
        _setInfo(info);
        _dispatch(PendingUiInput(_uiRequests(info.pendingUi)));
      }
    } else if (type == 'ws_error') {
      final err = frame['error'];
      if (err is String) state = state.copyWith(wsError: err);
    }
  }

  /// Local state may be stale (backlog gap, long background): refetch the
  /// snapshot, then rebase the stream. On failure, release held events so the
  /// stream keeps flowing; the next gap tries again.
  Future<void> _resync(SessionEnv env, String gwId, int gen) async {
    final stream = _stream;
    if (stream == null) return;
    try {
      final snap = await _snapshot(env, gwId);
      if (gen != _generation || !ref.mounted) return;
      _applySnapshot(snap.$1, snap.$2);
      stream.rebase(snap.$1.lastEventSeq);
    } catch (_) {
      if (gen == _generation) stream.rebase(stream.lastSeq);
    }
  }

  // ---------------------------------------------------------------- events

  /// Streaming deltas each carry the whole message, so only the newest one
  /// per message matters: consecutive updates for the same key collapse to
  /// the last. The web applies them once per animation frame; here they are
  /// released on the next microtask, which keeps ordering and tests
  /// deterministic without a frame clock.
  void _enqueue(OmpEvent event) {
    final at = DateTime.now().millisecondsSinceEpoch;
    final key = _coalesceKey(event);
    if (key != null) {
      if (_pendingEvents.isNotEmpty &&
          _coalesceKey(_pendingEvents.last.event) == key) {
        _pendingEvents[_pendingEvents.length - 1] = (event: event, at: at);
      } else {
        _pendingEvents.add((event: event, at: at));
      }
      if (!_flushScheduled) {
        _flushScheduled = true;
        unawaited(Future<void>.microtask(_flush));
      }
      return;
    }
    _pendingEvents.add((event: event, at: at));
    _flush();
  }

  void _flush() {
    _flushScheduled = false;
    if (_pendingEvents.isEmpty) return;
    if (!ref.mounted) {
      _pendingEvents.clear();
      return;
    }
    final batch = _pendingEvents.toList();
    _pendingEvents.clear();
    var transcript = state.transcript;
    for (final e in batch) {
      transcript = reduce(transcript, EventInput(e.event, at: e.at));
    }
    state = state.copyWith(transcript: transcript);
    for (final e in batch) {
      _afterEvent(e.event);
    }
  }

  void _afterEvent(OmpEvent event) {
    switch (event.type) {
      case 'agent_start':
        state = state.copyWith(
          activity: ActivitySummary(
            toolName: state.activity?.toolName ?? '',
            turnStartedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      case 'agent_end':
        // The turn is over: the activity line goes, stats refresh. The
        // reducer has already cleared `running`.
        state = state.copyWith(clearActivity: true);
        _scheduleStats();
      case 'tool_execution_start':
        final name = event.toolName ?? '';
        state = state.copyWith(
          activity: ActivitySummary(
            toolName: name,
            turnStartedAt:
                state.activity?.turnStartedAt ??
                    DateTime.now().millisecondsSinceEpoch,
          ),
        );
      case 'available_commands_update':
        final cmds = event.raw['commands'];
        if (cmds is List) _applyCommands(cmds);
      default:
        break;
    }
  }

  bool _statsPending = false;

  void _scheduleStats() {
    _statsTimer?.cancel();
    _statsPending = true;
    _statsTimer = Timer(const Duration(milliseconds: 600), () {
      _statsTimer = null;
      _statsPending = false;
      unawaited(_refreshAfterTurn());
    });
  }

  Future<void> _refreshAfterTurn() async {
    if (!ref.mounted) return;
    final gen = _generation; // captured before the await
    try {
      final env = await ref.read(sessionEnvProvider.future);
      if (!ref.mounted || gen != _generation) return;
      await Future.wait<void>([
        _refreshStats(env, gwId, gen),
        _refreshInfo(env, gwId, gen),
        _refreshQueued(env, gwId, gen),
      ]);
    } catch (_) {
      // stats are optional
    }
  }

  // ------------------------------------------------------- info refreshers

  Future<void> _refreshInfo(
      SessionEnv env, String gwId, int gen) async {
    try {
      final info = await env.client.sessionInfo(gwId);
      if (gen != _generation || !ref.mounted) return;
      _setInfo(info);
    } catch (_) {
      // the stream reports real trouble
    }
  }

  Future<void> _refreshStats(
      SessionEnv env, String gwId, int gen) async {
    try {
      final s = await env.client.stats(gwId);
      if (gen != _generation || !ref.mounted) return;
      state = state.copyWith(stats: s['data'] is Map
          ? Map<String, Object?>.from(s['data'] as Map)
          : s);
    } catch (_) {
      // stats are optional
    }
  }

  Future<void> _refreshQueued(
      SessionEnv env, String gwId, int gen) async {
    try {
      final st = await env.client.state(gwId);
      if (gen != _generation || !ref.mounted) return;
      final queued = st['queuedMessageCount'];
      state = state.copyWith(queued: queued is num ? queued.toInt() : 0);
      ref
          .read(sessionsStoreProvider.notifier)
          .setTodoActive(gwId, _hasActiveTodo(st));
    } catch (_) {
      // the count is a courtesy
    }
  }

  Future<void> _loadCommands(
      SessionEnv env, String gwId, int gen) async {
    try {
      final r = await env.client.commands(gwId);
      if (gen != _generation || !ref.mounted) return;
      final data = r['data'];
      final cmds = data is Map ? data['commands'] : null;
      if (cmds is List) _applyCommands(cmds);
    } catch (_) {
      // the palette works without slash commands
    }
  }

  /// Parse a raw commands list into both the name list and the full
  /// SlashCommand objects the slash menu filters on.
  void _applyCommands(List<dynamic> cmds) {
    final slash = SlashCommand.listFrom(cmds);
    state = state.copyWith(
      commands: [
        for (final c in cmds)
          if (c is Map && c['name'] is String) c['name'] as String,
        for (final c in cmds)
          if (c is String) c,
      ],
      slashCommands: slash,
    );
  }

  /// The reducer owns transcript state; fresh info reporting
  /// isStreaming:false always clears `running` so it can never stick.
  void _setInfo(SessionInfo info) {
    var transcript = state.transcript;
    final shouldClear = !info.isStreaming && state.activity != null;
    if (!info.isStreaming && transcript.running) {
      transcript = _withRunning(transcript, false);
    }
    state = state.copyWith(
      info: info,
      transcript: transcript,
      clearActivity: shouldClear,
    );
    ref.read(sessionsStoreProvider.notifier).patch(info);
  }

  // ------------------------------------------------------------ public API

  /// App went to the background: drop the socket and wait.
  void pause() {
    _statsTimer?.cancel();
    _statsTimer = null;
    _stream?.pause();
  }

  /// App came back: reconnect, resyncing when it was away too long.
  void resume() {
    _stream?.resume();
    // A stats refresh may have been pending when we paused; run it now.
    if (_statsTimer == null && _statsPending) {
      _statsPending = false;
      _scheduleStats();
    }
  }

  /// Refetch info now (e.g. pull-to-refresh on the session screen).
  Future<void> refreshInfo() async {
    try {
      final env = await ref.read(sessionEnvProvider.future);
      await _refreshInfo(env, gwId, _generation);
    } catch (_) {
      // the stream reports real trouble
    }
  }

  /// Reconnect immediately (e.g. after the user taps a retry affordance).
  void reconnect() => _stream?.reconnectNow();

  /// The active stream's cursor, for tests and diagnostics.
  int? get streamLastSeq => _stream?.lastSeq;

  // ------------------------------------------------------------- actions
  // Ported from web/src/lib/state/active.svelte.ts (send / answerUi /
  // dropUi / abort / setModel / setThinking / rename / compact).

  int _localCounter = 0;

  /// Send a prompt. Optimistic: the LocalSendInput paints the bubble before
  /// the request goes out. Durable at the composer level: on failure the
  /// bubble turns into a failed one (Retry affordance) and the composer puts
  /// the text back. The review pin clears only after the gateway accepts.
  Future<bool> send(String text,
      {String mode = 'prompt', List<Map<String, String>>? images}) async {
    final localId = 'local-${++_localCounter}';
    if (ref.mounted) state = state.copyWith(clearWsError: true);
    _dispatch(LocalSendInput(
        localId: localId, text: text, mode: mode, images: images));
    try {
      final env = await ref.read(sessionEnvProvider.future);
      final info = await env.client.prompt(gwId, text, mode: mode, images: images);
      if (!ref.mounted) return true; // sent; nothing left to paint
      _setInfo(info);
      if (mode != 'prompt') {
        unawaited(_refreshQueued(env, gwId, _generation));
      }
      // The user is working in here again: the review pin only makes sense on
      // a settled session. Cleared after the ack, so a failed send keeps it.
      await ref.read(reviewedStoreProvider.notifier).unflag(gwId);
      return true;
    } catch (e) {
      if (!ref.mounted) return false;
      _dispatch(LocalSendFailedInput(
          localId: localId,
          error:
              e is GatewayClientError ? e.message : 'Send failed'));
      return false;
    }
  }

  /// Answer one dialog. Local state is not touched on success: the
  /// ui_resolved event removes it through the reducer. A 409 (someone else
  /// answered first, or it timed out) drops it locally.
  Future<void> answerUi(String requestId, Map<String, Object?> answer) async {
    final env = await ref.read(sessionEnvProvider.future);
    await env.client.answerUi(gwId, requestId, answer);
  }

  /// Remove a dialog locally, e.g. after answering it or after someone else
  /// beat us to it (409).
  void dropUi(String requestId) {
    _dispatch(PendingUiInput(
        state.pendingUi.where((u) => u.id != requestId).toList()));
  }

  /// Stop the current turn.
  Future<void> abort() async {
    final env = await ref.read(sessionEnvProvider.future);
    await env.client.abort(gwId);
  }

  Future<void> setModel(String provider, String modelId) async {
    final env = await ref.read(sessionEnvProvider.future);
    await env.client.setModel(gwId, provider, modelId);
    if (!ref.mounted) return;
    await refreshInfo();
  }

  Future<void> setThinking(String level) async {
    final env = await ref.read(sessionEnvProvider.future);
    await env.client.setThinking(gwId, level);
    if (!ref.mounted) return;
    await refreshInfo();
  }

  Future<void> rename(String name) async {
    final env = await ref.read(sessionEnvProvider.future);
    await env.client.setName(gwId, name);
    if (!ref.mounted) return;
    await refreshInfo();
  }

  /// Ask omp to compact the session context. `instructions` steers what to keep.
  Future<void> compact(String? instructions) async {
    final env = await ref.read(sessionEnvProvider.future);
    await env.client.compact(gwId, instructions: instructions);
    if (!ref.mounted) return;
    await refreshInfo();
  }

  // TODO(D2 later): forgetCache(gwId) once transcript caching exists.

  // -------------------------------------------------------------- internals

  void _dispatch(TranscriptInput input) {
    state = state.copyWith(transcript: reduce(state.transcript, input));
  }

  void _teardown() {
    _generation++;
    _statsTimer?.cancel();
    _statsTimer = null;
    _statsPending = false;
    _flushScheduled = false;
    _pendingEvents.clear();
    _stream?.stop();
    _stream = null;
  }
}

/// TranscriptState with running forced to [value]; the only mutation the
/// controller makes outside the reducer (the never-stick rule).
TranscriptState _withRunning(TranscriptState t, bool value) => TranscriptState(
      items: t.items,
      pendingUi: t.pendingUi,
      running: value,
      counter: t.counter,
    );

List<UiRequest> _uiRequests(List<Map<String, Object?>> raw) =>
    [for (final r in raw) if (UiRequest.from(r) != null) UiRequest.from(r)!];

String? _coalesceKey(OmpEvent event) {
  switch (event.type) {
    case 'message_update':
      return 'm:${event.messageId ?? ''}';
    case 'tool_execution_update':
      return 't:${event.toolCallId ?? ''}';
    default:
      return null;
  }
}

/// True when some todo task is in_progress: the session is working even
/// between agent turns. Ported from web/src/lib/state/plan.ts hasActiveTodo,
/// reading a raw /state payload.
bool _hasActiveTodo(Map<String, dynamic> stateJson) {
  final phases = stateJson['todoPhases'];
  if (phases is! List) return false;
  for (final phase in phases) {
    if (phase is! Map) continue;
    final tasks = phase['tasks'];
    if (tasks is! List) continue;
    for (final task in tasks) {
      if (task is Map && task['status'] == 'in_progress') return true;
    }
  }
  return false;
}
