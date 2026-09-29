// Structured parsing of omp's line-numbered diff format, plus the extraction
// of per-file changes from edit/write tool results. Ported from
// web/src/lib/render/diff2.ts (parseOmpDiff, extractFiles, rowMarks, extLang).
import '../wire/wire.dart' show listOf;
import 'wordmarks.dart';

export 'wordmarks.dart' show Range;

typedef DiffRowType = String; // 'ctx' | 'add' | 'del' | 'gap'

class DiffRow {
  final DiffRowType t;

  /// Old line number (ctx, del).
  final int? o;

  /// New line number (add, ctx).
  final int? n;
  final String text;

  const DiffRow({required this.t, this.o, this.n, required this.text});

  @override
  bool operator ==(Object other) =>
      other is DiffRow && other.t == t && other.o == o && other.n == n && other.text == text;

  @override
  int get hashCode => Object.hash(t, o, n, text);

  @override
  String toString() => 'DiffRow($t, o:$o, n:$n, $text)';
}

class DiffHunk {
  final List<DiffRow> lines;
  const DiffHunk(this.lines);

  @override
  bool operator ==(Object other) => other is DiffHunk && _listEq(other.lines, lines);

  @override
  int get hashCode => Object.hashAll(lines);

  @override
  String toString() => 'DiffHunk(${lines.toString()})';
}

