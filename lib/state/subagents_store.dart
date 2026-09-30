// Live subagent roster for the open session, folded from subagent_progress
// and subagent_lifecycle frames. Ported from
// web/src/lib/state/subagents.svelte.ts (the fold logic is a direct port and
// the web tests are the conformance suite, see test/state/subagents_store_test.dart).
//
// The gateway subscribes at `progress` level right after v2 negotiation, so
// frames only arrive while the session is open; a reconnect catches up from
// the REST registry snapshot via seed(). The roster is pure Dart (no Flutter
// import) so the fold can be tested without a provider container; the
// notifier below just publishes the sorted rows.
//
// Keys: a row merges by progress.id, falling back to `#index` while omp has
// not assigned one, and migrates to the id when it arrives later.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../wire/wire.dart' show OmpEvent, mapOf, mapField, strOf, intOf, boolOf;

/// Status of one subagent row.
enum SubagentStatus { pending, running, completed, failed, aborted }

/// One roster row. Fields mirror the web SubagentRow so the two codebases
/// can be diffed by eye.
class SubagentRow {
  const SubagentRow({
    required this.key,
    required this.id,
    required this.index,
    required this.agent,
    required this.status,
    required this.task,
    required this.assignment,
    required this.description,
    required this.currentTool,
    required this.tokens,
    required this.cost,
    required this.toolCount,
    required this.durationMs,
    required this.contextTokens,
    required this.contextWindow,
    required this.retry,
    required this.model,
    required this.sessionFile,
    required this.detached,
    required this.seq,
  });

  /// progress.id, or `#index` while omp has not assigned one. Stable merge key.
  final String key;
  final String? id;
  final int? index;
  final String agent;
  final SubagentStatus status;
  final String task;
  final String assignment;

  /// Lifecycle description; progress frames do not carry one.
  final String description;
  final String currentTool;
  final int? tokens;
  final double? cost;
  final int? toolCount;
  final int? durationMs;
  final int? contextTokens;
  final int? contextWindow;
  final SubagentRetry? retry;
  final String model;
  final String sessionFile;
  final bool detached;

  /// Arrival counter, breaks ties for rows whose index is still unknown.
  final int seq;

  /// First lifecycle description, else task, else assignment: the one line
  /// shown under the agent name.
  String get taskText => description.isNotEmpty
      ? description
      : task.isNotEmpty
      ? task
      : assignment;

  SubagentRow copyWith({
    String? key,
    Object? id = _keep,
    int? index,
    String? agent,
    SubagentStatus? status,
    String? task,
    String? assignment,
    String? description,
    String? currentTool,
    int? tokens,
    double? cost,
    int? toolCount,
    int? durationMs,
    int? contextTokens,
    int? contextWindow,
    Object? retry = _keep,
    String? model,
    String? sessionFile,
    bool? detached,
    int? seq,
  }) => SubagentRow(
    key: key ?? this.key,
    id: id == _keep ? this.id : (id as String?),
    index: index ?? this.index,
    agent: agent ?? this.agent,
    status: status ?? this.status,
    task: task ?? this.task,
    assignment: assignment ?? this.assignment,
    description: description ?? this.description,
    currentTool: currentTool ?? this.currentTool,
    tokens: tokens ?? this.tokens,
    cost: cost ?? this.cost,
    toolCount: toolCount ?? this.toolCount,
    durationMs: durationMs ?? this.durationMs,
    contextTokens: contextTokens ?? this.contextTokens,
    contextWindow: contextWindow ?? this.contextWindow,
    retry: retry == _keep ? this.retry : (retry as SubagentRetry?),
    model: model ?? this.model,
    sessionFile: sessionFile ?? this.sessionFile,
    detached: detached ?? this.detached,
    seq: seq ?? this.seq,
  );

  static const _keep = Object();
}

/// Retry badge state, from a progress frame's retryState.
class SubagentRetry {
  const SubagentRetry({required this.attempt, required this.maxAttempts});
  final int attempt;
  final int maxAttempts;

  @override
  bool operator ==(Object other) =>
      other is SubagentRetry &&
      other.attempt == attempt &&
      other.maxAttempts == maxAttempts;

  @override
  int get hashCode => Object.hash(attempt, maxAttempts);
}

SubagentStatus? _progressStatus(String? v) => switch (v) {
  'pending' => SubagentStatus.pending,
  'running' => SubagentStatus.running,
  'completed' => SubagentStatus.completed,
  'failed' => SubagentStatus.failed,
  'aborted' => SubagentStatus.aborted,
  _ => null,
};

/// Lifecycle statuses map onto SubagentStatus; `started` is display-running
/// because the running status itself lives in progress frames.
SubagentStatus? _lifecycleStatus(String? v) => switch (v) {
  'started' => SubagentStatus.running,
  'completed' => SubagentStatus.completed,
  'failed' => SubagentStatus.failed,
  'aborted' => SubagentStatus.aborted,
  _ => null,
};

