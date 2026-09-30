// @-file mentions: which text opens the suggestion query, ranking, insertion.
// Pure and Flutter-free, ported from web/src/lib/composer/atQuery.ts so the
// whole lifecycle is testable without a widget.

/// One row of the gateway's `GET /sessions/{id}/files` listing.
class FileIndexEntry {
  const FileIndexEntry({
    required this.name,
    required this.path,
    required this.isDir,
    this.size,
  });

  factory FileIndexEntry.fromJson(Map<String, Object?> json) => FileIndexEntry(
    name: json['name'] as String? ?? '',
    path: json['path'] as String? ?? '',
    isDir: json['isDir'] == true,
    size: json['size'] is int ? json['size'] as int : null,
  );

  final String name;
  final String path;
  final bool isDir;

  /// Bytes; null for directories.
  final int? size;
}

/// The @-query in the text before the caret, or null.
class AtQuery {
  const AtQuery({
    required this.start,
    required this.query,
    required this.quoted,
  });

  /// Offset of the '@' (or '@"') that opened the query, in the text before
  /// the caret.
  final int start;
  final String query;

  /// Opened with `@"`; the query may then contain spaces until a closing
  /// quote.
  final bool quoted;

  @override
  bool operator ==(Object other) =>
      other is AtQuery &&
      other.start == start &&
      other.query == query &&
      other.quoted == quoted;

  @override
  int get hashCode => Object.hash(start, query, quoted);
}

final RegExp _plainAt = RegExp(r'(?:^|\s)@(\S*)$');
final RegExp _whitespace = RegExp(r'\s');

bool _isWhitespaceChar(String c) => c.isEmpty || _whitespace.hasMatch(c);

/// The @-query in the text before the caret, or null.
/// `@` triggers only at line start or after whitespace, so email addresses
/// never fire. The plain query is the trailing run of non-whitespace; the
/// quoted form `@"...` stays open (spaces allowed) until a closing quote.
AtQuery? extractAtQuery(String beforeCaret) {
  final q = beforeCaret.lastIndexOf('@"');
  if (q != -1) {
    // '' when the @" sits at index 0.
    final prev = q == 0 ? '' : beforeCaret.substring(q - 1, q);
    final opened = prev.isEmpty || _whitespace.hasMatch(prev);
    final rest = beforeCaret.substring(q + 2);
    if (opened && !rest.contains('"')) {
      return AtQuery(start: q, query: rest, quoted: true);
    }
  }
  final m = _plainAt.firstMatch(beforeCaret);
  if (m == null) return null;
  final head = m[0]!;
  return AtQuery(
    start: m.start + head.indexOf('@'),
    query: m[1]!,
    quoted: false,
  );
}

/// What to list for a query: its directory part. "src/ma" -> "src", "ma" -> "".
String atDirPrefix(String query) {
  final cut = query.lastIndexOf('/');
  return cut == -1 ? '' : query.substring(0, cut);
}

/// TUI-style tiers: 0 exact prefix of path or name, 1 substring after a word
/// boundary, 2 fuzzy subsequence, 3 no match (dropped). Case-insensitive.
int _matchTier(FileIndexEntry entry, String q) {
  final path = entry.path.toLowerCase();
  final name = entry.name.toLowerCase();
  if (path.startsWith(q) || name.startsWith(q)) return 0;
  for (final hay in [path, name]) {
    var i = hay.indexOf(q, 1); // index 0 would have been the prefix tier
    while (i != -1) {
      if (_wordBoundary.contains(hay[i - 1])) return 1;
      i = hay.indexOf(q, i + 1);
    }
  }
  return _isSubsequence(q, path) || _isSubsequence(q, name) ? 2 : 3;
}

const _wordBoundary = '/_.- ';

bool _isSubsequence(String needle, String hay) {
  var i = 0;
  for (var h = 0; h < hay.length && i < needle.length; h++) {
    if (hay[h] == needle[i]) i++;
  }
  return i == needle.length;
}

/// Empty query order: dirs first, then files, then shorter names.
int _byEmptyOrder(FileIndexEntry a, FileIndexEntry b) {
  final byDir = (b.isDir ? 1 : 0).compareTo(a.isDir ? 1 : 0);
  if (byDir != 0) return byDir;
  final byLen = a.name.length.compareTo(b.name.length);
  if (byLen != 0) return byLen;
  return a.path.compareTo(b.path);
}

/// Matched order ties: dirs first, then shorter paths.
int _byRankOrder(FileIndexEntry a, FileIndexEntry b) {
  final byDir = (b.isDir ? 1 : 0).compareTo(a.isDir ? 1 : 0);
  if (byDir != 0) return byDir;
  final byLen = a.path.length.compareTo(b.path.length);
  if (byLen != 0) return byLen;
  return a.path.compareTo(b.path);
}

/// Best matches first. An empty query keeps every entry in empty-order; a
/// non-empty query drops non-matches. Callers slice the top N.
List<FileIndexEntry> rankEntries(List<FileIndexEntry> entries, String query) {
  final q = query.toLowerCase();
  if (q.isEmpty) return [...entries]..sort(_byEmptyOrder);
  final scored = <(FileIndexEntry, int)>[];
  for (final e in entries) {
    final tier = _matchTier(e, q);
    if (tier < 3) scored.add((e, tier));
  }
  scored.sort((a, b) {
    final byTier = a.$2.compareTo(b.$2);
    return byTier != 0 ? byTier : _byRankOrder(a.$1, b.$1);
  });
  return [for (final s in scored) s.$1];
}

/// Replace the whole @-token at [at] with the picked path (quoted when the
/// path needs it). The token runs from the trigger through everything being
/// typed, so a mid-word caret (`@src/m|ain.ts`) replaces the trailing junk
/// too. Takes the full text, not just the part before the caret. One space is
/// added after the token only when the next character is neither whitespace
/// nor the end of the text; an existing separator is kept as is. Returns the
/// new full text and the caret offset inside it.
({String text, int caret}) insertMention(String text, AtQuery at, String path) {
  int end;
  if (at.quoted) {
    final close = text.indexOf('"', at.start + 2);
    end = close == -1 ? text.length : close + 1;
  } else {
    end = at.start + 1;
    while (end < text.length && !_isWhitespaceChar(text[end])) {
      end++;
    }
  }
  final token = _whitespace.hasMatch(path) ? '@"$path"' : '@$path';
  final gap = end < text.length && !_isWhitespaceChar(text[end]) ? ' ' : '';
  return (
    text: text.substring(0, at.start) + token + gap + text.substring(end),
    caret: at.start + token.length + gap.length,
  );
}

/// Web Composer's sizeLabel: 'folder', bytes, KB, or MB.
String sizeLabel(FileIndexEntry entry) {
  if (entry.isDir || entry.size == null) return 'folder';
  final size = entry.size!;
  String trim0(String s) => s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  if (size < 1024) return '$size B';
  if (size < 1024 * 1024) {
    return '${trim0((size / 1024).toStringAsFixed(size < 10 * 1024 ? 1 : 0))}'
        ' KB';
  }
  return '${trim0((size / (1024 * 1024)).toStringAsFixed(1))} MB';
}