bool _listEq(List a, List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class ParsedDiff {
  final List<DiffHunk> hunks;
  final int adds;
  final int dels;
  const ParsedDiff(this.hunks, this.adds, this.dels);

  @override
  bool operator ==(Object other) =>
      other is ParsedDiff && _listEq(other.hunks, hunks) && other.adds == adds && other.dels == dels;

  @override
  int get hashCode => Object.hash(hunks, adds, dels);

  @override
  String toString() => 'ParsedDiff($hunks, +$adds -$dels)';
}

class FileChange {
  final String path;

  /// omp's op: update, create, write, delete, ...
  final String op;

  /// The omp-format diff text (synthesized for writes that have no result diff).
  final String diff;
  final int adds;
  final int dels;
  final bool created;

  const FileChange({
    required this.path,
    required this.op,
    required this.diff,
    required this.adds,
    required this.dels,
    required this.created,
  });

  @override
  bool operator ==(Object other) =>
      other is FileChange &&
      other.path == path &&
      other.op == op &&
      other.diff == diff &&
      other.adds == adds &&
      other.dels == dels &&
      other.created == created;

  @override
  int get hashCode => Object.hash(path, op, diff, adds, dels, created);

  @override
  String toString() => 'FileChange($path, $op, +$adds -$dels, created:$created)';
}

/// Cap for the synthesized all-additions diff of a `write` tool call.
const int writeDiffCap = 60 * 1024;

final RegExp _virtual = RegExp(r'^[a-z][\w+.-]+://', caseSensitive: false);
final RegExp _row = RegExp(r'^([ +-])(\d+)\|(.*)$');
final RegExp _gap = RegExp(r'^\.{3}\s*(.*)$');

ParsedDiff parseOmpDiff(String diff) {
  final hunks = <DiffHunk>[];
  var cur = <DiffRow>[];
  var adds = 0;
  var dels = 0;
  // New-line offset carried across the whole diff: adds shift later context
  // rows down, deletes shift them up. Skipped context (gaps) moves both sides
  // equally and leaves the delta alone.
  var delta = 0;
  void flush() {
    if (cur.isNotEmpty) hunks.add(DiffHunk(List.unmodifiable(cur)));
    cur = <DiffRow>[];
  }

  for (final raw in diff.split('\n')) {
    final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
    if (line == '') {
      flush();
      continue;
    }
    final m = _row.firstMatch(line);
    if (m != null) {
      final text = m.group(3) ?? '';
      final n = num.parse(m.group(2)!);
      if (m.group(1) == '+') {
        adds += 1;
        delta += 1;
        cur.add(DiffRow(t: 'add', n: n.toInt(), text: text));
      } else if (m.group(1) == '-') {
        dels += 1;
        delta -= 1;
        cur.add(DiffRow(t: 'del', o: n.toInt(), text: text));
      } else {
        cur.add(DiffRow(t: 'ctx', o: n.toInt(), n: n.toInt() + delta, text: text));
      }
      continue;
    }
    final g = _gap.firstMatch(line);
    cur.add(DiffRow(t: 'gap', text: g != null ? (g.group(1) ?? '') : line));
  }
  flush();
  return ParsedDiff(List.unmodifiable(hunks), adds, dels);
}

FileChange _toFile(String path, String op, String diff) {
  final p = parseOmpDiff(diff);
  final rows = [for (final h in p.hunks) ...h.lines];
  int? firstAdd;
  for (final l in rows) {
    if (l.t == 'add') {
      firstAdd = l.n;
      break;
    }
  }
  // A new file has nothing but additions starting at line 1; an insert at the
  // top of an existing file still shows context rows around it.
  final created = op == 'create' ||
      (p.dels == 0 && p.adds > 0 && firstAdd == 1 && !rows.any((l) => l.t == 'ctx'));
  return FileChange(
      path: path, op: op, diff: diff, adds: p.adds, dels: p.dels, created: created);
}

/// omp-format all-additions diff from write tool call arguments, capped at
/// [writeDiffCap].
String _synthesizeAdditions(String content) {
  if (content == '') return '';
  final lines = content.split('\n');
  if (lines.length > 1 && lines.last == '') lines.removeLast();
  final parts = <String>[];
  var len = 0;
  for (var i = 0; i < lines.length; i++) {
    final raw = lines[i];
    final text = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
    final row = '+${i + 1}|$text';
    final cost = row.length + (parts.isNotEmpty ? 1 : 0);
    if (len + cost > writeDiffCap) {
      parts.add('... truncated at 60 KB, ${lines.length - parts.length} more lines');
      return parts.join('\n');
    }
    parts.add(row);
    len += cost;
  }
  return parts.join('\n');
}

/// Per-file changes carried by one tool result. `args` are the tool call
/// arguments (without omp's `i` intent key); `details` is the result's
/// details object. History toolResult messages and live tool_execution_end
/// events feed this the same shapes, so both produce the same files for the
/// same turn.
List<FileChange> extractFiles(String toolName, Map<String, Object?>? args, Object? details) {
  final d = details is Map<String, Object?>
      ? details
      : (details is Map ? details.cast<String, Object?>() : null);
  // Keyed by path so a repeated entry for the same file keeps only the latest diff.
  final byPath = <String, FileChange>{};
  if (d != null) {
    final per = listOf(d['perFileResults']) ?? const [];
    for (final item in per) {
      final o = item is Map<String, Object?> ? item : (item is Map ? item.cast<String, Object?>() : null);
      if (o == null) continue;
      final path = o['path'];
      final diff = o['diff'];
      if (path is! String || diff is! String) continue;
      if (_virtual.hasMatch(path)) continue;
      byPath[path] = _toFile(path, o['op'] is String ? o['op'] as String : 'update', diff);
    }
    if (byPath.isNotEmpty) return byPath.values.toList(growable: false);
    final diff = d['diff'];
    if (diff is String && diff.isNotEmpty) {
      final dPath = d['path'];
      final argsPath = args?['path'];
      final path = dPath is String && dPath.isNotEmpty ? dPath : (argsPath is String ? argsPath : '');
      if (path.isNotEmpty && !_virtual.hasMatch(path)) {
        byPath[path] = _toFile(path, d['op'] is String ? d['op'] as String : 'update', diff);
      }
      return byPath.values.toList(growable: false);
    }
  }
  if (toolName == 'write' && args != null) {
    final resolved = d?['resolvedPath'];
    final argsPath = args['path'];
    final path = resolved is String && resolved.isNotEmpty
        ? resolved
        : (argsPath is String ? argsPath : '');
    final content = args['content'];
    if (path.isNotEmpty && content is String && !_virtual.hasMatch(path)) {
      // A write replaces the whole file: mark it created so it renders unified
      // with an A badge.
      final f = _toFile(path, 'write', _synthesizeAdditions(content));
      return [FileChange(path: f.path, op: f.op, diff: f.diff, adds: f.adds, dels: f.dels, created: true)];
    }
  }
  return const [];
}

/// Pair each -/+ run and compute word-level marks per row index. Rows outside
/// pairs (context, gap notes, fully rewritten lines) have no entry.
Map<int, Range> rowMarks(List<DiffRow> lines) {
  final marks = <int, Range>{};
  var i = 0;
  while (i < lines.length) {
    if (lines[i].t != 'del') {
      i += 1;
      continue;
    }
    var d1 = i;
    while (d1 + 1 < lines.length && lines[d1 + 1].t == 'del') {
      d1 += 1;
    }
    final a0 = d1 + 1;
    if (a0 < lines.length && lines[a0].t == 'add') {
      var a1 = a0;
      while (a1 + 1 < lines.length && lines[a1 + 1].t == 'add') {
        a1 += 1;
      }
      final pairs = (d1 - i + 1) < (a1 - a0 + 1) ? (d1 - i + 1) : (a1 - a0 + 1);
      for (var k = 0; k < pairs; k++) {
        final wm = wordMarks(lines[i + k].text, lines[a0 + k].text);
        if (wm != null) {
          marks[i + k] = wm.$1;
          marks[a0 + k] = wm.$2;
        }
      }
      i = a1 + 1;
    } else {
      i = d1 + 1;
    }
  }
  return marks;
}

const Map<String, String> _extLang = {
  'ts': 'typescript', 'mts': 'typescript', 'cts': 'typescript', 'tsx': 'typescript',
  'js': 'javascript', 'mjs': 'javascript', 'cjs': 'javascript', 'jsx': 'javascript',
  'py': 'python', 'pyi': 'python',
  'sh': 'bash', 'bash': 'bash', 'zsh': 'bash',
  'json': 'json', 'jsonc': 'json',
  'yml': 'yaml', 'yaml': 'yaml',
  'css': 'css',
  'html': 'xml', 'htm': 'xml', 'svg': 'xml', 'xml': 'xml',
  'go': 'go', 'rs': 'rust', 'sql': 'sql',
  'md': 'markdown', 'markdown': 'markdown',
  'ini': 'ini', 'cfg': 'ini', 'toml': 'ini', 'conf': 'ini',
  'diff': 'diff', 'patch': 'diff',
  'dockerfile': 'dockerfile',
};

/// Map a file path to a registered highlight.js language, or null for plain text.
String? extLang(String path) {
  final parts = path.split('/');
  final base = parts.isEmpty ? '' : parts.last;
  if (base.isEmpty) return null;
  final byName = _extLang[base.toLowerCase()];
  if (byName != null) return byName;
  final dot = base.lastIndexOf('.');
  if (dot <= 0) return null;
  return _extLang[base.substring(dot + 1).toLowerCase()];
}