bool _isTerminal(SubagentStatus s) =>
    s != SubagentStatus.pending && s != SubagentStatus.running;

/// The fold, ported one-to-one from the web store. Not reactive by itself:
/// the notifier wraps it and publishes [rows] on every change.
class SubagentRoster {
  final Map<String, SubagentRow> _byKey = {};
  final List<SubagentRow> _rows = [];
  int _order = 0;

  /// Rows sorted by index (unknown last, arrival order within).
  List<SubagentRow> get rows => List.unmodifiable(_rows);

  int get running =>
      _rows.where((r) => r.status == SubagentStatus.running).length;
  int get failed =>
      _rows.where((r) => r.status == SubagentStatus.failed).length;
  int get total => _rows.length;
  bool get hasAny => _rows.isNotEmpty;

  /// Session switch (active.close also runs it when another session opens).
  void clear() {
    _byKey.clear();
    _rows.clear();
  }

  /// One omp event; only subagent_progress / subagent_lifecycle fold.
  void feed(Map<String, Object?> event) {
    if (event['type'] == 'subagent_progress') {
      final p = mapField(event, 'payload');
      if (p != null) _foldProgress(p);
    } else if (event['type'] == 'subagent_lifecycle') {
      final p = mapField(event, 'payload');
      if (p != null) _foldLifecycle(p);
    }
  }

  /// Registry snapshot from GET /subagents. Entries mirror the progress
  /// payload at the top level (with an optional nested `progress`); junk
  /// entries are skipped.
  void seed(Object? data) {
    List<Object?>? list = data is List<Object?> ? data : null;
    list ??= mapOf(data)?['subagents'] is List
        ? (mapOf(data)!['subagents'] as List).cast<Object?>()
        : null;
    if (list == null) return;
    for (final raw in list) {
      final p = mapOf(raw);
      if (p != null) _foldProgress(p);
    }
  }

  SubagentRow? byKey(String key) => _byKey[key];

  // ------------------------------------------------------------ folding

  /// Merge one progress payload (or registry entry) into the roster by key.
  void _foldProgress(Map<String, Object?> p) {
    final src = mapOf(p['progress']) ?? p;
    final id = strOf(src, 'id') ?? strOf(p, 'id');
    final index = intOf(src, 'index') ?? intOf(p, 'index');
    final key = _keyFor(id, index);
    var existing = _byKey[key];
    // An id arriving after a #index row: migrate the row to the id key.
    if (id != null && existing == null && index != null) {
      existing = _byKey['#$index'];
      if (existing != null) _byKey.remove('#$index');
    }
    final seq = existing?.seq ?? ++_order;
    final incomingStatus = _progressStatus(strOf(src, 'status'));
    final isTerminal = existing != null && _isTerminal(existing.status);
    var status = existing?.status ?? SubagentStatus.pending;
    if (incomingStatus != null) {
      if (isTerminal &&
          (incomingStatus == SubagentStatus.running ||
              incomingStatus == SubagentStatus.pending)) {
        // preserve terminal status
      } else if (existing?.status == SubagentStatus.running &&
          incomingStatus == SubagentStatus.pending) {
        // running subagent should not regress to pending
      } else {
        status = incomingStatus;
      }
    }
    final terminal = _isTerminal(status);
    final row = (existing ?? _emptyRow(key, seq)).copyWith(
      key: key,
      id: id ?? existing?.id,
      index: intOf(src, 'index') ?? intOf(p, 'index') ?? existing?.index,
      agent: _firstStr([
        strOf(src, 'agent'),
        strOf(p, 'agent'),
        existing?.agent,
      ]),
      status: status,
      task: _firstStr([strOf(src, 'task'), strOf(p, 'task'), existing?.task]),
      assignment: _firstStr([
        strOf(src, 'assignment'),
        strOf(p, 'assignment'),
        existing?.assignment,
      ]),
      description: existing?.description ?? '',
      // Nothing is running once the row is terminal, whatever the last frame said.
      currentTool: terminal
          ? ''
          : _firstStr([strOf(src, 'currentTool'), existing?.currentTool]),
      tokens: intOf(src, 'tokens') ?? existing?.tokens,
      cost: _numOf(src, 'cost') ?? existing?.cost,
      toolCount: intOf(src, 'toolCount') ?? existing?.toolCount,
      durationMs: intOf(src, 'durationMs') ?? existing?.durationMs,
      contextTokens: intOf(src, 'contextTokens') ?? existing?.contextTokens,
      contextWindow: intOf(src, 'contextWindow') ?? existing?.contextWindow,
      retry: _retryOf(mapOf(src['retryState']), existing?.retry),
      model: _firstStr([strOf(src, 'resolvedModel'), existing?.model]),
      sessionFile: _firstStr([strOf(p, 'sessionFile'), existing?.sessionFile]),
      detached: boolOf(p, 'detached') ?? existing?.detached ?? false,
      seq: seq,
    );
    _put(row);
  }

