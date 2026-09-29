// Unified diff for one file: op badge, short path, +/- counts, unified rows
// with word-level marks. Ported from web/src/components/items/DiffBlock.svelte
// (unified only; split view is the web desktop wide layout).
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

  @override
  void initState() {
    super.initState();
    _showAll = widget.showAll;
  }

  String get _shortPath {
    final parts = widget.file.path.replaceAll('\\', '/').split('/');
    return parts.length > 3 ? '…/${parts.sublist(parts.length - 3).join('/')}' : widget.file.path;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<OmpTokens>()!;
    final f = widget.file;
    final parsed = parseOmpDiff(f.diff);

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
    for (final h in parsed.hunks) {
      final marks = rowMarks(h.lines);
      for (var i = 0; i < h.lines.length; i++) {
        final row = h.lines[i];
        if (row.t == 'gap') {
          if (count < _limit) rows.add(_gapRow(row.text, t));
        } else {
          if (count < _limit) rows.add(_codeRow(row, marks[i], t));
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
          if (parsed.hunks.isEmpty)
            Padding(
              padding: const EdgeInsets.all(OmpMetrics.s3),
              child: Text('Empty file',
                  style: TextStyle(color: t.ink3, fontSize: OmpMetrics.fsSm)),
            )
          else
            Padding(
              padding: const EdgeInsets.only(bottom: OmpMetrics.s2),
              child: Column(children: rows),
            ),
          if (hidden > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: OmpMetrics.s2),
              child: TextButton(
                onPressed: () => setState(() => _showAll = true),
                child: Text('Show all $count lines'),
              ),
            ),
        ],
      ),
    );
  }

  int get _limit => _showAll ? 1 << 31 : _maxRows;

  Widget _gapRow(String text, OmpTokens t) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: OmpMetrics.s2),
      child: Text(
        text.isEmpty ? '...' : '... $text',
        style: TextStyle(
            fontFamily: 'monospace', color: t.ink3, fontSize: OmpMetrics.fsSm),
      ),
    );
  }

  Widget _codeRow(DiffRow row, Range? mark, OmpTokens t) {
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
