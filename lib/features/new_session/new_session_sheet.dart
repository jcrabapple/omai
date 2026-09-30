// The New session sheet, ported from web/src/components/NewSessionSheet.svelte
// (minus the draft-carry checkbox, which belongs to D2a's composer drafts).
// Fields: folder (with recent-cwd chips), model, thinking level, approval
// mode. Create POSTs /api/sessions and hands the new SessionInfo to
// [onCreated]; errors render inline, including the 429 session-cap message.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/errors.dart';
import '../../api/models.dart';
import '../../format.dart';
import '../../state/connection_notifier.dart';
import '../../state/hidden_cwds.dart';
import '../../state/session_controller.dart';
import '../../state/sessions_store.dart';
import '../../theme/tokens.dart';
import '../../widgets/model_picker.dart';
import '../../widgets/thinking_dropdown.dart';

import 'dart:async';

/// Web `DEFAULT_CWD`: where a session starts when the field is left at the
/// placeholder. Kept as a const so tests can pin it.
const defaultCwd = '~/projects';

/// Approval modes and their hints, ported from web/src/lib/composer/modes.ts.
const approvalModes = [
  (id: 'yolo', label: 'Yolo', hint: 'runs tools without asking'),
  (id: 'write', label: 'Write', hint: 'asks before edits and commands'),
  (id: 'always-ask', label: 'Always ask', hint: 'asks before every tool'),
];

/// Last folder the user started a session in, per app run. In-memory on
/// purpose: the web app persists it in device storage, the app starts fresh.
class LastCwd extends Notifier<String> {
  @override
  String build() => defaultCwd;
  void set(String v) => state = v;
}

final lastCwdProvider = NotifierProvider<LastCwd, String>(LastCwd.new);

/// Folders the gateway reports as deleted (saved entries with
/// `cwdExists: false`).
Set<String> missingCwds(List<SavedSession> saved) => {
  for (final s in saved)
    if (s.cwd != null && s.cwdExists == false) s.cwd!,
};

/// Recent working directories for the chip row: live sessions first (the
/// store keeps them newest-first), then saved ones, deduped, at most five.
/// Only real folders that still exist: a saved entry the gateway marks
/// `cwdExists: false` is skipped (and so is any live session in that folder),
/// and so is one with no recorded cwd, whose `cwdFolder` is omp's mangled
/// directory name rather than a path. A missing `cwdExists` (older gateway)
/// counts as unknown and stays.
/// [hidden] are folders the user removed with a long-press (device-local,
/// see state/hidden_cwds.dart); skipping them lets older folders fill in.
List<String> recentCwds(
  List<SessionInfo> live,
  List<SavedSession> saved, {
  Set<String> hidden = const {},
}) {
  final missing = missingCwds(saved);
  final seen = <String>{...missing, ...hidden};
  final out = <String>[];
  for (final cwd in [
    ...live.map((s) => s.cwd),
    for (final s in saved)
      if (s.cwd != null) s.cwd!,
  ]) {
    if (cwd.isEmpty || !seen.add(cwd)) continue;
    out.add(cwd);
  }
  return out.take(5).toList();
}

/// Opens the sheet. [onCreated] runs after a successful create, before the
/// sheet closes; the caller opens the session screen there. [initialPrompt]
/// (Task F share intents) is sent as the first prompt right after create.
Future<void> showNewSessionSheet(
  BuildContext context,
  WidgetRef ref, {
  required ValueChanged<SessionInfo> onCreated,
  String? initialPrompt,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    // A scroll-controlled sheet may grow to full height; without this it
    // slides under the status bar (edge-to-edge is on by default).
    useSafeArea: true,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: NewSessionSheet(
          onCreated: onCreated,
          initialPrompt: initialPrompt,
        ),
      ),
    ),
  );
}

class NewSessionSheet extends ConsumerStatefulWidget {
  const NewSessionSheet({
    super.key,
    required this.onCreated,
    this.initialPrompt,
  });

  final ValueChanged<SessionInfo> onCreated;

  /// First prompt to send once the session exists (share intent); null keeps
  /// the plain create flow.
  final String? initialPrompt;

  @override
  ConsumerState<NewSessionSheet> createState() => _NewSessionSheetState();
}

class _NewSessionSheetState extends ConsumerState<NewSessionSheet> {
  late final TextEditingController _cwd;

  /// What the folder field was prefilled with; replaced only while the user
  /// hasn't edited it.
  late String _prefilled;
  CatalogModel? _model;
  String _thinking = '';
  String _approval = 'yolo';
  bool _starting = false;
  String? _error;

  /// The folder just removed from the chips, offered back via Undo until the
  /// next removal or until the sheet closes. Inline, not a SnackBar: a
  /// SnackBar would appear on the scaffold behind this sheet.
  String? _removed;

