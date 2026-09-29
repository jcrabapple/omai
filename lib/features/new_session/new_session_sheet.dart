// The New session sheet, ported from web/src/components/NewSessionSheet.svelte
// (minus the draft-carry checkbox, which belongs to D2a's composer drafts).
// Fields: folder (with recent-cwd chips), model, thinking level, approval
// mode. Create POSTs /api/sessions and hands the new SessionInfo to
// [onCreated]; errors render inline, including the 429 session-cap message.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/errors.dart';
import '../../api/models.dart';
import '../../format.dart';
import '../../state/connection_notifier.dart';
import '../../state/sessions_store.dart';
import '../../theme/tokens.dart';
import '../../widgets/model_picker.dart';

/// Web `DEFAULT_CWD`: where a session starts when the field is left at the
/// placeholder. Kept as a const so tests can pin it.
const defaultCwd = '~/projects';

/// Thinking levels from API.md (`POST /sessions/{id}/thinking`), '' = default.
const thinkingLevels = ['', 'off', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'];

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

/// Recent working directories for the chip row: live sessions first (the
/// store keeps them newest-first), then saved ones, deduped, at most five.
List<String> recentCwds(List<SessionInfo> live, List<SavedSession> saved) {
  final seen = <String>{};
  final out = <String>[];
  for (final cwd in [...live.map((s) => s.cwd), ...saved.map((s) => s.displayCwd)]) {
    if (cwd.isEmpty || !seen.add(cwd)) continue;
    out.add(cwd);
  }
  return out.take(5).toList();
}

/// Opens the sheet. [onCreated] runs after a successful create, before the
/// sheet closes; the caller opens the session screen there.
Future<void> showNewSessionSheet(
  BuildContext context,
  WidgetRef ref, {
  required ValueChanged<SessionInfo> onCreated,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
      child: SingleChildScrollView(
        child: NewSessionSheet(onCreated: onCreated),
      ),
    ),
  );
}

class NewSessionSheet extends ConsumerStatefulWidget {
  const NewSessionSheet({super.key, required this.onCreated});

  final ValueChanged<SessionInfo> onCreated;

  @override
  ConsumerState<NewSessionSheet> createState() => _NewSessionSheetState();
}

