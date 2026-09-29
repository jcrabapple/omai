// Collapsed-by-default thinking row: "Thought for 1.2 s", tap to expand.
// Ported from web/src/components/items/ThinkingRow.svelte.
import 'package:flutter/material.dart';

import '../../format.dart';
import '../../theme/tokens.dart';
import '../../transcript/items.dart';

class ThinkingRow extends StatefulWidget {
  final ThinkingItem item;

  /// Test seam: start expanded.
  final bool initiallyExpanded;

  const ThinkingRow({
    super.key,
    required this.item,
    this.initiallyExpanded = false,
  });

  @override
  State<ThinkingRow> createState() => _ThinkingRowState();
}

class _ThinkingRowState extends State<ThinkingRow> {
  bool _open = false;

  @override
  void initState() {
    super.initState();
    _open = widget.initiallyExpanded;
  }

  String get _label {
    final it = widget.item;
    if (it.streaming) return 'Thinking';
    final s = it.startedAt;
    final e = it.endedAt;
    if (s != null && e != null && e > s) {
      return 'Thought for ${duration((e - s).toDouble())}';
    }
    return 'Thought';
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<OmpTokens>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          button: true,
          expanded: _open,
          label: '$_label, thinking details',
          child: InkWell(
            onTap: () => setState(() => _open = !_open),
            borderRadius: BorderRadius.circular(OmpMetrics.radiusSm),
            child: Container(
              constraints: const BoxConstraints(minHeight: OmpMetrics.hit),
              padding:
                  const EdgeInsets.only(right: OmpMetrics.s2, left: 0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedRotation(
                    turns: _open ? 0.25 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: Icon(Icons.chevron_right,
                        size: 14, color: t.ink3),
                  ),
                  const SizedBox(width: OmpMetrics.s1),
                  Text(
                    _label,
                    style: TextStyle(
                        color: t.ink3, fontSize: OmpMetrics.fsSm),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_open)
          Container(
            margin: const EdgeInsets.only(
                left: 6, bottom: OmpMetrics.s2),
            padding: const EdgeInsets.only(left: OmpMetrics.s4),
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: t.lineStrong)),
            ),
            constraints: const BoxConstraints(maxHeight: 320),
            child: SingleChildScrollView(
              child: Text(
                widget.item.text.trim().isEmpty
                    ? 'No thinking text was kept.'
                    : widget.item.text.trim(),
                style: TextStyle(color: t.ink3, fontSize: OmpMetrics.fsSm),
              ),
            ),
          ),
      ],
    );
  }
}
