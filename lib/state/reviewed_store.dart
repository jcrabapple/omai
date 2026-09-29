// Per-device review markers, ported from web/src/lib/state/reviewed.svelte.ts.
// The gateway has no notion of "reviewed", so this is device-local: two sets
// of gateway session ids, each persisted as a JSON array, with the keys
// namespaced by connection id.
//   done        - sessions the user marked done (dashboard-side marker only;
//                 it never touches the omp session file)
//   needsReview - sessions the user pinned for review ("Ready for review"
//                 group); auto-cleared when a prompt is sent from the session
//                 (that send path is D2).

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'connection_notifier.dart';

/// Persistence seam so tests run against an in-memory map.
abstract class ReviewedKv {
  Future<String?> get(String key);
  Future<void> set(String key, String value);
}

class SharedPreferencesReviewedKv implements ReviewedKv {
  final SharedPreferencesAsync _prefs = SharedPreferencesAsync();

  @override
  Future<String?> get(String key) => _prefs.getString(key);

  @override
  Future<void> set(String key, String value) => _prefs.setString(key, value);
}

final reviewedKvProvider =
    Provider<ReviewedKv>((ref) => SharedPreferencesReviewedKv());

/// Cap on the done ledger: gwIds are ephemeral per run and nothing prunes
/// them on session exit, so an unbounded set would grow on the device forever.
const doneLedgerCap = 500;

class ReviewedState {
  const ReviewedState({this.done = const {}, this.needsReview = const {}});

  final Set<String> done;
  final Set<String> needsReview;
}

class ReviewedStore extends Notifier<ReviewedState> {
  String _connId = '';
  bool _dirty = false;
  String get _doneKey => 'ompgw-reviewed:$_connId';
  String get _reviewKey => 'ompgw-needs-review:$_connId';

  ReviewedKv get _kv => ref.read(reviewedKvProvider);

  @override
  ReviewedState build() {
    _connId = ref.watch(connectionNotifierProvider
        .select((s) => s.active?.id ?? ''));
    _dirty = false;
    // Reload whatever this connection has persisted.
    _load();
    return const ReviewedState();
  }

  Future<void> _load() async {
    final done = _loadSet(await _kv.get(_doneKey));
    final needsReview = _loadSet(await _kv.get(_reviewKey));
    // The user (or a store method) already acted before the load finished:
    // their writes win over the persisted snapshot.
    if (!ref.mounted || _dirty) return;
    state = ReviewedState(done: done, needsReview: needsReview);
  }

  /// A stored value is a JSON array of strings; anything else resets the set.
  Set<String> _loadSet(String? raw) {
    if (raw == null) return {};
    List<Object?> decoded;
    try {
      final v = jsonDecode(raw);
      if (v is! List) return {};
      decoded = v;
    } on FormatException {
      return {};
    }
    return {for (final v in decoded) if (v is String) v};
  }

  /// True when the session was marked done.
  bool has(String gwId) => state.done.contains(gwId);

  Future<void> markDone(String gwId) async {
    _dirty = true;
    if (state.done.contains(gwId)) return;
    final next = <String>{...state.done};
    next.add(gwId);
    while (next.length > doneLedgerCap) {
      next.remove(next.first);
    }
    state = ReviewedState(done: next, needsReview: state.needsReview);
    await _kv.set(_doneKey, jsonEncode(next.toList()));
    // Recording done removes the review pin; callers shouldn't have to pair
    // the two.
    await unflag(gwId);
  }

  Future<void> undo(String gwId) async {
    _dirty = true;
    if (!state.done.contains(gwId)) return;
    final next = <String>{...state.done}..remove(gwId);
    state = ReviewedState(done: next, needsReview: state.needsReview);
    await _kv.set(_doneKey, jsonEncode(next.toList()));
  }

  Future<void> clear() async {
    state = ReviewedState(done: const {}, needsReview: state.needsReview);
    await _kv.set(_doneKey, '[]');
  }

  Future<void> flag(String gwId) async {
    _dirty = true;
    if (state.needsReview.contains(gwId)) return;
    final next = <String>{...state.needsReview, gwId};
    state = ReviewedState(done: state.done, needsReview: next);
    await _kv.set(_reviewKey, jsonEncode(next.toList()));
  }

  Future<void> unflag(String gwId) async {
    _dirty = true;
    if (!state.needsReview.contains(gwId)) return;
    final next = <String>{...state.needsReview}..remove(gwId);
    state = ReviewedState(done: state.done, needsReview: next);
    await _kv.set(_reviewKey, jsonEncode(next.toList()));
  }
}

final reviewedStoreProvider =
    NotifierProvider<ReviewedStore, ReviewedState>(ReviewedStore.new);
