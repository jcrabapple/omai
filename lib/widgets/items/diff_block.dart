// Unified diff for one file: op badge, short path, +/- counts, unified rows
// with word-level marks. Ported from web/src/components/items/DiffBlock.svelte
// (unified only; split view is the web desktop wide layout).
//
// Performance: the diff string and word marks are parsed once in
// initState/didUpdateWidget (only when the diff string changes), never in
// build. The expanded view is capped at steps of [_maxRows] lines with a
// "show more" button instead of thousands of un-virtualized rows. Rows are
// selectable and keyed for stable element matching.
import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../transcript/diff.dart';

const int _maxRows = 400;

class DiffBlock extends StatefulWidget {
  final FileChange file;

  /// Test seam: start with every row visible.
  final bool showAll;

  const DiffBlock({super.key, required this.file, this.showAll = false});

  @override
  State<DiffBlock> createState() => _DiffBlockState();
}

class _DiffBlockState extends State<DiffBlock> {
  bool _showAll = false;

  /// How many [_maxRows] steps are currently expanded.
  int _steps = 1;

  // Cached parse results, recomputed only when the diff string changes.
  ParsedDiff _parsed = const ParsedDiff([], 0, 0);
  List<Map<int, Range>> _marks = const [];
  String? _parsedFor;

  @override
  void initState() {
    super.initState();
    _showAll = widget.showAll;
    _reparse();
  }

