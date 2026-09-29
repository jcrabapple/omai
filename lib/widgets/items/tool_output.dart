// Tool output body: per-file diffs when the tool changed files, otherwise the
// raw text (ANSI colored, truncated at 200 lines with a show-more button).
// Ported from web/src/components/items/ToolOutput.svelte.
import 'package:flutter/material.dart';

import '../../render/ansi.dart';
import '../../theme/tokens.dart';
import '../../transcript/diff.dart';
import 'diff_block.dart';

const int _maxLines = 200;

class ToolOutput extends StatefulWidget {
  final String text;
  final bool error;

  /// Files this tool changed; diffs render instead of raw output when present
  /// and the tool did not fail.
  final List<FileChange>? files;

  /// Test seam: start with every line visible.
  final bool showAll;

  const ToolOutput({
    super.key,
    required this.text,
    required this.error,
    this.files,
    this.showAll = false,
  });

  @override
  State<ToolOutput> createState() => _ToolOutputState();
}

class _ToolOutputState extends State<ToolOutput> {
  bool _all = false;

  @override
  void initState() {
    super.initState();
    _all = widget.showAll;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<OmpTokens>()!;
    final w = widget;

    if ((w.files?.isNotEmpty ?? false) && !w.error) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final f in w.files!) ...[
            DiffBlock(key: ValueKey<String>('diff:${f.path}'), file: f),
            const SizedBox(height: OmpMetrics.s2),
          ],
        ],
      );
    }

    if (w.text.trim().isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: OmpMetrics.s1),
        child: Text('No output',
            style: TextStyle(color: t.ink3, fontSize: OmpMetrics.fsSm)),
      );
    }

    final lines = w.text.split('\n');
    final cut = !_all && lines.length > _maxLines;
    final shown = cut ? lines.sublist(0, _maxLines).join('\n') : w.text;
    final base = TextStyle(
      fontFamily: 'monospace',
      fontSize: OmpMetrics.fsSm,
      color: w.error ? t.err : t.ink2,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
              horizontal: OmpMetrics.s3, vertical: OmpMetrics.s2),
          decoration: BoxDecoration(
            color: t.inset,
            borderRadius: BorderRadius.circular(OmpMetrics.radiusMd),
            border: w.error ? Border.all(color: t.err.withValues(alpha: 0.3)) : null,
          ),
          constraints: const BoxConstraints(maxHeight: 360),
          child: SingleChildScrollView(
            child: SelectionArea(
              child: Text.rich(
                TextSpan(
                  children:
                      ansiToSpans(shown, palette: ansiPalette(t), base: base),
                ),
                style: base,
              ),
            ),
          ),
        ),
        if (cut)
          Padding(
            padding: const EdgeInsets.only(top: OmpMetrics.s2),
            child: TextButton(
              onPressed: () => setState(() => _all = true),
              child: Text('Show all ${lines.length} lines'),
            ),
          ),
      ],
    );
  }
}
