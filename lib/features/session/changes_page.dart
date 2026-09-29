// Per-session Changes page: every file the session touched, latest diff per
// path, with +/− counts; tapping a file opens its combined diff. Ported from
// web/src/components/ChangesView.svelte (unified only, matching the
// transcript's DiffBlock; the split view is the web desktop wide layout).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/session_controller.dart';
import '../../theme/tokens.dart';
import '../../transcript/changes.dart';
import '../../widgets/items/diff_block.dart';

class ChangesPage extends ConsumerWidget {
  const ChangesPage({super.key, required this.gwId});

  final String gwId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final state = ref.watch(sessionControllerProvider(gwId));
    final rollup = collectChanges(state.transcript.items);

    return Scaffold(
      backgroundColor: tokens.canvas,
      appBar: AppBar(
        backgroundColor: tokens.canvas,
        foregroundColor: tokens.ink,
        elevation: 0,
        title: Text(
          'Changes',
          style: TextStyle(
            color: tokens.ink,
            fontSize: OmpMetrics.fsLg,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: rollup.groups.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(OmpMetrics.s4),
              child: Text(
                'No file changes in this session yet.',
                style: TextStyle(color: tokens.ink3, fontSize: OmpMetrics.fsSm),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(OmpMetrics.s3),
              children: [
                Semantics(
                  label: 'Changes summary',
                  child: Text(
                    '${rollup.files} ${rollup.files == 1 ? 'file' : 'files'}'
                    ' · ${rollup.edits} ${rollup.edits == 1 ? 'edit' : 'edits'}',
                    style: TextStyle(
                      color: tokens.ink3,
                      fontSize: OmpMetrics.fsSm,
                    ),
                  ),
                ),
                const SizedBox(height: OmpMetrics.s2),
                for (final g in rollup.groups)
                  ChangeGroupTile(
                    key: ValueKey('change-${g.path}'),
                    group: g,
                    onOpen: () => _openDiff(context, g),
                  ),
              ],
            ),
    );
  }

  void _openDiff(BuildContext context, ChangeGroup g) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (context) => _FileDiffPage(group: g)),
    );
  }
}

/// One file row: op badge, path, +/- counts. 48dp target.
class ChangeGroupTile extends StatelessWidget {
  const ChangeGroupTile({super.key, required this.group, required this.onOpen});

  final ChangeGroup group;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final f = group.file;

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
    final Color badgeFg = f.op == 'delete'
        ? tokens.err
        : (f.created || f.op == 'create' ? tokens.ok : tokens.warn);

    return Semantics(
      label: '${group.path}, ${f.adds} added, ${f.dels} removed',
      button: true,
      child: InkWell(
        onTap: onOpen,
        child: Container(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: tokens.line)),
          ),
          constraints: const BoxConstraints(minHeight: OmpMetrics.hit),
          padding: const EdgeInsets.symmetric(
            horizontal: OmpMetrics.s2,
            vertical: OmpMetrics.s2,
          ),
          child: Row(
            children: [
              Container(
                width: 20,
                height: 20,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: badgeFg.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(OmpMetrics.radiusSm),
                ),
                child: Text(
                  badge,
                  style: TextStyle(
                    color: badgeFg,
                    fontSize: OmpMetrics.fsXs,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: OmpMetrics.s2),
              Expanded(
                child: Text(
                  group.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    color: tokens.ink,
                    fontSize: OmpMetrics.fsSm,
                  ),
                ),
              ),
              const SizedBox(width: OmpMetrics.s2),
              Text(
                '+${f.adds}',
                style: TextStyle(color: tokens.ok, fontSize: OmpMetrics.fsXs),
              ),
              const SizedBox(width: 4),
              Text(
                '-${f.dels}',
                style: TextStyle(color: tokens.err, fontSize: OmpMetrics.fsXs),
              ),
              Icon(Icons.chevron_right, size: 16, color: tokens.ink3),
            ],
          ),
        ),
      ),
    );
  }
}

class _FileDiffPage extends StatelessWidget {
  const _FileDiffPage({required this.group});

  final ChangeGroup group;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    return Scaffold(
      backgroundColor: tokens.canvas,
      appBar: AppBar(
        backgroundColor: tokens.canvas,
        foregroundColor: tokens.ink,
        elevation: 0,
        title: Text(
          group.path,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: 'monospace',
            color: tokens.ink,
            fontSize: OmpMetrics.fsSm,
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(OmpMetrics.s3),
        child: DiffBlock(file: group.file, showAll: true),
      ),
    );
  }
}
