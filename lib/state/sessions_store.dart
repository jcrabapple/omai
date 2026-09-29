// Sessions list store for the active connection, ported from
// web/src/lib/state/sessions.svelte.ts. Stale-first: a refresh keeps the last
// list on screen and reports itself through `refreshing`; an error lands in
// `error` and never blanks the list.
//
// Polling runs on a timer while the app is foregrounded; the UI layer calls
// startPolling/stopPolling from its AppLifecycle listener (the web store
// listens to document visibilitychange itself).

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/errors.dart';
import '../api/models.dart';
import 'connection_notifier.dart';
import 'grouping.dart';
import 'reviewed_store.dart';

const pollMs = 5000;

/// How long a todoActive entry stays believable without a /state refresh
/// (see [SessionsStore.expireTodoStale]).
const todoFreshMs = 15000;

final sessionsClockProvider =
    Provider<DateTime Function()>((ref) => DateTime.now);

final sessionsPollIntervalProvider =
    Provider<Duration>((ref) => const Duration(milliseconds: pollMs));

class SessionsState {
  const SessionsState({
    this.live = const [],
    this.saved = const [],
    this.loaded = false,
    this.refreshing = false,
    this.error,
    this.todoActive = const {},
  });

  final List<SessionInfo> live;
  final List<SavedSession> saved;

  /// False until the first list arrives, so the rail can show skeletons.
  final bool loaded;

  /// True while a fetch is in flight, including over an already-loaded list.
  final bool refreshing;

  /// Last failure. Null once a refresh succeeds. Never clears the list.
  final String? error;

  /// Sessions whose last known /state has an in_progress todo task; the rail
  /// reads them as working.
  final Set<String> todoActive;

  SessionsState copyWith({
    List<SessionInfo>? live,
    List<SavedSession>? saved,
    bool? loaded,
    bool? refreshing,
    String? error,
    bool clearError = false,
    Set<String>? todoActive,
  }) {
    return SessionsState(
      live: live ?? this.live,
      saved: saved ?? this.saved,
      loaded: loaded ?? this.loaded,
      refreshing: refreshing ?? this.refreshing,
      error: clearError ? null : (error ?? this.error),
      todoActive: todoActive ?? this.todoActive,
    );
  }
}

class SessionsStore extends Notifier<SessionsState> {
  /// Only the newest refresh may apply its result.
  int _generation = 0;
  Timer? _timer;

  /// Whether the UI asked for polling; a connection change restarts the
  /// timer instead of losing it.
  bool _polling = false;

  /// Connection id the current list belongs to; null until the first build,
  /// '' when signed out.
  String? _connId;

  /// Survives provider rebuilds: the session currently open on screen, when
  /// any. Its todoActive entry is kept across polls because its /state keeps
  /// being refreshed.
  String? openGwId;

  /// Last time each session's /state confirmed its todo state; entries go
  /// stale without refreshes.
  final Map<String, DateTime> _lastTodoRefresh = {};

  @override
  SessionsState build() {
    // Rebuild (and so drop the stale connection's list) when the active
    // connection changes; then fetch the new connection's list.
    final id =
        ref.watch(connectionNotifierProvider.select((s) => s.active?.id ?? ''));
    ref.onDispose(() {
      _timer?.cancel();
      _timer = null;
    });
    if (id != _connId) {
      _connId = id;
      _generation++;
      _timer?.cancel();
      _timer = null;
      _lastTodoRefresh.clear();
      // Polling survives connection switches: rearm the timer for the new
      // connection (the immediate refresh happens below).
      if (_polling) {
        final interval = ref.read(sessionsPollIntervalProvider);
        _timer = Timer.periodic(interval, (_) => refresh());
      }
      Future<void>.microtask(() => refresh());
      return const SessionsState();
    }
    return state;
  }

