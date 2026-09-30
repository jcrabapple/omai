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
import '../transcript/items.dart' show AssistantItem, UserItem;
import '../transcript/plan.dart';
import '../wire/wire.dart' show OmpEvent, UiRequest;
import 'connection_notifier.dart';
import 'reviewed_store.dart';
import 'sessions_store.dart';
import 'subagents_store.dart';

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

/// Per-turn numbers for the info sheet's "Stats for nerds": the turn's
/// time-to-first-token, tokens per second, and session-wide stream health.
class TurnStats {
  const TurnStats({
    required this.ttftMs,
    required this.tokensPerSec,
    required this.reconnects,
    required this.lastEventSeq,
  });

  /// agent_start to the first assistant delta of the last turn; null when
  /// the turn produced no streamed assistant message.
  final int? ttftMs;

  /// Output tokens per second over the last turn's stream duration, from the
  /// turn's usage when the model reported it; null when it did not.
  final double? tokensPerSec;

  /// Times the websocket dropped since the session opened.
  final int reconnects;

  /// Newest event sequence number we hold.
  final int? lastEventSeq;

  @override
  bool operator ==(Object other) =>
      other is TurnStats &&
      other.ttftMs == ttftMs &&
      other.tokensPerSec == tokensPerSec &&
      other.reconnects == reconnects &&
      other.lastEventSeq == lastEventSeq;

  @override
  int get hashCode =>
      Object.hash(ttftMs, tokensPerSec, reconnects, lastEventSeq);
}

/// Everything the session screen renders, one immutable snapshot.
class SessionState {
  SessionState({
    required this.gwId,
    this.phase = SessionPhase.idle,
    this.error,
    this.info,
    TranscriptState? transcript,
    this.connection = const StreamStatus(
      state: StreamState.offline,
      retryAt: null,
    ),
    this.wsError,
    this.stats,
    this.commands = const [],
    this.slashCommands = const [],
    this.queued = 0,
    this.activity,
    this.retryingSends = const <String>{},
    this.planPhases = const <TodoPhase>[],
    this.streamReconnects = 0,
    this.turnStats,
    this.lastFailedSendId,
    this.ackedRetryIds = const <String>{},
    this.backgroundWork = false,
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

  /// Local send ids currently being retried, so the Retry affordance can
  /// disable itself and re-entry is visible in state.
  final Set<String> retryingSends;

  /// The open session's omp task plan, from the /state poll. Empty when the
  /// session has no plan.
  final List<TodoPhase> planPhases;

  /// Times the websocket dropped since the session opened (live to
  /// connecting/retrying/offline transitions).
  final int streamReconnects;

  /// Timing of the last finished turn, for "Stats for nerds".
  final TurnStats? turnStats;

  /// The local id of the most recent failed send, so the composer can match
  /// its restored content against the eventual Retry ack (triage #12).
  final String? lastFailedSendId;

  /// Local send ids whose Retry has been acked by the gateway. The composer
  /// clears the restored text/images when one of these lands and its content
  /// is unchanged (triage #12).
  final Set<String> ackedRetryIds;

  /// omp still has background jobs (async task subagents, async bash) that
  /// can inject a follow-up and wake the session on their own. From
  /// /state's hasPendingAsyncWork (the poll after agent_end is the signal
  /// that matters: after a user abort agent_end carries no flag), the
  /// agent_end awaitingAsyncWork fast path, cleared by session_settled.
  /// Older omp builds omit the fields; missing reads as false.
  final bool backgroundWork;

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
    Set<String>? retryingSends,
    List<TodoPhase>? planPhases,
    int? streamReconnects,
    TurnStats? turnStats,
    bool clearTurnStats = false,
    String? lastFailedSendId,
    Set<String>? ackedRetryIds,
    bool? backgroundWork,
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
      retryingSends: retryingSends ?? this.retryingSends,
      planPhases: planPhases ?? this.planPhases,
      streamReconnects: streamReconnects ?? this.streamReconnects,
      turnStats: clearTurnStats ? null : (turnStats ?? this.turnStats),
      lastFailedSendId: lastFailedSendId ?? this.lastFailedSendId,
      ackedRetryIds: ackedRetryIds ?? this.ackedRetryIds,
      backgroundWork: backgroundWork ?? this.backgroundWork,
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
    this.now = _systemNow,
  });

  final GatewayClient client;
  final String baseUrl;
  final String token;
  final SocketFactory socketFactory;
  final Scheduler scheduler;

  /// Injectable clock for turn timing (TTFT, tokens per second).
  final DateTime Function() now;

