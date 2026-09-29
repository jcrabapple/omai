// Skill injection chip with the full prompt behind an expander. Ported from
// web/src/components/items/SkillChip.svelte.
import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../transcript/items.dart';

class SkillChip extends StatefulWidget {
  final SkillItem item;

  /// Test seam: start expanded.
  final bool initiallyExpanded;

  const SkillChip({
    super.key,
    required this.item,
    this.initiallyExpanded = false,
  });

  @override
  State<SkillChip> createState() => _SkillChipState();
}

class _SkillChipState extends State<SkillChip> {
  bool _open = false;

  @override
  void initState() {
    super.initState();
    _open = widget.initiallyExpanded;
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
          label: 'Skill: ${widget.item.name}',
          child: InkWell(
            onTap: () => setState(() => _open = !_open),
            borderRadius: BorderRadius.circular(OmpMetrics.radiusSm),
            child: Container(
              constraints: const BoxConstraints(minHeight: OmpMetrics.hit),
              padding: const EdgeInsets.symmetric(horizontal: OmpMetrics.s2),
              decoration: BoxDecoration(
                color: t.surface,
                borderRadius: BorderRadius.circular(OmpMetrics.radiusSm),
                border: Border.all(color: t.line),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.auto_awesome, size: 13, color: t.accent),
                  const SizedBox(width: OmpMetrics.s1),
                  Text(
                    'Skill: ${widget.item.name}',
                    style: TextStyle(color: t.ink, fontSize: OmpMetrics.fsSm),
                  ),
                  const SizedBox(width: OmpMetrics.s1),
                  Icon(
                    _open ? Icons.expand_less : Icons.expand_more,
                    size: 13,
                    color: t.ink3,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_open)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: OmpMetrics.s2),
            constraints: const BoxConstraints(maxHeight: 320),
            padding: const EdgeInsets.all(OmpMetrics.s3),
            decoration: BoxDecoration(
              color: t.inset,
              borderRadius: BorderRadius.circular(OmpMetrics.radiusMd),
            ),
            child: SingleChildScrollView(
              child: Text(
                widget.item.content,
                style: TextStyle(color: t.ink2, fontSize: OmpMetrics.fsSm),
              ),
            ),
          ),
      ],
    );
  }
}