class _NewSessionSheetState extends ConsumerState<NewSessionSheet> {
  late final TextEditingController _cwd;
  CatalogModel? _model;
  String _thinking = '';
  String _approval = 'yolo';
  bool _starting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _cwd = TextEditingController(text: ref.read(lastCwdProvider));
  }

  @override
  void dispose() {
    _cwd.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_starting) return;
    final dir = _cwd.text.trim();
    if (dir.isEmpty) {
      setState(() => _error = 'Enter a folder for the session.');
      return;
    }
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
    final client =
        ref.read(gatewayClientFactoryProvider)(active.url, token);
    try {
      final info = await client.startSession(
        cwd: dir,
        model: _model?.selector,
        thinking: _thinking.isEmpty ? null : _thinking,
        approvalMode: _approval,
      );
      if (!mounted) return;
      ref.read(lastCwdProvider.notifier).set(dir);
      // Pop first: onCreated pushes the session screen, and a pop after
      // that would remove the session route instead of this sheet.
      Navigator.of(context).pop();
      widget.onCreated(info);
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
    final sessions = ref.watch(sessionsStoreProvider);
    final suggestions = recentCwds(sessions.live, sessions.saved);
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
            Text('New session',
                style: TextStyle(
                    color: tokens.ink,
                    fontSize: OmpMetrics.fsLg,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: OmpMetrics.s4),
            Text('Folder',
                style:
                    TextStyle(color: tokens.ink2, fontSize: OmpMetrics.fsSm)),
            const SizedBox(height: OmpMetrics.s1),
            TextField(
              controller: _cwd,
              autofillHints: const [],
              enableSuggestions: false,
              decoration: InputDecoration(
                hintText: defaultCwd,
                isDense: true,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(OmpMetrics.radiusMd)),
              ),
            ),
            if (suggestions.isNotEmpty) ...[
              const SizedBox(height: OmpMetrics.s2),
              Wrap(
                spacing: OmpMetrics.s2,
                runSpacing: OmpMetrics.s1,
                children: [
                  for (final dir in suggestions)
                    Semantics(
                      label: 'Use $dir',
                      button: true,
                      child: ActionChip(
                        label: Text(basename(dir)),
                        tooltip: dir,
                        onPressed: () => _cwd.text = dir,
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: OmpMetrics.s4),
            Text('Model',
                style:
                    TextStyle(color: tokens.ink2, fontSize: OmpMetrics.fsSm)),
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
                      child: Text(_model?.name ?? 'Default model',
                          style: TextStyle(
                              color: _model == null ? tokens.ink3 : tokens.ink,
                              fontSize: OmpMetrics.fsBase)),
                    ),
                    Icon(Icons.expand_more,
                        size: 16, color: tokens.ink3),
                  ],
                ),
              ),
            ),
            const SizedBox(height: OmpMetrics.s4),
            Text('Thinking',
                style:
                    TextStyle(color: tokens.ink2, fontSize: OmpMetrics.fsSm)),
            const SizedBox(height: OmpMetrics.s1),
            Wrap(
              spacing: OmpMetrics.s2,
              runSpacing: OmpMetrics.s1,
              children: [
                for (final level in thinkingLevels)
                  _ChoiceChip(
                    tokens: tokens,
                    label: level.isEmpty ? 'Default' : level,
                    on: _thinking == level,
                    onTap: () => setState(() => _thinking = level),
                  ),
              ],
            ),
            const SizedBox(height: OmpMetrics.s4),
            Text('Approval',
                style:
                    TextStyle(color: tokens.ink2, fontSize: OmpMetrics.fsSm)),
            const SizedBox(height: OmpMetrics.s1),
            for (final mode in approvalModes)
              Semantics(
                button: true,
                selected: _approval == mode.id,
                label: '${mode.label}. ${mode.hint}',
                child: InkWell(
                  onTap: () => setState(() => _approval = mode.id),
                  borderRadius:
                      BorderRadius.circular(OmpMetrics.radiusMd),
                  child: Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(minHeight: 48),
                    margin: const EdgeInsets.symmetric(
                        vertical: OmpMetrics.s1),
                    padding: const EdgeInsets.symmetric(
                        horizontal: OmpMetrics.s3, vertical: OmpMetrics.s2),
                    decoration: BoxDecoration(
                      color: _approval == mode.id
                          ? tokens.accentSoft
                          : tokens.inset,
                      borderRadius:
                          BorderRadius.circular(OmpMetrics.radiusMd),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(mode.label,
                            style: TextStyle(
                                color: tokens.ink,
                                fontSize: OmpMetrics.fsBase,
                                fontWeight: FontWeight.w600)),
                        Text(mode.hint,
                            style: TextStyle(
                                color: tokens.ink3,
                                fontSize: OmpMetrics.fsSm)),
                      ],
                    ),
                  ),
                ),
              ),
            if (_error != null) ...[
              const SizedBox(height: OmpMetrics.s2),
              Semantics(
                liveRegion: true,
                child: Text(_error!,
                    style:
                        TextStyle(color: tokens.err, fontSize: OmpMetrics.fsSm)),
              ),
            ],
            const SizedBox(height: OmpMetrics.s4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _starting ? null : () => Navigator.of(context).pop(),
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
                                strokeWidth: 2, color: tokens.accentInk)),
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

class _ChoiceChip extends StatelessWidget {
  const _ChoiceChip({
    required this.tokens,
    required this.label,
    required this.on,
    required this.onTap,
  });

  final OmpTokens tokens;
  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: on,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          constraints: const BoxConstraints(minHeight: 36),
          padding:
              const EdgeInsets.symmetric(horizontal: OmpMetrics.s3),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? tokens.accentSoft : tokens.inset,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(label,
              style: TextStyle(
                  color: on ? tokens.ink : tokens.ink2,
                  fontSize: OmpMetrics.fsSm)),
        ),
      ),
    );
  }
}
