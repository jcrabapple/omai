// Transcript search models, ported from web SearchView.svelte plus the
// SearchHit type in web/src/lib/api/types.ts. Pure Dart: grouping, label
// fallbacks and snippet segmentation live here so the widget only renders.

import '../../api/models.dart';
import '../../format.dart';

/// The gateway wraps matches in private-use sentinels that cannot collide
/// with transcript text (docs/API.md).
const openSentinel = '\uE000';
const closeSentinel = '\uE001';

/// One hit from `GET /api/search`. Lenient: missing or mistyped fields fall
/// back to nulls and empty strings, never throw.
class SearchHit {
  const SearchHit({
    required this.path,
    required this.line,
    required this.role,
    required this.ts,
    required this.snippet,
    required this.sessionId,
    required this.cwd,
    required this.title,
    required this.archived,
    required this.gwId,
  });

  factory SearchHit.fromJson(Object? json) {
    final m = asMap(json) ?? const <String, dynamic>{};
    return SearchHit(
      path: str(m['path']) ?? '',
      line: intVal(m['line']),
      role: str(m['role']),
      ts: str(m['ts']) ?? '',
      snippet: str(m['snippet']) ?? '',
      sessionId: str(m['sessionId']),
      cwd: str(m['cwd']),
      title: str(m['title']),
      archived: boolVal(m['archived']) ?? false,
      // Present only when that transcript is live on the gateway.
      gwId: str(m['gwId']),
    );
  }

  final String path;
  final int? line;
  final String? role;
  final String ts;
  final String snippet;
  final String? sessionId;
  final String? cwd;
  final String? title;
  final bool archived;

  /// Set only when the transcript is currently live on the gateway.
  final String? gwId;
}

/// `indexed` from the search response; null when the gateway did not send it.
class SearchIndexed {
  const SearchIndexed({required this.files, required this.messages});
  final int files;
  final int messages;
}

/// Parsed `GET /api/search` body.
class SearchResponse {
  const SearchResponse({
    required this.total,
    required this.results,
    required this.indexed,
  });

  factory SearchResponse.fromJson(Object? json) {
    final m = asMap(json) ?? const <String, dynamic>{};
    final list = asList(m['results']) ?? const [];
    final idx = asMap(m['indexed']);
    return SearchResponse(
      total: intVal(m['total']) ?? 0,
      results: [
        for (final e in list)
          if (asMap(e) != null) SearchHit.fromJson(e),
      ],
      indexed: idx == null
          ? null
          : SearchIndexed(
              files: intVal(idx['files']) ?? 0,
              messages: intVal(idx['messages']) ?? 0,
            ),
    );
  }

  final int total;
  final List<SearchHit> results;
  final SearchIndexed? indexed;
}

/// All hits from one transcript, in first-seen order (web `groups`).
class SearchHitGroup {
  const SearchHitGroup({required this.path, required this.hits});
  final String path;
  final List<SearchHit> hits;
}

List<SearchHitGroup> groupSearchHits(List<SearchHit> hits) {
  final byPath = <String, List<SearchHit>>{};
  final order = <String>[];
  for (final hit in hits) {
    final list = byPath[hit.path];
    if (list == null) {
      byPath[hit.path] = [hit];
      order.add(hit.path);
    } else {
      list.add(hit);
    }
  }
  return [
    for (final path in order) SearchHitGroup(path: path, hits: byPath[path]!),
  ];
}

/// Header label for a group, ported from the web `label()` fallback chain:
/// title, else cwd basename, else sessionId, else path.
String searchHitLabel(SearchHit hit) {
  final title = hit.title?.trim() ?? '';
  if (title.isNotEmpty) return title;
  final base = basename(hit.cwd);
  if (base.isNotEmpty) return base;
  final sessionId = hit.sessionId?.trim() ?? '';
  if (sessionId.isNotEmpty) return sessionId;
  return hit.path;
}

/// Port of the web `isLive()`: the hit carries a gwId, or a live session in
/// the sessions store points at the same transcript file and has not exited.
bool searchHitIsLive(SearchHit hit, List<SessionInfo> live) =>
    liveGwIdFor(hit, live) != null;

/// The gwId to open a hit with: the hit's own when present, else the matching
/// live session's. Null means the hit is saved, not live.
String? liveGwIdFor(SearchHit hit, List<SessionInfo> live) {
  if (hit.gwId != null && hit.gwId!.isNotEmpty) return hit.gwId;
  for (final s in live) {
    if (s.ompSessionFile == hit.path && !s.exited) return s.gwId;
  }
  return null;
}

/// One rendered span of a snippet: transcript text, [marked] when it sits
/// between a pair of sentinels (the match).
class SnippetPart {
  const SnippetPart(this.text, {required this.marked});
  final String text;
  final bool marked;

  @override
  bool operator ==(Object other) =>
      other is SnippetPart && other.text == text && other.marked == marked;

  @override
  int get hashCode => Object.hash(text, marked);
}

/// Splits a snippet on the sentinels into plain text runs and marked runs.
/// Snippets are rendered as text, never markup: a transcript that literally
/// contains `<mark>` stays text. Mirror of the web replacement order: an
/// unmatched open sentinel marks the rest of the string; a close sentinel
/// with nothing open is dropped, like the browser drops a stray `</mark>`.
List<SnippetPart> snippetParts(String snippet) {
  final parts = <SnippetPart>[];
  final buf = StringBuffer();
  var marked = false;
  void flush() {
    if (buf.isEmpty) return;
    parts.add(SnippetPart(buf.toString(), marked: marked));
    buf.clear();
  }

  for (final rune in snippet.runes) {
    final ch = String.fromCharCode(rune);
    if (ch == openSentinel) {
      flush();
      marked = true;
    } else if (ch == closeSentinel) {
      flush();
      marked = false;
    } else {
      buf.write(ch);
    }
  }
  flush();
  return parts;
}

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// Local timestamp for a hit row, ported from the web `when()`: empty when
/// the gateway sent no parseable timestamp.
String hitWhen(String ts) {
  final parsed = DateTime.tryParse(ts);
  if (parsed == null) return '';
  final t = parsed.isUtc ? parsed.toLocal() : parsed;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${_months[t.month - 1]} ${t.day}, ${two(t.hour)}:${two(t.minute)}';
}
