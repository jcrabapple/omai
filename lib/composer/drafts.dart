// Per-session composer drafts, ported from web/src/lib/composer/drafts.ts
// (scoped localStorage there, SharedPreferences here). The key is namespaced
// by connection id + gateway session id (CLIENTS.md rule 6). A draft outlives
// reloads, reconnects and the session itself.
//
// Pure Dart: persistence goes through [DraftKv] so tests run on a map.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persistence seam so tests run against an in-memory map.
abstract class DraftKv {
  Future<String?> get(String key);
  Future<void> set(String key, String value);
  Future<void> remove(String key);
}

class SharedPreferencesDraftKv implements DraftKv {
  final SharedPreferencesAsync _prefs = SharedPreferencesAsync();

  @override
  Future<String?> get(String key) => _prefs.getString(key);

  @override
  Future<void> set(String key, String value) => _prefs.setString(key, value);

  @override
  Future<void> remove(String key) => _prefs.remove(key);
}

final draftKvProvider = Provider<DraftKv>((ref) => SharedPreferencesDraftKv());

/// Storage key for one session's draft on one connection.
String draftKey(String connId, String gwId) => 'ompgw-draft:$connId:$gwId';

Future<String> loadDraft(DraftKv kv, String connId, String gwId) async {
  final v = await kv.get(draftKey(connId, gwId));
  return v ?? '';
}

/// Empty or whitespace-only text clears the stored draft.
Future<void> saveDraft(DraftKv kv, String connId, String gwId, String text) async {
  final key = draftKey(connId, gwId);
  if (text.trim().isNotEmpty) {
    await kv.set(key, text);
  } else {
    await kv.remove(key);
  }
}

Future<void> clearDraft(DraftKv kv, String connId, String gwId) =>
    kv.remove(draftKey(connId, gwId));
