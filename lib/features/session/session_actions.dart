// Session overflow menu: Rename, Compact, Stop session, Mark done. Ported
// from the web SessionHeader menu bits of active.svelte.ts (rename/compact)
// and the dashboard's stop + mark-done actions.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/reviewed_store.dart';
import '../../state/session_controller.dart';
import '../../state/sessions_store.dart';
import '../../theme/tokens.dart';
import 'changes_page.dart';

/// What [confirmAndStopSession] ended up doing.
enum StopSessionOutcome {
  /// The user confirmed and the gateway session was deleted.
  stopped,

  /// The user backed out of the confirm dialog.
  cancelled,

  /// The delete failed; the caller decides how to say so.
  failed,
}

/// The one stop-session flow: confirm dialog, then DELETE the gateway
/// session. Used by the overflow menu and by the background-work banner.
/// On success the session leaves the rail and the session screen pops.
Future<StopSessionOutcome> confirmAndStopSession(
  BuildContext context,
  WidgetRef ref,
  String gwId,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Stop session'),
      content: const Text(
        'The agent stops. The transcript is saved in History.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Stop'),
        ),
      ],
    ),
  );
  if (confirmed != true) return StopSessionOutcome.cancelled;
  try {
    final env = await ref.read(sessionEnvProvider.future);
    await env.client.deleteSession(gwId);
  } catch (_) {
    return StopSessionOutcome.failed;
  }
  if (!context.mounted) return StopSessionOutcome.stopped;
  ref.read(sessionsStoreProvider.notifier).remove(gwId);
  Navigator.of(context).pop();
  return StopSessionOutcome.stopped;
}

class SessionActions extends ConsumerStatefulWidget {
  const SessionActions({super.key, required this.gwId});

  final String gwId;

  @override
  ConsumerState<SessionActions> createState() => _SessionActionsState();
}

class _SessionActionsState extends ConsumerState<SessionActions> {
  bool _stopping = false;

  void _changes() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ChangesPage(gwId: widget.gwId),
      ),
    );
  }

  Future<void> _rename() async {
    final controller = TextEditingController(
      text: ref.read(sessionControllerProvider(widget.gwId)).info?.title ?? '',
    );
    try {
      final name = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Rename session'),
          content: TextField(
            controller: controller,
            autofocus: true,
            onSubmitted: (v) => Navigator.of(context).pop(v),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('Rename'),
            ),
          ],
        ),
      );
      if (name == null) return;
      final trimmed = name.trim();
      if (trimmed.isEmpty) return;
      try {
        await ref
            .read(sessionControllerProvider(widget.gwId).notifier)
            .rename(trimmed);
      } catch (_) {
        _snack('Could not rename the session');
      }
    } finally {
      controller.dispose();
    }
  }

  Future<void> _compact() async {
    final controller = TextEditingController();
    try {
      final instructions = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Compact context'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'What should it keep? (optional)',
            ),
            onSubmitted: (v) => Navigator.of(context).pop(v),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('Compact'),
            ),
          ],
        ),
      );
      if (instructions == null) return;
      try {
        await ref
            .read(sessionControllerProvider(widget.gwId).notifier)
            .compact(instructions.trim().isEmpty ? null : instructions.trim());
      } catch (_) {
        _snack('Could not compact the session');
      }
    } finally {
      controller.dispose();
    }
  }

  Future<void> _stopSession() async {
    setState(() => _stopping = true);
    final outcome = await confirmAndStopSession(context, ref, widget.gwId);
    if (outcome == StopSessionOutcome.failed) {
      if (mounted) setState(() => _stopping = false);
      _snack('Could not stop the session');
      return;
    }
    if (mounted) setState(() => _stopping = false);
  }

  Future<void> _markDone() async {
    await ref.read(reviewedStoreProvider.notifier).markDone(widget.gwId);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final done = ref.watch(
      reviewedStoreProvider.select((s) => s.done.contains(widget.gwId)),
    );
    return PopupMenuButton<String>(
      tooltip: 'Session actions',
      icon: _stopping
          ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: tokens.ink2,
              ),
            )
          : Icon(Icons.more_vert, color: tokens.ink),
      onSelected: (v) {
        switch (v) {
          case 'changes':
            _changes();
          case 'rename':
            _rename();
          case 'compact':
            _compact();
          case 'stop':
            _stopSession();
          case 'done':
            _markDone();
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(value: 'changes', child: Text('Changes')),
        const PopupMenuItem(value: 'rename', child: Text('Rename')),
        const PopupMenuItem(value: 'compact', child: Text('Compact')),
        if (!done) const PopupMenuItem(value: 'done', child: Text('Mark done')),
        const PopupMenuItem(value: 'stop', child: Text('Stop session')),
      ],
    );
  }
}
