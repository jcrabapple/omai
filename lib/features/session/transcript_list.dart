// The transcript list, ported from web/src/components/Transcript.svelte's
// follow/jump logic, reworked for Flutter.
//
// RikkaHub bug #1077 rule: a session opens at the NEWEST activity and can
// never get stuck at the top. The list is `reverse: true`, so offset 0 is
// the bottom edge and index 0 the newest block: opening at offset 0 opens at
// the newest, and content added while the user follows stays pinned there.
// When the user scrolls up, we stop following and show a jump pill; new
// content never yanks them down.

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../transcript/blocks.dart';
import '../../transcript/items.dart' show UserItem;
import '../../widgets/transcript_item.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/session_controller.dart';

const _followPx = 120.0;

class TranscriptList extends ConsumerStatefulWidget {
  const TranscriptList({super.key, required this.state});

  final SessionState state;

  @override
  ConsumerState<TranscriptList> createState() => _TranscriptListState();
}

class _TranscriptListState extends ConsumerState<TranscriptList> {
  final ScrollController _scroll = ScrollController();
  bool _following = true;

  /// How many blocks arrived while the user was scrolled away, shown on the
  /// jump pill until they come back.
  int _newCount = 0;

  /// Newest block key last seen while following.
  String? _lastFollowedKey;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  /// Retry a failed local send: re-send the text. The failed bubble stays
  /// until a fresh echo or the reducer's settle pass cleans it up.
  void _retrySend(UserItem item) {
    final text = item.text.trim();
    if (text.isEmpty) return;
    ref
        .read(sessionControllerProvider(widget.state.gwId).notifier)
        .send(text);
  }

  void _onScroll() {
    final atBottom =
        !_scroll.hasClients || _scroll.offset <= _followPx;
    if (atBottom != _following && mounted) {
      setState(() {
        _following = atBottom;
        if (atBottom) _newCount = 0;
      });
    }
  }

  void _jumpToLatest() {
    if (!_scroll.hasClients) return;
    setState(() {
      _following = true;
      _newCount = 0;
    });
    _scroll.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final state = widget.state;
    final blocks = toBlocks(state.transcript.items);
    final newest = blocks.isEmpty ? null : blocks.last.key;

    // New content arrived while the user reads older things: count it, never
    // move the viewport. While following, the reversed list keeps offset 0
    // pinned to the newest block by itself.
    if (newest != null && newest != _lastFollowedKey) {
      if (_following) {
        _lastFollowedKey = newest;
      } else {
        _newCount += 1;
      }
    }

    final loading = state.phase == SessionPhase.loading &&
        state.transcript.items.isEmpty;
    final showEmpty = state.phase == SessionPhase.ready &&
        state.transcript.items.isEmpty &&
        !state.running;

    final children = <Widget>[
      for (final b in blocks.reversed)
        Padding(
          key: ValueKey(b.key),
          padding:
              const EdgeInsets.only(bottom: OmpMetrics.s4),
          child: b is ToolsBlock
              ? TranscriptItemView(
                  key: ValueKey('view:${b.key}'),
                  item: b.tools.first,
                  toolRun: b.tools,
                )
              : TranscriptItemView(
                  key: ValueKey('view:${b.key}'),
                  item: (b as ItemBlock).item,
                  callbacks: TranscriptItemCallbacks(
                    onRetrySend: b.item is UserItem &&
                            (b.item as UserItem).failed == true
                        ? _retrySend
                        : null,
                  ),
                ),
        ),
    ];

    final list = ListView(
      reverse: true,
      controller: _scroll,
      padding: const EdgeInsets.all(OmpMetrics.s4),
      children: loading
          ? const [Center(child: SizedBox(width: 20, height: 20, child: Padding(padding: EdgeInsets.all(40), child: CircularProgressIndicator())))]
          : showEmpty
              ? [
                  Center(
                    child: Text('No messages yet',
                        style: TextStyle(
                            color: tokens.ink3,
                            fontSize: OmpMetrics.fsBase)),
                  )
                ]
              : children,
    );

    return Stack(
      children: [
        list,
        if (!_following && !loading && !showEmpty)
          Positioned(
            bottom: OmpMetrics.s4,
            left: 0,
            right: 0,
            child: Center(
              child: AnimatedSlide(
                duration: const Duration(milliseconds: 150),
                offset: Offset.zero,
                child: Material(
                  color: tokens.accent,
                  borderRadius: BorderRadius.circular(999),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: _jumpToLatest,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: OmpMetrics.s4,
                          vertical: OmpMetrics.s2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.arrow_downward,
                              size: 14, color: tokens.accentInk),
                          const SizedBox(width: OmpMetrics.s1),
                          Text(
                            _newCount > 0
                                ? 'Jump to latest ($_newCount new)'
                                : 'Jump to latest',
                            style: TextStyle(
                                color: tokens.accentInk,
                                fontSize: OmpMetrics.fsSm,
                                fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
