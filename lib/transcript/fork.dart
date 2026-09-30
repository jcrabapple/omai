// Fork (branch) support: pure matching and prefix logic, no stores. Ported
// from web/src/lib/fork.ts.
//
// omp's `branch` copies the transcript strictly BEFORE the target user entry
// (a root entry starts an empty session linked to the old file), so the fork
// point's own message is expected to be absent from the forked session; the
// gateway returns its text for a composer prefill instead.

import 'items.dart';

/// One row of GET /sessions/{id}/entries: `{entryId, role, timestamp}`. The
/// `entryId`s are the fork targets; only `role: 'user'` rows branch.
class SessionEntry {
  final String entryId;
  final String role;
  final int? timestamp;

  const SessionEntry({
    required this.entryId,
    required this.role,
    this.timestamp,
  });

  static SessionEntry? fromJson(Object? v) {
    if (v is! Map) return null;
    final id = v['entryId'];
    final role = v['role'];
    if (id is! String || role is! String) return null;
    final ts = v['timestamp'];
    return SessionEntry(
      entryId: id,
      role: role,
      timestamp: ts is num ? ts.toInt() : null,
    );
  }
}

/// User items a fork can target: settled and echoed by omp, so an entry
/// exists.
bool forkable(Item item) =>
    item is UserItem &&
    !item.pending &&
    item.failed != true &&
    item.text.trim().isNotEmpty;

/// User texts, in order, for everything strictly before [item] (the prefix the
/// forked session should carry). Items are matched by id; a missing target
/// yields null, so the caller skips the prefix check instead of verifying
/// against an empty expectation.
List<String>? userTextsBefore(List<Item> items, UserItem item) {
  final out = <String>[];
  var found = false;
  for (final it in items) {
    if (it is UserItem && it.id == item.id) {
      found = true;
      break;
    }
    if (forkable(it)) out.add((it as UserItem).text.trim());
  }
  return found ? out : null;
}

/// The live entry for a transcript item: same timestamp. A miss means the live
/// history diverged (compacted, another device) and the caller must confirm
/// before forking instead of navigating blind.
SessionEntry? entryForItem(UserItem item, List<SessionEntry> entries) {
  final ts = item.timestamp;
  if (ts == null) return null;
  for (final e in entries) {
    if (e.role == 'user' && e.timestamp == ts) return e;
  }
  return null;
}

String _textBlock(Object? b) {
  if (b is! Map) return '';
  if (b['type'] != 'text') return '';
  final t = b['text'];
  return t is String ? t : '';
}

/// User texts from gateway messages (the forked session's transcript). Mirrors
/// the reducer exactly: skill prompts are skill items, not user bubbles, and a
/// message's text blocks concatenate into ONE entry per message.
List<String> userTexts(List<Object?> messages) {
  final out = <String>[];
  for (final raw in messages) {
    if (raw is! Map) continue;
    if (raw['role'] != 'user' || raw['customType'] == 'skill-prompt') continue;
    final content = raw['content'];
    final text = content is String
        ? content
        : content is List
        ? content.map(_textBlock).join()
        : '';
    final t = text.trim();
    if (t.isNotEmpty) out.add(t);
  }
  return out;
}

/// True when the forked session's transcript does not start with the expected
/// ancestor prefix. Only the prefix is compared; extra history after it is
/// fine.
bool prefixMissing(List<String> expected, List<String> actual) {
  if (actual.length < expected.length) return true;
  for (var i = 0; i < expected.length; i++) {
    if (actual[i] != expected[i]) return true;
  }
  return false;
}
