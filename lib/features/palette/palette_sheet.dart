// The search palette sheet, ported from web/src/components/CommandPalette.svelte
// (mobile form: a bottom sheet instead of a floating dialog). Tall sheet with
// an autofocused search field and the ranked list below; section headers when
// the query is empty, a flat ranked list when searching. Actions are
// injected via [PaletteActions] so the sheet stays decoupled from routing.
//
// Palette data and ranking: lib/palette/palette.ts port. Live/saved sessions
// come from the sessions store.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../palette/palette.dart';
import '../../state/sessions_store.dart';
import '../../theme/tokens.dart';
import '../../widgets/status_glyph.dart';

const Map<String, IconData> paletteIcons = {
  'plus': Icons.add,
  'alert': Icons.warning_amber_outlined,
  'terminal': Icons.terminal_outlined,
  'sliders': Icons.tune,
  'clock': Icons.schedule,
};

const Map<PaletteKind, String> kindLabels = {
  PaletteKind.action: 'Actions',
  PaletteKind.session: 'Sessions',
  PaletteKind.setting: 'Settings',
  PaletteKind.history: 'History',
};

/// Opens the palette. [actions] runs after the sheet has popped (like the
/// web's queueMicrotask after closing), so a `newSession` action can push a
/// route without it being popped by this sheet.
Future<void> showPaletteSheet(
  BuildContext context, {
  required PaletteActions actions,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    // A scroll-controlled sheet may grow to full height; without this it
    // slides under the status bar (edge-to-edge is on by default).
    useSafeArea: true,
    builder: (sheetContext) => PaletteSheet(actions: actions),
  );
}

class PaletteSheet extends ConsumerStatefulWidget {
  const PaletteSheet({super.key, required this.actions});

  final PaletteActions actions;

  @override
  ConsumerState<PaletteSheet> createState() => _PaletteSheetState();
}

class _PaletteSheetState extends ConsumerState<PaletteSheet> {
  final TextEditingController _query = TextEditingController();
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _run(PaletteItem item) {
    Navigator.of(context).pop();
    // After the pop, like the web's queueMicrotask: an action that pushes a
    // route (New session, a session) must not have it popped by this sheet.
    Future.microtask(item.run);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final sessions = ref.watch(sessionsStoreProvider);
    final ctx = PaletteContext(
      live: sessions.live,
      saved: sessions.saved,
      now: DateTime.now().millisecondsSinceEpoch,
      activeGwId: ref.read(sessionsStoreProvider.notifier).openGwId,
      actions: widget.actions,
    );
    final query = _query.text.trim();
    final items = buildPaletteItems(ctx);
    final ranked = rankItems(items, query);

    return SafeArea(
      // The keyboard would otherwise cover the results: pad by the view
      // inset and cap the sheet at ~85% of the screen so the list has a
      // usable height above the keyboard (triage #10).
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.85,
          ),
          child: Padding(
            padding: const EdgeInsets.all(OmpMetrics.s4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _query,
                  focusNode: _focus,
                  autofocus: true,
                  textInputAction: TextInputAction.go,
                  decoration: InputDecoration(
                    hintText: 'Search sessions and actions',
                    prefixIcon: const Icon(Icons.search),
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(OmpMetrics.radiusMd),
                    ),
                  ),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) {
                    if (ranked.isNotEmpty) _run(ranked.first);
                  },
                ),
                const SizedBox(height: OmpMetrics.s2),
                Flexible(
                  child: ranked.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: OmpMetrics.s5,
                          ),
                          child: Text(
                            'No matches',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: tokens.ink3,
                              fontSize: OmpMetrics.fsBase,
                            ),
                          ),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          // At most a screenful; the sheet never scrolls the page.
                          itemCount: ranked.length,
                          itemBuilder: (context, i) {
                            final item = ranked[i];
                            // Section headers only in the empty-query menu.
                            final header =
                                query.isEmpty &&
                                (i == 0 || ranked[i - 1].kind != item.kind);
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (header)
                                  Padding(
                                    padding: EdgeInsets.only(
                                      top: i == 0 ? 0 : OmpMetrics.s2,
                                      bottom: OmpMetrics.s1,
                                      left: OmpMetrics.s2,
                                    ),
                                    child: Text(
                                      kindLabels[item.kind] ?? '',
                                      style: TextStyle(
                                        color: tokens.ink3,
                                        fontSize: OmpMetrics.fsXs,
                                        fontWeight: FontWeight.w600,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                  ),
                                _PaletteRow(
                                  item: item,
                                  onTap: () => _run(item),
                                ),
                              ],
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One palette row: icon, title, sub, and for live sessions the status glyph.
/// At least 48dp tall.
class _PaletteRow extends StatelessWidget {
  const _PaletteRow({required this.item, required this.onTap});

  final PaletteItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: OmpMetrics.hit),
          padding: const EdgeInsets.symmetric(
            horizontal: OmpMetrics.s2,
            vertical: OmpMetrics.s1,
          ),
          child: Row(
            children: [
              Icon(
                paletteIcons[item.icon] ?? Icons.terminal_outlined,
                size: 20,
                color: tokens.ink2,
              ),
              const SizedBox(width: OmpMetrics.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: tokens.ink,
                        fontSize: OmpMetrics.fsBase,
                      ),
                    ),
                    if (item.sub != null && item.sub!.isNotEmpty)
                      Text(
                        item.sub!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: tokens.ink3,
                          fontSize: OmpMetrics.fsSm,
                        ),
                      ),
                  ],
                ),
              ),
              if (item.status != null) ...[
                const SizedBox(width: OmpMetrics.s2),
                StatusGlyph(status: item.status!),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
