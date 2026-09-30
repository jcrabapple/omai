// Thinking-level picker: one dropdown used by the New session sheet and the
// session info sheet, so both offer the same levels (docs/API.md
// `POST /sessions/{id}/thinking`: off, minimal, low, medium, high, xhigh,
// max). A dropdown instead of a row of chips keeps the sheets short.

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Every level the gateway accepts, in order of effort.
const thinkingLevels = <String>[
  'off',
  'minimal',
  'low',
  'medium',
  'high',
  'xhigh',
  'max',
];

class ThinkingDropdown extends StatelessWidget {
  const ThinkingDropdown({
    super.key,
    required this.value,
    required this.onChanged,
    this.defaultLabel,
  });

  /// The selected level. With [defaultLabel] set, '' means "use the default"
  /// and is offered as the first entry. A value the list doesn't know (a
  /// newer omp level) is shown as-is rather than dropped.
  final String? value;
  final ValueChanged<String> onChanged;
  final String? defaultLabel;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final levels = [
      if (defaultLabel != null) '',
      ...thinkingLevels,
      if (value != null && value!.isNotEmpty && !thinkingLevels.contains(value))
        value!,
    ];
    final selected = value != null && levels.contains(value) ? value : null;
    return Semantics(
      label: 'Thinking level',
      child: DropdownButtonFormField<String>(
        initialValue: selected,
        isExpanded: true,
        hint: Text(
          'Not reported',
          style: TextStyle(color: tokens.ink3, fontSize: OmpMetrics.fsBase),
        ),
        dropdownColor: tokens.surface,
        borderRadius: BorderRadius.circular(OmpMetrics.radiusMd),
        icon: Icon(Icons.expand_more, size: 16, color: tokens.ink3),
        decoration: const InputDecoration(
          isDense: false,
          contentPadding: EdgeInsets.symmetric(
            horizontal: OmpMetrics.s3,
            vertical: OmpMetrics.s3,
          ),
          constraints: BoxConstraints(minHeight: OmpMetrics.hit),
        ),
        items: [
          for (final level in levels)
            DropdownMenuItem(
              value: level,
              child: Text(
                level.isEmpty ? defaultLabel! : level,
                style: TextStyle(
                  color: level.isEmpty ? tokens.ink3 : tokens.ink,
                  fontSize: OmpMetrics.fsBase,
                ),
              ),
            ),
        ],
        onChanged: (v) {
          if (v != null && v != value) onChanged(v);
        },
      ),
    );
  }
}
