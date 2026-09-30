// Folders the user removed from the New session sheet's recent-folder chips.
// The chips are derived from the gateway's live and saved sessions, and those
// saved transcripts are not ours to delete, so "remove from history" is a
// device-local hide list: a set of paths per connection, persisted as a JSON
// array under 'ompgw-hidden-cwds:<connId>' (same storage seam as the review
// markers). Starting a new session in a hidden folder unhides it: it's recent
// again.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection_notifier.dart';
import 'reviewed_store.dart';

/// Cap so the list can't grow without bound on the device.
const hiddenCwdsCap = 200;

String hiddenCwdsKey(String connId) => 'ompgw-hidden-cwds:$connId';

class HiddenCwdsStore extends Notifier<Set<String>> {
  String _connId = '';
  bool _dirty = false;

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
    final raw = await _kv.get(hiddenCwdsKey(connId));
    // A hide/unhide before the load finished wins; so does a connection
    // switch (the data belongs to the old connection).
    if (!ref.mounted || _dirty || _connId != connId) return;
    state = _decode(raw);
  }

  static Set<String> _decode(String? raw) {
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

  Future<void> _write(Set<String> next) async {
    _dirty = true;
    state = next;
    await _kv.set(hiddenCwdsKey(_connId), jsonEncode(next.toList()));
  }

  Future<void> hide(String cwd) async {
    if (cwd.isEmpty || state.contains(cwd)) return;
    final list = [...state, cwd];
    // Oldest entries drop first once over the cap.
    final next = list
        .skip(list.length > hiddenCwdsCap ? list.length - hiddenCwdsCap : 0)
        .toSet();
    await _write(next);
  }

  Future<void> unhide(String cwd) async {
    if (!state.contains(cwd)) return;
    await _write({...state}..remove(cwd));
  }
}

final hiddenCwdsProvider = NotifierProvider<HiddenCwdsStore, Set<String>>(
  HiddenCwdsStore.new,
);
