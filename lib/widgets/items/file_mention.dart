// The attached-files row for a fileMention message: one compact line per
// file under the user bubble (a single summary line when there are more than
// three). Tapping a file opens a bottom sheet with the attached content in a
// monospace scrollable view, rendered lazily so a 5k-line file cannot jank.
// File content never enters a semantics label or a log.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/tokens.dart';
import '../../transcript/items.dart';

/// How many characters of a file render before the user asks for the rest.
@visibleForTesting
const int contentPreviewChars = 20000;

/// Hard cap for 'Show all': beyond this the sheet shows the head and says so,
/// because laying out megabytes of text in one frame locks the UI thread.
@visibleForTesting
const int contentShowAllChars = 200000;

/// Size of the lazily built text chunks in the full view.
@visibleForTesting
const int contentChunkChars = 2000;

/// Split [text] into chunks of about [chunkChars], breaking on newlines when
/// one is nearby so a chunk boundary rarely cuts a line in half.
List<String> chunkContent(String text, int chunkChars) {
  if (text.isEmpty) return const [''];
  final chunks = <String>[];
  var start = 0;
  while (start < text.length) {
    if (text.length - start <= chunkChars) {
      chunks.add(text.substring(start));
      break;
    }
    var end = start + chunkChars;
    // Prefer a newline within the last quarter of the window.
    final nl = text.lastIndexOf('\n', end);
    if (nl > start + chunkChars - chunkChars ~/ 4) end = nl + 1;
    chunks.add(text.substring(start, end));
    start = end;
  }
  return chunks;
}

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
      // container: true keeps 'Attached files' as a group boundary while the
      // file rows inside stay their own focusable nodes with their own tap
      // action (device review L7b): without it the whole column collapses
      // into one merged stop when skipped or image files are present.
      container: true,
      explicitChildNodes: true,
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
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final f = widget.file;
    final t = widget.tokens;
    final content = f.content ?? '';
    final previewTruncated = !_all && content.length > contentPreviewChars;
    // 'Show all' is itself capped: a multi-megabyte file shows its head with
    // a note, and 'Copy all' carries the full content to the clipboard.
    final shownLength = _all
        ? content.length.clamp(0, contentShowAllChars)
        : content.length.clamp(0, contentPreviewChars);
    final shown = content.substring(0, shownLength);
    final capped = _all && content.length > contentShowAllChars;
    // Lazily built chunks: a virtualized list so even the capped view never
    // lays out more than the visible few chunks per frame (device review L4).
    final chunks = chunkContent(shown, contentChunkChars);

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
              child: ListView.builder(
                padding: const EdgeInsets.all(OmpMetrics.s3),
                itemCount: chunks.length,
                itemBuilder: (context, i) => Text(
                  chunks[i],
                  style: TextStyle(
                    color: t.ink,
                    fontSize: OmpMetrics.fsSm,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
            if (previewTruncated)
              Padding(
                padding: const EdgeInsets.all(OmpMetrics.s2),
                child: Center(
                  child: TextButton(
                    onPressed: () => setState(() => _all = true),
                    child: const Text('Show all'),
                  ),
                ),
              )
            else ...[
              if (capped)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: OmpMetrics.s3),
                  child: Text('Showing the first 200k characters.'),
                ),
              Padding(
                padding: const EdgeInsets.all(OmpMetrics.s2),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TextButton.icon(
                      onPressed: content.isEmpty
                          ? null
                          : () {
                              Clipboard.setData(ClipboardData(text: content));
                              setState(() => _copied = true);
                            },
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('Copy all'),
                    ),
                    if (_copied) ...[
                      const SizedBox(width: OmpMetrics.s2),
                      Text(
                        'Copied',
                        style: TextStyle(
                          color: t.ink3,
                          fontSize: OmpMetrics.fsSm,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