  Future<void> refresh() async {
    final connection = ref.read(connectionNotifierProvider);
    final active = connection.active;
    if (active == null || !ref.mounted) return;
    final token = await ref.read(tokenStoreProvider).read(active.id);
    if (!ref.mounted || token == null || token.isEmpty) return;
    final client = ref.read(gatewayClientFactoryProvider)(active.url, token);

    final gen = ++_generation;
    state = state.copyWith(refreshing: true);
    try {
      final list = await client.sessions(limit: 60, includeSaved: true);
      if (gen != _generation || !ref.mounted) return;
      state = state.copyWith(
        live: list.live,
        saved: list.saved,
        loaded: true,
        refreshing: false,
        clearError: true,
      );
      expireTodoStale();
    } on AuthError catch (e) {
      if (gen != _generation || !ref.mounted) return;
      state = state.copyWith(refreshing: false, error: e.message);
      // A confirmed 401 signs the user out; nothing else here does.
      unawaited(ref.read(connectionNotifierProvider.notifier).signOut());
    } on GatewayClientError catch (e) {
      if (gen != _generation || !ref.mounted) return;
      state = state.copyWith(refreshing: false, error: e.message);
    } catch (_) {
      if (gen != _generation || !ref.mounted) return;
      state = state.copyWith(refreshing: false, error: 'Could not load sessions');
    }
  }

  SessionInfo? get(String gwId) =>
      state.live.where((s) => s.gwId == gwId).firstOrNull;

  /// Record whether a session's last known /state had an in_progress todo
  /// task. Replaces the Set so group consumers recompute.
  void setTodoActive(String gwId, bool on) {
    if (on) _lastTodoRefresh[gwId] = ref.read(sessionsClockProvider)();
    if (on == state.todoActive.contains(gwId)) return;
    final next = <String>{...state.todoActive};
    if (on) {
      next.add(gwId);
    } else {
      next.remove(gwId);
    }
    state = state.copyWith(todoActive: next);
  }

  /// The UI calls this when a session screen opens or closes, so
  /// [expireTodoStale] can keep the open session's entry (its /state is being
  /// refreshed) while dropping stale background guesses.
  void setOpenSession(String? gwId) {
    openGwId = gwId;
  }

  /// Replace one live session with a fresher copy (from auth_ok or an info
  /// fetch) without waiting for the poll.
  void patch(SessionInfo info) {
    final live = [...state.live];
    final i = live.indexWhere((s) => s.gwId == info.gwId);
    if (i < 0) {
      live.insert(0, info);
    } else {
      live[i] = info;
    }
    state = state.copyWith(live: live);
  }

  void remove(String gwId) {
    final live = state.live.where((s) => s.gwId != gwId).toList();
    final todo = <String>{...state.todoActive}..remove(gwId);
    _lastTodoRefresh.remove(gwId);
    state = state.copyWith(live: live, todoActive: todo);
  }

  /// Drop todoActive entries gone stale on the global poll: only the open
  /// session keeps having its /state refreshed, so for anything else an old
  /// entry is a guess, not a fact.
  void expireTodoStale() {
    final now = ref.read(sessionsClockProvider)();
    final cutoff = now.subtract(const Duration(milliseconds: todoFreshMs));
    var changed = false;
    final next = <String>{...state.todoActive};
    for (final gwId in state.todoActive) {
      if (gwId == openGwId) continue;
      final at = _lastTodoRefresh[gwId];
      if (at == null || at.isBefore(cutoff)) {
        next.remove(gwId);
        changed = true;
      }
    }
    if (changed) state = state.copyWith(todoActive: next);
  }

  // ------------------------------------------------------------- polling

  /// Start polling (and refresh immediately). The UI calls this when the app
  /// comes to the foreground, [stopPolling] when it leaves.
  void startPolling() {
    if (_timer != null) {
      _polling = true;
      return;
    }
    _polling = true;
    unawaited(Future<void>.microtask(() => refresh()));
    final interval = ref.read(sessionsPollIntervalProvider);
    _timer = Timer.periodic(interval, (_) => refresh());
  }

  void stopPolling() {
    _polling = false;
    _timer?.cancel();
    _timer = null;
  }
}

final sessionsStoreProvider =
    NotifierProvider<SessionsStore, SessionsState>(SessionsStore.new);

/// The rail's grouped view: derives from the sessions list, the todo flags
/// and the review pins.
final sessionGroupsProvider = Provider<SessionGroups>((ref) {
  final sessions = ref.watch(sessionsStoreProvider);
  final needsReview =
      ref.watch(reviewedStoreProvider.select((s) => s.needsReview));
  return groupSessions(
    sessions.live,
    sessions.saved,
    ref.watch(sessionsClockProvider)(),
    sessions.todoActive,
    needsReview,
  );
});
