// @-file mention menu, ported from web/src/components/Composer.svelte's
// at-menu (popover variant; on a phone there is no desktop/touch split).
// Ranked entries with 48dp rows: a folder row navigates into the folder, a
// file row inserts its path. A quiet note line carries errors or 'No
// matches'; it is never a crash and never a SnackBar.

import 'package:flutter/material.dart';

import '../../composer/at_query.dart';
import '../../theme/tokens.dart';

class AtMenu extends StatelessWidget {
  const AtMenu({
    super.key,
    required this.entries,
    required this.active,
    required this.note,
    required this.onPick,
    required this.onHover,
  });

  /// Already ranked and sliced by the caller (rankEntries(...).take(8)).
  final List<FileIndexEntry> entries;

  /// Flat index of the highlighted row.
  final int active;

  /// Quiet status line: a listing error, or 'No matches'.
  final String? note;

  final void Function(FileIndexEntry entry) onPick;
  final void Function(int index) onHover;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final children = <Widget>[];
    if (note != null) {
      children.add(
        Semantics(
          liveRegion: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: OmpMetrics.s3,
              vertical: OmpMetrics.s2,
            ),
            child: Text(
              note!,
              textAlign: TextAlign.center,
              style: TextStyle(color: tokens.ink3, fontSize: OmpMetrics.fsSm),
            ),
          ),
        ),
      );
    }
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      final idx = i;
      children.add(
        Semantics(
          // One label per row: without excludeSemantics the child text nodes
          // merge in and TalkBack reads the filename twice.
          excludeSemantics: true,
          label: e.isDir
              ? 'Folder ${e.name}'
              : 'File ${e.name}, ${sizeLabel(e)}',
          button: true,
          selected: idx == active,
          child: InkWell(
            onTap: () => onPick(e),
            onHover: (h) {
              if (h) onHover(idx);
            },
            child: Container(
              constraints: const BoxConstraints(minHeight: OmpMetrics.hit),
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(
                horizontal: OmpMetrics.s3,
                vertical: OmpMetrics.s1,
              ),
              color: idx == active ? tokens.press : null,
              child: Row(
                children: [
                  Icon(
                    e.isDir
                        ? Icons.folder_outlined
                        : Icons.insert_drive_file_outlined,
                    size: 18,
                    color: e.isDir ? tokens.accent : tokens.ink3,
                  ),
                  const SizedBox(width: OmpMetrics.s2),
                  Expanded(
                    child: Text(
                      e.isDir ? '${e.name}/' : e.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: e.isDir ? tokens.accent : tokens.ink,
                        fontSize: OmpMetrics.fsBase,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  const SizedBox(width: OmpMetrics.s2),
                  Text(
                    sizeLabel(e),
                    style: TextStyle(
                      color: tokens.ink3,
                      fontSize: OmpMetrics.fsSm,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return Semantics(
      label: 'Files',
      child: Material(
        color: tokens.surface,
        borderRadius: BorderRadius.circular(OmpMetrics.radiusLg),
        elevation: 4,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: children,
            ),
          ),
        ),
      ),
    );
  }
}
