// Pure grouping of the sessions list into the rail's sections.
// Ported from web/src/lib/state/grouping.ts (and grouping.test.ts).

import '../api/models.dart';

enum HistoryBucketKey { today, yesterday, week, older }

String historyBucketLabel(HistoryBucketKey key) => switch (key) {
      HistoryBucketKey.today => 'Today',
      HistoryBucketKey.yesterday => 'Yesterday',
      HistoryBucketKey.week => 'Previous 7 days',
      HistoryBucketKey.older => 'Earlier',
    };

class HistoryGroup {
  const HistoryGroup({required this.key, required this.items});

  final HistoryBucketKey key;
  final List<SavedSession> items;

  String get label => historyBucketLabel(key);

  @override
  bool operator ==(Object other) =>
      other is HistoryGroup && other.key == key && _listEq(other.items, items);

  @override
  int get hashCode => Object.hash(key, Object.hashAll(items));
}

bool _listEq<T>(List<T> a, List<T> b) =>
    a.length == b.length && a.indexed.every((e) => b[e.$1] == e.$2);

class SessionGroups {
  const SessionGroups({
    required this.needsYou,
    required this.review,
    required this.running,
    required this.idle,
    required this.history,
    this.pinned = const [],
    this.hiddenCount = 0,
  });

  final List<SessionInfo> needsYou;
  final List<SessionInfo> review;
  final List<SessionInfo> running;
  final List<SessionInfo> idle;
  final List<HistoryGroup> history;

  /// Saved transcripts the user pinned; rendered above the dated history.
  final List<SavedSession> pinned;

  /// Saved transcripts left out of [history] by the folder filter.
  final int hiddenCount;

  static const empty = SessionGroups(
    needsYou: [],
    review: [],
    running: [],
    idle: [],
    history: [],
  );

  @override
  bool operator ==(Object other) =>
      other is SessionGroups &&
      _listEq(other.needsYou, needsYou) &&
      _listEq(other.review, review) &&
      _listEq(other.running, running) &&
      _listEq(other.idle, idle) &&
      _listEq(other.history, history) &&
      _listEq(other.pinned, pinned) &&
      other.hiddenCount == hiddenCount;

  @override
  int get hashCode => Object.hash(needsYou.length, review.length, running.length,
      idle.length, history.length, pinned.length, hiddenCount);
}

/// The folder filter's key for a saved transcript: its recorded cwd, else
/// omp's mangled folder name (web grouping.ts folderKey).
String folderKey(SavedSession s) {
  final cwd = s.cwd;
  return cwd != null && cwd.isNotEmpty ? cwd : s.cwdFolder;
}

/// One folder in the filter menu with how many transcripts it would hide.
class FolderCount {
  const FolderCount(this.key, this.count);
  final String key;
  final int count;

  @override
  bool operator ==(Object other) =>
      other is FolderCount && other.key == key && other.count == count;

  @override
  int get hashCode => Object.hash(key, count);

  @override
  String toString() => 'FolderCount($key, $count)';
}

/// Folders the filter can act on, busiest first (ties by name). Only
/// transcripts the filter could actually hide count: live/running and pinned
/// ones always show (web Rail.svelte `folders`).
List<FolderCount> folderCounts(
  List<SavedSession> saved, {
  List<SessionInfo> live = const [],
  Set<String> pinned = const {},
}) {
  final liveFiles = {
    for (final s in live)
      if (!s.exited && (s.ompSessionFile ?? '').isNotEmpty) s.ompSessionFile!,
  };
  final counts = <String, int>{};
  for (final s in saved) {
    if (s.running || liveFiles.contains(s.file) || pinned.contains(s.file)) {
      continue;
    }
    final key = folderKey(s);
    if (key.isEmpty) continue;
    counts[key] = (counts[key] ?? 0) + 1;
  }
  final out = [for (final e in counts.entries) FolderCount(e.key, e.value)];
  out.sort((a, b) {
    final c = b.count.compareTo(a.count);
    return c != 0 ? c : a.key.compareTo(b.key);
  });
  return out;
}

DateTime _startOfDay(DateTime ms) =>
    DateTime(ms.year, ms.month, ms.day);

/// Which history bucket a transcript's mtime (seconds since epoch) falls in,
/// judged against the local calendar day of [now].
HistoryBucketKey historyBucket(double mtimeSec, DateTime now) {
  final today = _startOfDay(now);
  final t = DateTime.fromMillisecondsSinceEpoch((mtimeSec * 1000).round());
  if (!t.isBefore(today)) return HistoryBucketKey.today;
  final yesterday = today.subtract(const Duration(days: 1));
  if (!t.isBefore(yesterday)) return HistoryBucketKey.yesterday;
  final week = today.subtract(const Duration(days: 7));
  return t.isBefore(week) ? HistoryBucketKey.older : HistoryBucketKey.week;
}

/// Live sessions that have exited are dropped; saved sessions that are live
/// right now are dropped. [todoActive] holds sessions whose last known state
/// has an in_progress todo task; they read as working even between agent
/// turns. [needsReview] holds sessions the user pinned for review; they read
/// as ready for review while idle, but anything working or asking for input
/// outranks the pin (needs you > running > review > idle). [pinned]
/// transcript files leave the dated history for [SessionGroups.pinned]
/// (newest first); [hiddenFolders] (folder filter, see [folderKey]) only thins
/// the dated history and is counted in [SessionGroups.hiddenCount].
SessionGroups groupSessions(
  List<SessionInfo> live,
  List<SavedSession> saved,
  DateTime now, [
  Set<String> todoActive = const {},
  Set<String> needsReview = const {},
  Set<String> pinned = const {},
  Set<String> hiddenFolders = const {},
]) {
  final needsYou = <SessionInfo>[];
  final review = <SessionInfo>[];
  final running = <SessionInfo>[];
  final idle = <SessionInfo>[];
  final liveFiles = <String>{};
  for (final s in live) {
    if (s.exited) continue;
    final file = s.ompSessionFile;
    if (file != null && file.isNotEmpty) liveFiles.add(file);
    if (s.pendingUi.isNotEmpty) {
      needsYou.add(s);
    } else if (s.isStreaming || todoActive.contains(s.gwId)) {
      running.add(s);
    } else if (needsReview.contains(s.gwId)) {
      review.add(s);
    } else {
      idle.add(s);
    }
  }

  final buckets = <HistoryBucketKey, List<SavedSession>>{};
  final pinnedItems = <SavedSession>[];
  var hiddenCount = 0;
  final sorted = [...saved]..sort((a, b) => b.mtime.compareTo(a.mtime));
  for (final s in sorted) {
    if (s.running || liveFiles.contains(s.file)) continue;
    if (pinned.contains(s.file)) {
      pinnedItems.add(s);
      continue;
    }
    if (hiddenFolders.isNotEmpty && hiddenFolders.contains(folderKey(s))) {
      hiddenCount++;
      continue;
    }
    buckets
        .putIfAbsent(historyBucket(s.mtime, now), () => [])
        .add(s);
  }
  final history = <HistoryGroup>[];
  for (final key in HistoryBucketKey.values) {
    final items = buckets[key];
    if (items != null && items.isNotEmpty) {
      history.add(HistoryGroup(key: key, items: items));
    }
  }
  return SessionGroups(
    needsYou: needsYou,
    review: review,
    running: running,
    idle: idle,
    history: history,
    pinned: pinnedItems,
    hiddenCount: hiddenCount,
  );
}
