// The attached-files row for a fileMention message: one compact line per
// file under the user bubble (a single summary line when there are more than
// three). Tapping a file opens a bottom sheet with the attached content in a
// monospace scrollable view, rendered lazily so a 5k-line file cannot jank.
// File content never enters a semantics label or a log.
import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../transcript/items.dart';

/// How many characters of a file render before the user asks for the rest.
@visibleForTesting
const int contentPreviewChars = 20000;

/// More files than this collapse into one summary row.
@visibleForTesting
const int maxDetailedFiles = 3;

class FileMentionRow extends StatelessWidget {
  final FileMentionItem item;

  const FileMentionRow({super.key, required this.item});

  String _label(FileMentionFile f) {
    final name = f.name;
    if (f.skippedReason != null) {
      final reason = switch (f.skippedReason) {
        'tooLarge' => 'too large',
        'binary' => 'binary',
        final other => other,
      };
      return 'Skipped $name: $reason';
    }
    if (f.image) return '$name (image)';
    final count = f.lineCount;
    if (count == null) return name;
    return '$name ($count ${count == 1 ? 'line' : 'lines'})';
  }

  Future<void> _openSheet(BuildContext context, FileMentionFile f) async {
    final t = Theme.of(context).extension<OmpTokens>()!;
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) => _ContentSheet(file: f, tokens: t),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<OmpTokens>()!;
    final files = item.files;
    if (files.isEmpty) return const SizedBox.shrink();

    final rows = files.length > maxDetailedFiles
        ? [
            _Row(
              label: 'Attached ${files.length} files',
              onTap: null,
              tokens: t,
            ),
          ]
        : [
            for (final f in files)
              _Row(
                label: _label(f),
                onTap: f.content == null ? null : () => _openSheet(context, f),
                tokens: t,
              ),
          ];

    return Semantics(
      label: 'Attached files',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.only(top: OmpMetrics.s1),
              child: row,
            ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final String label;

  /// Null for skipped files and the summary row: not tappable.
  final VoidCallback? onTap;
  final OmpTokens tokens;

  const _Row({required this.label, required this.onTap, required this.tokens});

  @override
  Widget build(BuildContext context) {
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.attach_file, size: 14, color: tokens.ink3),
        const SizedBox(width: OmpMetrics.s1),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: onTap != null ? tokens.ink2 : tokens.ink3,
              fontSize: OmpMetrics.fsSm,
            ),
          ),
        ),
      ],
    );
    if (onTap == null) return child;
    // 48dp touch target for the tappable file rows.
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(OmpMetrics.radiusSm),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: OmpMetrics.hit),
        child: child,
      ),
    );
  }
}

class _ContentSheet extends StatefulWidget {
  final FileMentionFile file;
  final OmpTokens tokens;

  const _ContentSheet({required this.file, required this.tokens});

  @override
  State<_ContentSheet> createState() => _ContentSheetState();
}

class _ContentSheetState extends State<_ContentSheet> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final f = widget.file;
    final t = widget.tokens;
    final content = f.content ?? '';
    final truncated = !_all && content.length > contentPreviewChars;
    final shown = truncated
        ? content.substring(0, contentPreviewChars)
        : content;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(OmpMetrics.s3),
              child: Row(
                children: [
                  Icon(Icons.attach_file, size: 16, color: t.ink3),
                  const SizedBox(width: OmpMetrics.s2),
                  Expanded(
                    child: Text(
                      f.path,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: t.ink,
                        fontSize: OmpMetrics.fsSm,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: Icon(Icons.close, size: 20, color: t.ink3),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(OmpMetrics.s3),
                child: SelectableText(
                  shown,
                  style: TextStyle(
                    color: t.ink,
                    fontSize: OmpMetrics.fsSm,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
            if (truncated)
              Padding(
                padding: const EdgeInsets.all(OmpMetrics.s2),
                child: Center(
                  child: TextButton(
                    onPressed: () => setState(() => _all = true),
                    child: const Text('Show all'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