  @override
  void didUpdateWidget(covariant DiffBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.showAll != widget.showAll) _showAll = widget.showAll;
    _reparse();
  }

  void _reparse() {
    if (_parsedFor != null && widget.file.diff == _parsedFor) return;
    _parsedFor = widget.file.diff;
    _parsed = parseOmpDiff(widget.file.diff);
    _marks = [
      for (final h in _parsed.hunks) rowMarks(h.lines),
    ];
  }

  String get _shortPath {
    final parts = widget.file.path.replaceAll('\\', '/').split('/');
    return parts.length > 3 ? '…/${parts.sublist(parts.length - 3).join('/')}' : widget.file.path;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<OmpTokens>()!;
    final f = widget.file;

    final String badge;
    if (f.created || f.op == 'create') {
      badge = 'A';
    } else if (f.op == 'write') {
      badge = 'W';
    } else if (f.op == 'delete') {
      badge = 'D';
    } else {
      badge = 'M';
    }
    final Color badgeFg;
    if (f.op == 'delete') {
      badgeFg = t.err;
    } else if (f.created || f.op == 'create') {
      badgeFg = t.ok;
    } else {
      badgeFg = t.warn;
    }

    final rows = <Widget>[];
    var count = 0;
    final limit = _limit;
    for (var hi = 0; hi < _parsed.hunks.length; hi++) {
      final h = _parsed.hunks[hi];
      final marks = _marks[hi];
      for (var i = 0; i < h.lines.length; i++) {
        final row = h.lines[i];
        if (count < limit) {
          final key = ValueKey<int>(count);
          if (row.t == 'gap') {
            rows.add(_gapRow(row.text, t, key));
          } else {
            rows.add(_codeRow(row, marks[i], t, key));
          }
        }
        count += 1;
      }
    }
    final hidden = count - rows.length;

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: t.line),
        borderRadius: BorderRadius.circular(OmpMetrics.radiusMd),
        color: t.inset,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: OmpMetrics.s2, vertical: OmpMetrics.s1),
            child: Row(
              children: [
                Container(
                  width: 20,
                  height: 20,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: badgeFg.withValues(alpha: 0.15),
                    borderRadius:
                        BorderRadius.circular(OmpMetrics.radiusSm),
                  ),
                  child: Text(badge,
                      style: TextStyle(
                          color: badgeFg,
                          fontSize: OmpMetrics.fsXs,
                          fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: OmpMetrics.s2),
                Expanded(
                  child: Text(
                    _shortPath,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontFamily: 'monospace',
                        color: t.ink,
                        fontSize: OmpMetrics.fsSm),
                  ),
                ),
                Semantics(
                  label: '${f.adds} added, ${f.dels} removed',
                  excludeSemantics: true,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text('+${f.adds}',
                        style: TextStyle(color: t.ok, fontSize: OmpMetrics.fsXs)),
                    const SizedBox(width: 4),
                    Text('-${f.dels}',
                        style: TextStyle(color: t.err, fontSize: OmpMetrics.fsXs)),
                  ]),
                ),
              ],
            ),
          ),
          if (_parsed.hunks.isEmpty)
            Padding(
              padding: const EdgeInsets.all(OmpMetrics.s3),
              child: Text('Empty file',
                  style: TextStyle(color: t.ink3, fontSize: OmpMetrics.fsSm)),
            )
          else
            Padding(
              padding: const EdgeInsets.only(bottom: OmpMetrics.s2),
              child: SelectionArea(child: Column(children: rows)),
            ),
          if (hidden > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: OmpMetrics.s2),
              child: TextButton(
                key: const ValueKey('diff-show-more'),
                onPressed: () => setState(() => _steps += 1),
                child: Text(
                    'Show ${hidden > _maxRows ? _maxRows : hidden} more lines'),
              ),
            ),
        ],
      ),
    );
  }

  int get _limit => _showAll ? 1 << 31 : _maxRows * _steps;

  Widget _gapRow(String text, OmpTokens t, Key key) {
    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: OmpMetrics.s2),
      child: Text(
        text.isEmpty ? '...' : '... $text',
        style: TextStyle(
            fontFamily: 'monospace', color: t.ink3, fontSize: OmpMetrics.fsSm),
      ),
    );
  }

  Widget _codeRow(DiffRow row, Range? mark, OmpTokens t, Key key) {
    final Color bg;
    if (row.t == 'add') {
      bg = t.ok.withValues(alpha: 0.08);
    } else if (row.t == 'del') {
      bg = t.err.withValues(alpha: 0.08);
    } else {
      bg = t.inset;
    }
    final TextStyle codeBase = TextStyle(
      fontFamily: 'monospace',
      fontSize: OmpMetrics.fsSm,
      color: t.ink2,
    );
    final spans = <TextSpan>[];
    if (mark != null && mark.start >= 0 && mark.end <= row.text.length) {
      if (mark.start > 0) {
        spans.add(TextSpan(text: row.text.substring(0, mark.start)));
      }
      spans.add(TextSpan(
        text: row.text.substring(mark.start, mark.end),
        style: TextStyle(
          background: Paint()
            ..color = row.t == 'del'
                ? t.errSoft
                : t.ok.withValues(alpha: 0.15),
        ),
      ));
      if (mark.end < row.text.length) {
        spans.add(TextSpan(text: row.text.substring(mark.end)));
      }
    } else {
      spans.add(TextSpan(text: row.text));
    }
    return Container(
      key: key,
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: OmpMetrics.s2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 34,
            child: Text(
              row.o?.toString() ?? '',
              textAlign: TextAlign.right,
              style: TextStyle(
                  fontFamily: 'monospace',
                  color: t.ink3,
                  fontSize: OmpMetrics.fsXs),
            ),
          ),
          const SizedBox(width: 4),
          SizedBox(
            width: 34,
            child: Text(
              row.n?.toString() ?? '',
              textAlign: TextAlign.right,
              style: TextStyle(
                  fontFamily: 'monospace',
                  color: t.ink3,
                  fontSize: OmpMetrics.fsXs),
            ),
          ),
          const SizedBox(width: 4),
          SizedBox(
            width: 10,
            child: Text(
              row.t == 'add' ? '+' : (row.t == 'del' ? '-' : ' '),
              style: TextStyle(
                  fontFamily: 'monospace',
                  color: row.t == 'add'
                      ? t.ok
                      : (row.t == 'del' ? t.err : t.ink3),
                  fontSize: OmpMetrics.fsSm),
            ),
          ),
          Expanded(
            child: Text.rich(
              TextSpan(children: spans, style: codeBase),
              style: codeBase,
            ),
          ),
        ],
      ),
    );
  }
}
