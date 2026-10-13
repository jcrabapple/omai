// Per-device rail preferences, ported from the web dashboard
// (web/src/lib/state/pins.svelte.ts and folders.svelte.ts):
//
// - Pinned sessions: saved transcripts the user pinned float to a "Pinned"
//   section above the dated history. Keyed on the transcript file path, which
//   is stable across resumes and gateway restarts (gw ids are not).
// - Hidden folders: whole folders of saved transcripts (scheduler runs in ~,
//   throwaway probes in /tmp) drop out of the dated history. Nothing is
//   deleted; live sessions and pinned transcripts are never hidden. Keyed on
//   the transcript's recorded cwd, else omp's mangled folder name.
//
// Both are device-local sets namespaced by connection id (CLIENTS.md rule 6),
// persisted as JSON arrays through the same storage seam as the review
// markers, like hidden_cwds.dart.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection_notifier.dart';
import 'reviewed_store.dart';

/// Cap so a set can't grow without bound on the device.
const railPrefsCap = 500;

String pinnedSessionsKey(String connId) => 'ompgw-pinned-sessions:$connId';
String hiddenFoldersKey(String connId) => 'ompgw-rail-hidden-folders:$connId';

abstract class _ConnectionSetStore extends Notifier<Set<String>> {
  String _connId = '';
  bool _dirty = false;

  String keyFor(String connId);

  ReviewedKv get _kv => ref.read(reviewedKvProvider);

  @override
  Set<String> build() {
    _connId = ref.watch(
      connectionNotifierProvider.select((s) => s.active?.id ?? ''),
    );
    _dirty = false;
    _load(_connId);
    return const {};
  }

  Future<void> _load(String connId) async {
    final raw = await _kv.get(keyFor(connId));
    // A change before the load finished wins; so does a connection switch.
    if (!ref.mounted || _dirty || _connId != connId) return;
    state = decodeStringSet(raw);
  }

  Future<void> _write(Set<String> next) async {
    _dirty = true;
    state = next;
    await _kv.set(keyFor(_connId), jsonEncode(next.toList()));
  }

  bool contains(String value) => state.contains(value);

  Future<void> toggle(String value) async {
    if (value.isEmpty) return;
    if (state.contains(value)) {
      await _write({...state}..remove(value));
      return;
    }
    final list = [...state, value];
    // Oldest entries drop first once over the cap.
    await _write(
      list
          .skip(list.length > railPrefsCap ? list.length - railPrefsCap : 0)
          .toSet(),
    );
  }

  Future<void> remove(String value) async {
    if (!state.contains(value)) return;
    await _write({...state}..remove(value));
  }

  Future<void> clear() async {
    if (state.isEmpty) return;
    await _write(const {});
  }
}

/// A JSON array of non-empty strings, or an empty set for anything else.
Set<String> decodeStringSet(String? raw) {
  if (raw == null) return {};
  try {
    final v = jsonDecode(raw);
    if (v is! List) return {};
    return {
      for (final e in v)
        if (e is String && e.isNotEmpty) e,
    };
  } on FormatException {
    return {};
  }
}

class PinnedSessionsStore extends _ConnectionSetStore {
  @override
  String keyFor(String connId) => pinnedSessionsKey(connId);
}

class HiddenFoldersStore extends _ConnectionSetStore {
  @override
  String keyFor(String connId) => hiddenFoldersKey(connId);

  /// Unhide every folder.
  Future<void> showAll() => clear();
}

final pinnedSessionsProvider =
    NotifierProvider<PinnedSessionsStore, Set<String>>(PinnedSessionsStore.new);

final hiddenFoldersProvider = NotifierProvider<HiddenFoldersStore, Set<String>>(
  HiddenFoldersStore.new,
);