  Future<void> _removeRecent(String dir) async {
    HapticFeedback.mediumImpact();
    setState(() => _removed = dir);
    await ref.read(hiddenCwdsProvider.notifier).hide(dir);
  }

  Future<void> _undoRemove() async {
    final dir = _removed;
    if (dir == null) return;
    setState(() => _removed = null);
    await ref.read(hiddenCwdsProvider.notifier).unhide(dir);
  }

  @override
  void initState() {
    super.initState();
    // The remembered folder may have been deleted since; start from the
    // default instead of prefilling a path the create would fail on. The
    // sessions list may still be loading, so this is re-checked in build.
    _prefilled = ref.read(lastCwdProvider);
    _cwd = TextEditingController(text: _prefilled);
    _dropMissingPrefill(ref.read(sessionsStoreProvider).saved);
  }

  void _dropMissingPrefill(List<SavedSession> saved) {
    if (_cwd.text != _prefilled || _prefilled == defaultCwd) return;
    if (!missingCwds(saved).contains(_prefilled)) return;
    _prefilled = defaultCwd;
    _cwd.text = defaultCwd;
  }

  @override
  void dispose() {
    _cwd.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_starting) return;
    // Web NewSessionSheet: an empty field means the default cwd, not an error.
    final dir = _cwd.text.trim().isEmpty ? defaultCwd : _cwd.text.trim();
    setState(() {
      _starting = true;
      _error = null;
    });
    final connection = ref.read(connectionNotifierProvider);
    final active = connection.active;
    if (active == null) {
      setState(() {
        _starting = false;
        _error = 'Not signed in.';
      });
      return;
    }
    final token = await ref.read(tokenStoreProvider).read(active.id);
    if (!mounted || token == null || token.isEmpty) {
      setState(() {
        _starting = false;
        _error = 'Not signed in.';
      });
      return;
    }
    final client = ref.read(gatewayClientFactoryProvider)(active.url, token);
    try {
      final info = await client.startSession(
        cwd: dir,
        model: _model?.selector,
        thinking: _thinking.isEmpty ? null : _thinking,
        approvalMode: _approval,
      );
      if (!mounted) return;
      ref.read(lastCwdProvider.notifier).set(dir);
      // Used again, so it's recent again.
      unawaited(ref.read(hiddenCwdsProvider.notifier).unhide(dir));
      // Pop first: onCreated pushes the session screen, and a pop after
      // that would remove the session route instead of this sheet.
      Navigator.of(context).pop();
      widget.onCreated(info);
      // Share intent: the shared text becomes the session's first prompt.
      final prompt = widget.initialPrompt?.trim() ?? '';
      if (prompt.isNotEmpty) {
        unawaited(
          ref.read(sessionControllerProvider(info.gwId).notifier).send(prompt),
        );
      }
    } on GatewayClientError catch (e) {
      if (!mounted) return;
      // Includes the bare-429 session cap: the gateway's own message shows.
      setState(() {
        _starting = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _error = 'Could not start the session';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    ref.listen(
      sessionsStoreProvider,
      (_, next) => _dropMissingPrefill(next.saved),
    );
    final sessions = ref.watch(sessionsStoreProvider);
    final suggestions = recentCwds(
      sessions.live,
      sessions.saved,
      hidden: ref.watch(hiddenCwdsProvider),
    );
    final current = _model == null
        ? null
        : CurrentModel(provider: _model!.provider, id: _model!.id);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(OmpMetrics.s4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'New session',
              style: TextStyle(
                color: tokens.ink,
                fontSize: OmpMetrics.fsLg,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: OmpMetrics.s4),
            Text(
              'Folder',
              style: TextStyle(color: tokens.ink2, fontSize: OmpMetrics.fsSm),
            ),
            const SizedBox(height: OmpMetrics.s1),
            TextField(
              controller: _cwd,
              autofillHints: const [],
              enableSuggestions: false,
              decoration: InputDecoration(
                hintText: defaultCwd,
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(OmpMetrics.radiusMd),
                ),
              ),
            ),
            if (suggestions.isNotEmpty) ...[
              const SizedBox(height: OmpMetrics.s2),
              Wrap(
                spacing: OmpMetrics.s2,
                runSpacing: OmpMetrics.s1,
                children: [
                  for (final dir in suggestions)
                    // Tap fills the field; long-press removes the folder
                    // from the recent list. No tooltip: on a phone a tooltip
                    // is itself a long-press and would fight the removal.
                    Semantics(
                      key: ValueKey('recent-cwd:$dir'),
                      label: 'Use $dir',
                      button: true,
                      hint: 'Long press to remove from recent folders',
                      onLongPress: () => _removeRecent(dir),
                      child: GestureDetector(
                        onLongPress: () => _removeRecent(dir),
                        child: ActionChip(
                          label: Text(basename(dir)),
                          onPressed: () => _cwd.text = dir,
                        ),
                      ),
                    ),
                ],
              ),
            ],
            if (_removed != null)
              Semantics(
                liveRegion: true,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Removed ${basename(_removed!)} from recent folders',
                        style: TextStyle(
                          color: tokens.ink3,
                          fontSize: OmpMetrics.fsSm,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _undoRemove,
                      style: TextButton.styleFrom(
                        minimumSize: const Size(OmpMetrics.hit, OmpMetrics.hit),
                      ),
                      child: const Text('Undo'),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: OmpMetrics.s4),
            Text(
              'Model',
              style: TextStyle(color: tokens.ink2, fontSize: OmpMetrics.fsSm),
            ),
            const SizedBox(height: OmpMetrics.s1),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => showModelPickerSheet(
                  context,
                  ref,
                  current: current,
                  defaultLabel: 'Default model',
                  onPick: (m) => setState(() => _model = m),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _model?.name ?? 'Default model',
                        style: TextStyle(
                          color: _model == null ? tokens.ink3 : tokens.ink,
                          fontSize: OmpMetrics.fsBase,
                        ),
                      ),
                    ),
                    Icon(Icons.expand_more, size: 16, color: tokens.ink3),
                  ],
                ),
              ),
            ),
            const SizedBox(height: OmpMetrics.s4),
            Text(
              'Thinking',
              style: TextStyle(color: tokens.ink2, fontSize: OmpMetrics.fsSm),
            ),
            const SizedBox(height: OmpMetrics.s1),
            ThinkingDropdown(
              value: _thinking,
              defaultLabel: 'Default',
              onChanged: (level) => setState(() => _thinking = level),
            ),
            const SizedBox(height: OmpMetrics.s4),
            Text(
              'Approval',
              style: TextStyle(color: tokens.ink2, fontSize: OmpMetrics.fsSm),
            ),
            const SizedBox(height: OmpMetrics.s1),
            for (final mode in approvalModes)
              _ApprovalOption(
                tokens: tokens,
                label: mode.label,
                hint: mode.hint,
                selected: _approval == mode.id,
                onTap: () => setState(() => _approval = mode.id),
              ),
            if (_error != null) ...[
              const SizedBox(height: OmpMetrics.s2),
              Semantics(
                liveRegion: true,
                child: Text(
                  _error!,
                  style: TextStyle(
                    color: tokens.err,
                    fontSize: OmpMetrics.fsSm,
                  ),
                ),
              ),
            ],
            const SizedBox(height: OmpMetrics.s4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _starting
                      ? null
                      : () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: OmpMetrics.s2),
                FilledButton(
                  onPressed: _starting ? null : _start,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_starting) ...[
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: tokens.accentInk,
                          ),
                        ),
                        const SizedBox(width: OmpMetrics.s2),
                      ],
                      const Text('Start'),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One approval-mode row. The selected row has to read at a glance on a dark