  static DateTime _systemNow() => DateTime.now();
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

final sessionControllerProvider = NotifierProvider.autoDispose
    .family<SessionController, SessionState, String>(SessionController.new);

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

  // Turn timing (Stats for nerds), all driven by env.now.
  int? _turnStartMs;
  int? _ttftMs;

  /// Client-clock ms of the first assistant delta and of agent_end: the
  /// tokens-per-second duration is measured between exactly these two client
  /// readings, never mixed with server timestamps (review #11).
  int? _firstDeltaMs;
  int? _turnEndMs;

  /// The last stream state we saw, for counting reconnects.
  StreamState? _lastStreamState;

  /// Set while the socket is down because WE paused it (voluntary app
  /// backgrounding); such drops must not count as reconnects (review #13).
  bool _pausedByUs = false;

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
        error: e is GatewayClientError
            ? e.message
            : 'Could not open the session',
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
      // Fresh roster for this session: clear, then seed the REST registry
      // snapshot; live frames keep it current while the session is open
      // (web: active.close clears, open seeds via GET /subagents).
      ref.read(subagentsStoreProvider.notifier).clear();
      unawaited(_seedSubagents(env, gwId, gen));
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
        unawaited(ref.read(connectionNotifierProvider.notifier).signOut());
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
    SessionEnv env,
    String gwId,
  ) async {
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
          if (gen == _generation) _onStreamState(status);
        },
        onResync: (_) => unawaited(_resync(env, gwId, gen)),
        onSignedOut: () {
          if (!ref.mounted) return;
          // Close code 4401: the token was rejected. Sign out.
          unawaited(ref.read(connectionNotifierProvider.notifier).signOut());
        },
        onGone: () {
          if (gen != _generation || !ref.mounted) return;
          state = state.copyWith(
            phase: SessionPhase.gone,
            clearError: true,
            clearActivity: true,
          );
          ref.read(sessionsStoreProvider.notifier).remove(gwId);
        },
      ),
    );
    _stream = stream;
    stream.start();
  }

  /// Connection status: paint it, and count a reconnect each time a live
  /// socket drops unexpectedly. A voluntary pause (the app backgrounded
  /// without a running turn) is not a reconnect (review #13).
  void _onStreamState(StreamStatus status) {
    final was = _lastStreamState;
    _lastStreamState = status.state;
    final voluntary = _pausedByUs && status.state != StreamState.live;
    if (status.state == StreamState.live) _pausedByUs = false;
    if (was == StreamState.live && status.state != StreamState.live) {
      state = state.copyWith(
        connection: status,
        streamReconnects: voluntary
            ? state.streamReconnects
            : state.streamReconnects + 1,
      );
      return;
    }
    state = state.copyWith(connection: status);
  }

  void _onControl(Map<String, Object?> frame) {
    final type = frame['type'];
    if (type == 'auth_ok') {
      final session = frame['session'];
      if (session is Map) {
        final info = SessionInfo.fromJson(Map<String, dynamic>.from(session));
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
    // TTFT is the wall time from agent_start to the FIRST assistant delta;
    // it must be read at enqueue time, before coalescing can delay the
    // delta's delivery past the next clock reading.
    if (_turnStartMs != null &&
        _ttftMs == null &&
        event.type == 'message_update' &&
        _isAssistantDelta(event)) {
      _ttftMs = _now() - _turnStartMs!;
      _firstDeltaMs = _now();
    }
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

  /// Injectable clock for turn timing, in epoch ms; the wall clock until the
  /// env has loaded (which is before any event can arrive anyway).
  int _now() {
    final env = ref.read(sessionEnvProvider).value;
    final clock = env?.now;
    return (clock == null ? DateTime.now() : clock()).millisecondsSinceEpoch;
  }

  void _afterEvent(OmpEvent event) {
    switch (event.type) {
      case 'agent_start':
        _turnStartMs = _now();
        _ttftMs = null;
        _firstDeltaMs = null;
        _turnEndMs = null;
        state = state.copyWith(
          activity: ActivitySummary(
            toolName: state.activity?.toolName ?? '',
            turnStartedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      case 'agent_end':
        // The turn is over: the activity line goes, stats refresh. The
        // reducer has already cleared `running`.
        _turnEndMs = _now();
        state = state.copyWith(
          clearActivity: true,
          turnStats: _turnStatsForLastTurn(),
          // Fast path: omp says the only possible resume is a background
          // job result. After a user abort agent_end arrives WITHOUT this
          // flag even with jobs running; the /state poll then decides.
          backgroundWork:
              state.backgroundWork || event.raw['awaitingAsyncWork'] == true,
        );
        _scheduleStats();
      case 'session_settled':
        // omp went quiet with no background work left.
        state = state.copyWith(backgroundWork: false);
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
      case 'subagent_progress':
      case 'subagent_lifecycle':
        ref.read(subagentsStoreProvider.notifier).feed(event);
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

  /// True while a message_update carries an assistant message payload (the
  /// first one after agent_start defines the turn's TTFT).
  bool _isAssistantDelta(OmpEvent event) {
    final m = event.raw['message'];
    return m is Map && m['role'] == 'assistant';
  }

  /// Timing of the turn that just ended: TTFT as timed from agent_start to
  /// the first assistant delta, tokens per second from the last assistant
  /// message's output tokens over the client-clock stream duration (first
  /// delta to turn end). Client clock only: server timestamps are a
  /// different clock and produced wildly skewed figures (review #11).
  TurnStats _turnStatsForLastTurn() {
    AssistantItem? last;
    for (final it in state.transcript.items) {
      if (it is AssistantItem) last = it;
    }
    int? ttft = _ttftMs ?? last?.ttft;
    double? tokensPerSec;
    final output = last?.usage?['output'];
    final firstDelta = _firstDeltaMs;
    final end = _turnEndMs;
    if (output is num && output > 0 && firstDelta != null && end != null) {
      final durationMs = end - firstDelta;
      // Shorter than 500ms of streaming is not a measurable rate.
      if (durationMs >= 500) {
        tokensPerSec = output.toDouble() * 1000 / durationMs;
      }
    }
    if (ttft != null && ttft < 0) ttft = 0;
    return TurnStats(
      ttftMs: ttft,
      tokensPerSec: tokensPerSec,
      reconnects: state.streamReconnects,
      lastEventSeq: streamLastSeq ?? state.info?.lastEventSeq,
    );
  }

  // ------------------------------------------------------- info refreshers

  Future<void> _refreshInfo(SessionEnv env, String gwId, int gen) async {
    try {
      final info = await env.client.sessionInfo(gwId);
      if (gen != _generation || !ref.mounted) return;
      _setInfo(info);
    } catch (_) {
      // the stream reports real trouble
    }
  }

  Future<void> _refreshStats(SessionEnv env, String gwId, int gen) async {
    try {
      final s = await env.client.stats(gwId);
      if (gen != _generation || !ref.mounted) return;
      state = state.copyWith(
        stats: s['data'] is Map
            ? Map<String, Object?>.from(s['data'] as Map)
            : s,
      );
    } catch (_) {
      // stats are optional
    }
  }

  Future<void> _refreshQueued(SessionEnv env, String gwId, int gen) async {
    try {
      final st = await env.client.state(gwId);
      if (gen != _generation || !ref.mounted) return;
      final queued = st['queuedMessageCount'];
      state = state.copyWith(queued: queued is num ? queued.toInt() : 0);
      // The plan rides the same /state payload (web: plan store derives from
      // active.state.todoPhases, refreshed by the state poll).
      final phases = normalizePhases(st['todoPhases']);
      state = state.copyWith(planPhases: phases);
      // Background work rides the same /state payload. Missing field
      // (older omp builds) reads as false. This poll also runs on the
      // initial open (_open calls it), so a session opened onto idle
      // background work is flagged from the start.
      state = state.copyWith(backgroundWork: st['hasPendingAsyncWork'] == true);
      ref
          .read(sessionsStoreProvider.notifier)
          .setTodoActive(gwId, hasActiveTodo(phases));
    } catch (_) {
      // the count is a courtesy
    }
  }

  Future<void> _loadCommands(SessionEnv env, String gwId, int gen) async {
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

  /// Registry snapshot for the subagents roster; optional, like stats.
  Future<void> _seedSubagents(SessionEnv env, String gwId, int gen) async {
    try {
      final r = await env.client.subagents(gwId);
      if (gen != _generation || !ref.mounted) return;
      ref.read(subagentsStoreProvider.notifier).seed(r);
    } catch (_) {
      // the roster fills from live frames anyway
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
    // Marked before the stream reports the drop so _onStreamState sees it.
    _pausedByUs = true;
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

  /// Local send ids with a retry in flight (re-entry guard).
  final Set<String> _retrying = {};

  /// The prompt images of each local send, kept until the gateway acks so a
  /// failed images-only send can be retried (retrySend bails only when a
  /// send had neither text nor images). Bounded: only the most recent
  /// [_sendImagesLimit] failed sends keep their images (review triage #1).
  final Map<String, List<Map<String, String>>> _sendImages = {};

  static const int _sendImagesLimit = 3;

  void _retainSendImages(String localId, List<Map<String, String>> images) {
    while (_sendImages.length >= _sendImagesLimit) {
      _sendImages.remove(_sendImages.keys.first);
    }
    _sendImages[localId] = images;
  }

  /// Send a prompt. Optimistic: the LocalSendInput paints the bubble before
  /// the request goes out. Durable at the composer level: on failure the
  /// bubble turns into a failed one (Retry affordance) and the composer puts
  /// the text back. The review pin clears only after the gateway accepts.
  Future<bool> send(
    String text, {
    String mode = 'prompt',
    List<Map<String, String>>? images,
    String? retryLocalId,
  }) async {
    final localId = retryLocalId ?? 'local-${++_localCounter}';
    if (ref.mounted) state = state.copyWith(clearWsError: true);
    if (retryLocalId != null) {
      // Retry: the SAME failed bubble flips back to pending; no second one.
      _dispatch(LocalSendRetryInput(localId));
    } else {
      // Keep the images for a possible retry; cleared once the gateway acks.
      if (images != null && images.isNotEmpty) {
        _retainSendImages(localId, images);
      }
      _dispatch(
        LocalSendInput(
          localId: localId,
          text: text,
          mode: mode,
          images: images,
        ),
      );
    }
    try {
      final env = await ref.read(sessionEnvProvider.future);
      final info = await env.client.prompt(
        gwId,
        text,
        mode: mode,
        images: images,
      );
      // Drop the retained images as soon as the gateway acks, BEFORE the
      // mounted check (triage #1): the map must not keep them when this
      // controller is going away mid-send.
      _sendImages.remove(localId);
      if (!ref.mounted) return true; // sent; nothing left to paint
      _setInfo(info);
      // A retried send just acked: record it so the composer can clear the
      // content the failed send restored (triage #12).
      if (retryLocalId != null) {
        state = state.copyWith(
          ackedRetryIds: {...state.ackedRetryIds, localId},
        );
      }
      if (mode != 'prompt') {
        unawaited(_refreshQueued(env, gwId, _generation));
      }
      // The user is working in here again: the review pin only makes sense on
      // a settled session. Cleared after the ack, so a failed send keeps it.
      await ref.read(reviewedStoreProvider.notifier).unflag(gwId);
      return true;
    } catch (e) {
      if (!ref.mounted) return false;
      _dispatch(
        LocalSendFailedInput(
          localId: localId,
          error: e is GatewayClientError ? e.message : 'Send failed',
        ),
      );
      // Remember which send failed so the composer can match its restored
      // content against the eventual Retry ack (triage #12).
      state = state.copyWith(lastFailedSendId: localId);
      return false;
    }
  }

  /// Retry a FAILED local send, identified by its local id. Controller-level
  /// guard (review finding: double-tap Retry must not double-send): re-entry
  /// while the retry is in flight is ignored, and the failed bubble is
  /// REUSED (same bubble flips back to pending, no second one).
  Future<bool> retrySend(String localId) async {
    if (_retrying.contains(localId)) return false;
    UserItem? failed;
    for (final it in state.transcript.items) {
      if (it is UserItem && it.localId == localId && it.failed == true) {
        failed = it;
      }
    }
    final text = failed?.text.trim() ?? '';
    final images = _sendImages[localId];
    // An images-only failed send (empty text, images attached) retries too.
    if (text.isEmpty && (images == null || images.isEmpty)) return false;
    _retrying.add(localId);
    if (ref.mounted) {
      state = state.copyWith(retryingSends: {...state.retryingSends, localId});
    }
    try {
      return await send(
        text,
        images: (images == null || images.isEmpty) ? null : images,
        retryLocalId: localId,
      );
    } finally {
      _retrying.remove(localId);
      if (ref.mounted) {
        final next = {...state.retryingSends}..remove(localId);
        state = state.copyWith(retryingSends: next);
      }
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
    _dispatch(
      PendingUiInput(state.pendingUi.where((u) => u.id != requestId).toList()),
    );
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
    // Failed-send images belong to this controller only (triage #1).
    _sendImages.clear();
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

List<UiRequest> _uiRequests(List<Map<String, Object?>> raw) => [
  for (final r in raw)
    if (UiRequest.from(r) != null) UiRequest.from(r)!,
];

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
