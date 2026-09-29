// Card for `!` command output with ANSI colors. Ported from
// web/src/components/items/CommandCard.svelte.
//
// Performance: like ToolOutput, display is capped at 200 lines with a
// show-more button, and the ANSI spans are memoized per text in build
// (recomputed only when text, cap state or tokens change).
import 'package:flutter/material.dart';

import '../../render/ansi.dart';
import '../../theme/tokens.dart';
import '../../transcript/items.dart';

const int _maxLines = 200;

class CommandCard extends StatefulWidget {
  final CommandItem item;

  /// Test seam: start with every line visible.
  final bool showAll;

  const CommandCard({super.key, required this.item, this.showAll = false});

  @override
  State<CommandCard> createState() => _CommandCardState();
}

class _CommandCardState extends State<CommandCard> {
  bool _all = false;

  // Memoized ANSI spans, keyed by the (possibly truncated) text.
  InlineSpan _spans = const TextSpan();
  String _spansFor = '';
  bool _spansAll = false;
  OmpTokens? _spansTokens;

  @override
  void initState() {
    super.initState();
    _all = widget.showAll;
  }

  @override
  void didUpdateWidget(covariant CommandCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.showAll != widget.showAll) _all = widget.showAll;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<OmpTokens>()!;
    final title = (widget.item.command?.trim().isNotEmpty ?? false)
        ? widget.item.command!.trim()
        : 'Command output';
    final base = TextStyle(
      fontFamily: 'monospace',
      fontSize: OmpMetrics.fsSm,
      color: t.ink,
    );

    final lines = widget.item.text.split('\n');
    final cut = !_all && lines.length > _maxLines;
    final shown =
        cut ? lines.sublist(0, _maxLines).join('\n') : widget.item.text;

    // Memoize: recompute only when text, cap state or tokens changed.
    if (shown != _spansFor ||
        _all != _spansAll ||
        !identical(t, _spansTokens)) {
      _spansFor = shown;
      _spansAll = _all;
      _spansTokens = t;
      _spans = TextSpan(
        children: ansiToSpans(shown, palette: ansiPalette(t), base: base),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: t.canvas,
        borderRadius: BorderRadius.circular(OmpMetrics.radiusMd),
        border: Border.all(color: t.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DecoratedBox(
            decoration:
                BoxDecoration(border: Border(bottom: BorderSide(color: t.line))),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: OmpMetrics.s3, vertical: OmpMetrics.s2),
              child: Semantics(
                header: true,
                child: Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    color: t.ink2,
                    fontSize: OmpMetrics.fsSm,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(OmpMetrics.s3),
              child: SelectionArea(
                child: Text.rich(_spans, style: base),
              ),
            ),
          ),
          if (cut)
            Padding(
              padding: const EdgeInsets.only(bottom: OmpMetrics.s2),
              child: TextButton(
                key: const ValueKey('command-show-all'),
                onPressed: () => setState(() => _all = true),
                child: Text('Show all ${lines.length} lines'),
              ),
            ),
        ],
      ),
    );
  }
}