/// sheet, so it's marked three ways: a filled radio icon (shape, not only
/// color), a 2px accent border, and an accent label.
class _ApprovalOption extends StatelessWidget {
  const _ApprovalOption({
    required this.tokens,
    required this.label,
    required this.hint,
    required this.selected,
    required this.onTap,
  });

  final OmpTokens tokens;
  final String label;
  final String hint;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(OmpMetrics.radiusMd);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: OmpMetrics.s1),
      child: Semantics(
        button: true,
        inMutuallyExclusiveGroup: true,
        checked: selected,
        selected: selected,
        label: '$label. $hint',
        excludeSemantics: true,
        child: Material(
          color: selected ? tokens.accentSoft : tokens.inset,
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: selected
                ? BorderSide(color: tokens.accent, width: 2)
                : BorderSide(color: tokens.line),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Container(
              width: double.infinity,
              constraints: const BoxConstraints(minHeight: OmpMetrics.hit),
              padding: const EdgeInsets.symmetric(
                horizontal: OmpMetrics.s3,
                vertical: OmpMetrics.s2,
              ),
              child: Row(
                children: [
                  Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 20,
                    color: selected ? tokens.accent : tokens.ink3,
                  ),
                  const SizedBox(width: OmpMetrics.s3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            color: selected ? tokens.accent : tokens.ink,
                            fontSize: OmpMetrics.fsBase,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          hint,
                          style: TextStyle(
                            color: selected ? tokens.ink2 : tokens.ink3,
                            fontSize: OmpMetrics.fsSm,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