  void _foldLifecycle(Map<String, Object?> l) {
    final mapped = _lifecycleStatus(strOf(l, 'status'));
    if (mapped == null) return;
    final id = strOf(l, 'id');
    final index = intOf(l, 'index');
    final key = _keyFor(id, index);
    var existing = _byKey[key];
    if (id != null && existing == null && index != null) {
      existing = _byKey['#$index'];
      if (existing != null) _byKey.remove('#$index');
    }
    final seq = existing?.seq ?? ++_order;
    // Terminal lifecycle statuses are authoritative; `started` only promotes
    // rows that never got a progress status and never regresses a terminal one.
    final status =
        mapped == SubagentStatus.running &&
            existing != null &&
            _isTerminal(existing.status)
        ? existing.status
        : mapped;
    final prev = existing ?? _emptyRow(key, seq);
    final row = prev.copyWith(
      key: key,
      id: id ?? existing?.id,
      index: intOf(l, 'index') ?? existing?.index,
      agent: _firstStr([strOf(l, 'agent'), existing?.agent]),
      status: status,
      description: _firstStr([strOf(l, 'description'), existing?.description]),
      currentTool: mapped == SubagentStatus.running
          ? existing?.currentTool ?? ''
          : '',
      sessionFile: _firstStr([strOf(l, 'sessionFile'), existing?.sessionFile]),
      detached: boolOf(l, 'detached') ?? existing?.detached ?? false,
      seq: seq,
    );
    _put(row);
  }

  void _put(SubagentRow row) {
    _byKey[row.key] = row;
    _rows
      ..clear()
      ..addAll(
        _byKey.values.toList()..sort((a, b) {
          final ai = a.index ?? 0x7fffffffffffffff;
          final bi = b.index ?? 0x7fffffffffffffff;
          return ai != bi ? ai.compareTo(bi) : a.seq.compareTo(b.seq);
        }),
      );
  }

  String _keyFor(String? id, int? index) =>
      id ?? (index != null ? '#$index' : '#$_order');
}

/// First non-null, non-empty string; missing or junk fields collapse to ''.
String _firstStr(List<String?> vals) =>
    vals.firstWhere((v) => v != null && v.isNotEmpty, orElse: () => '') ?? '';

double? _numOf(Map<String, Object?> m, String k) =>
    m[k] is num ? (m[k] as num).toDouble() : null;

SubagentRetry? _retryOf(Map<String, Object?>? rs, SubagentRetry? prev) {
  if (rs == null) return prev;
  final attempt = intOf(rs, 'attempt');
  final maxAttempts = intOf(rs, 'maxAttempts');
  if (attempt == null && maxAttempts == null) return prev;
  return SubagentRetry(
    attempt: attempt ?? prev?.attempt ?? 0,
    maxAttempts: maxAttempts ?? prev?.maxAttempts ?? 0,
  );
}

/// Row shape before any progress frame has arrived.
SubagentRow _emptyRow(String key, int seq) => SubagentRow(
  key: key,
  id: null,
  index: null,
  agent: '',
  status: SubagentStatus.pending,
  task: '',
  assignment: '',
  description: '',
  currentTool: '',
  tokens: null,
  cost: null,
  toolCount: null,
  durationMs: null,
  contextTokens: null,
  contextWindow: null,
  retry: null,
  model: '',
  sessionFile: '',
  detached: false,
  seq: seq,
);

/// Publishes the roster's rows. One instance for the app, like the web
/// singleton; the open session feeds it and clears it on dispose.
class SubagentsStore extends Notifier<List<SubagentRow>> {
  final SubagentRoster _roster = SubagentRoster();

  @override
  List<SubagentRow> build() => const [];

  /// Live events: subagent_progress / subagent_lifecycle.
  void feed(OmpEvent event) {
    _roster.feed(event.raw);
    _publish();
  }

  /// REST registry snapshot from GET /sessions/{id}/subagents.
  void seed(Object? data) {
    _roster.seed(data);
    _publish();
  }

  /// Session switch / controller teardown.
  void clear() {
    _roster.clear();
    _publish();
  }

  void _publish() {
    // Container torn down mid-teardown (screen dispose during container
    // dispose): writing state here throws in Riverpod 3.
    if (!ref.mounted) return;
    state = _roster.rows.toList();
  }
}

final subagentsStoreProvider =
    NotifierProvider<SubagentsStore, List<SubagentRow>>(SubagentsStore.new);
