// The transcript list, ported from web/src/components/Transcript.svelte's
// follow/jump logic, reworked for Flutter.
//
// RikkaHub bug #1077 rule: a session opens at the NEWEST activity and can
// never get stuck at the top. The list is `reverse: true`, so offset 0 is
// the bottom edge and index 0 the newest block: opening at offset 0 opens at
// the newest, and content added while the user follows stays pinned there.
// When the user scrolls up, we stop following and show a jump pill. While
// scrolled away the viewport is ANCHORED ON CONTENT: after every frame we
// compare a visible block's on-screen position with the previous frame and
// slide the offset by whatever the content shifted, so growth at the bottom
// (new blocks and a streaming message getting taller) never moves what the
// user is reading. Sending a message always re-follows (web: the lastSentId
// effect).

import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/errors.dart';
import '../../composer/drafts.dart';
import '../../state/connection_notifier.dart';
import '../../state/session_controller.dart';
import '../../state/sessions_store.dart';
import '../../theme/tokens.dart';
import '../../transcript/blocks.dart';
import '../../transcript/fork.dart';
import '../../transcript/items.dart' show UserItem;
import '../../widgets/items/inspector_sheet.dart' show showInspectorSheet;
import '../../widgets/transcript_item.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'session_screen.dart';

const _followPx = 120.0;

/// Fork the session at a settled user message: history strictly before it
/// becomes a new session and the message lands in the new session's composer
/// for a re-send. Ported from web/src/lib/actions.svelte.ts forkFromItem /
/// forkAt.
Future<void> forkFromItem(
  BuildContext context,
  WidgetRef ref,
  SessionState state,
  UserItem item,
) async {
  final gwId = state.gwId;
  // Same guard as the web menu: no fork while a turn runs or the message
  // could not have an entry (pending, failed, empty).
  if (state.running || !forkable(item)) return;

  void snack(String message) =>
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(message)));

  final env = await ref.read(sessionEnvProvider.future);

  // The live user entries, oldest first. A fetch failure means no fork.
  List<SessionEntry> entries;
  try {
    final res = await env.client.entries(gwId);
    final rows = (res['entries'] as List?)?.cast<Object?>() ?? const [];
    entries = [for (final row in rows) ?SessionEntry.fromJson(row)];
  } catch (_) {
    snack('Could not load the session entries');
    return;
  }

  final entry = entryForItem(item, entries);
  if (entry == null) {
    // The live history diverged (compacted, another device): do not fork
    // blind (web: forkStaleToast).
    snack('This session has changed since it loaded');
    return;
  }

  Map<String, Object?> res;
  try {
    res = await env.client.fork(gwId, entry.entryId);
  } on GatewayError catch (e) {
    // 409 while a turn runs or the session compacts; 422 is the gateway's
    // stale-entry verdict, and a 400 mentioning the entry or the branch is
    // omp losing the same race between validation and branch.
    if (e.status == 409) {
      snack('The session is busy');
    } else if (e.status == 422 ||
        (e.status == 400 && RegExp('entr|branch').hasMatch(e.message))) {
      snack('This session has changed since it loaded');
    } else {
      snack('Could not fork the session');
    }
    return;
  } catch (_) {
    snack('Could not fork the session');
    return;
  }
  final newGwId = res['gwId'];
  if (newGwId is! String || newGwId.isEmpty) {
    snack('Could not fork the session');
    return;
  }

  // The caller's text wins (it matches what the user sees); the gateway's
  // text covers a fork whose item carries none.
  final gatewayText = res['text'];
  final seed = item.text.trim().isNotEmpty
      ? item.text
      : (gatewayText is String && gatewayText.isNotEmpty ? gatewayText : null);

  // omp forks at the LIVE history. A failed or diverging prefix check must
  // not strand the user on the now-stopped parent, so always open the child
  // and surface any doubt as a note there.
  String? note;
  final expected = userTextsBefore(state.transcript.items, item);
  if (expected != null) {
    try {
      final msgs = await env.client.messages(newGwId);
      final rows = (msgs['messages'] as List?)?.cast<Object?>() ?? const [];
      if (prefixMissing(expected, userTexts(rows))) {
        note = 'The forked session is missing part of this history';
      }
    } catch (_) {
      note = 'Could not verify the forked session history';
    }
  }

  // Seed the new session's draft before navigating so the composer loads it.
  if (seed != null) {
    final connId = ref.read(connectionNotifierProvider).active?.id ?? '';
    await saveDraft(ref.read(draftKvProvider), connId, newGwId, seed);
  }

  // The parent process was stopped server-side; keeping the row would ghost
  // the rail until the next poll.
  ref.read(sessionsStoreProvider.notifier).remove(gwId);
  unawaited(ref.read(sessionsStoreProvider.notifier).refresh());

  if (!context.mounted) return;
  Navigator.of(context).pushReplacement(
    MaterialPageRoute<void>(builder: (_) => SessionScreen(gwId: newGwId)),
  );
  snack(note ?? 'Forked to new session');
}

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

  /// Block keys seen at the previous update, for counting fresh blocks once.
  Set<String> _blockKeys = const {};

  /// The last user item id seen; a NEW user item means the user just sent a
  /// message, which always brings them back to the bottom.
  String? _lastUserId;

  /// Render-object anchors, one per block, for reading-position anchoring.
  final Map<String, GlobalKey> _anchors = {};

  /// The block currently anchoring the viewport and its last known screen
  /// top, plus the offset it was measured at.
  String? _anchorKey;
  double? _anchorTop;
  double? _anchorOffset;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _syncTracking(initial: true);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(TranscriptList old) {
    super.didUpdateWidget(old);
    _syncTracking();
  }

  /// All per-update bookkeeping lives here, never in build(): count fresh
  /// blocks once each (the jump pill must not run away on streaming frames)
  /// and re-follow when the user sends a message.
  void _syncTracking({bool initial = false}) {
    final items = widget.state.transcript.items;
    final keys = toBlocks(items).map((b) => b.key).toSet();
    _anchors.removeWhere((k, _) => !keys.contains(k));
    if (!initial) {
      final fresh = keys.where((k) => !_blockKeys.contains(k)).length;
      if (!_following && fresh > 0) {
        _newCount += fresh;
      }
      final last = items.isEmpty ? null : items.last;
      // Only the user's OWN just-sent message (a pending local send)
      // re-follows; a user item echoed from elsewhere must not yank a
      // reader who is scrolled up.
      if (last is UserItem && last.pending && last.id != _lastUserId) {
        _lastUserId = last.id;
        // Sending always brings you back to the bottom (web Transcript).
        _following = true;
        _newCount = 0;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) {
            _scroll.jumpTo(0);
          }
        });
      }
    }
    _blockKeys = keys;
  }

  /// Retry a failed local send: re-send the text. The retry lives in the
  /// CONTROLLER (retrySend): the failed bubble is reused, re-entry while the
  /// retry is in flight is ignored, and the button disables via
  /// `retryingSends` in the state.
  void _retrySend(UserItem item) {
    final localId =
        item.localId ??
        (item.id.startsWith('local:') ? item.id.substring(6) : item.id);
    ref
        .read(sessionControllerProvider(widget.state.gwId).notifier)
        .retrySend(localId);
  }

  void _onScroll() {
    final atBottom = !_scroll.hasClients || _scroll.offset <= _followPx;
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

  // ------------------------------------------------------- position anchor

  GlobalKey _anchorFor(String blockKey) =>
      _anchors.putIfAbsent(blockKey, GlobalKey.new);

  /// Top of the anchor block in viewport coordinates (global), or null when
  /// it is not currently laid out / visible.
  double? _anchorBoxTop(String key) {
    final ctx = _anchors[key]?.currentContext;
    if (ctx == null) return null;
    final ro = ctx.findRenderObject();
    if (ro is! RenderBox || !ro.attached || !ro.hasSize) return null;
    final top = ro.localToGlobal(Offset.zero).dy;
    final size = ro.size.height;
    if (top > _screenHeight || top + size < 0) return null;
    return top;
  }

  double get _screenHeight {
    final view = View.of(context);
    return view.physicalSize.height / view.devicePixelRatio;
  }

  /// Reading-position anchor, run after every frame we build: if the anchored
  /// block moved on screen while the scroll offset did not (content grew or
  /// shrank below it), slide the offset by the same amount so what the user
  /// is reading stays put. While following, the reversed list pins offset 0
  /// to the newest block by itself and this is a no-op. A real user scroll
  /// just re-anchors.
  void _compensateShift() {
    if (!_scroll.hasClients || !mounted) return;
    final offset = _scroll.offset;
    final anchor = _anchorKey;
    var top = anchor == null ? null : _anchorBoxTop(anchor);

    // (Re-)pick the topmost visible block as the anchor.
    if (top == null) {
      String? best;
      var bestTop = double.infinity;
      for (final k in _anchors.keys) {
        final t = _anchorBoxTop(k);
        if (t != null && t >= 0 && t < bestTop) {
          bestTop = t;
          best = k;
        }
      }
      _anchorKey = best;
      _anchorTop = best == null ? null : _anchorBoxTop(best);
      _anchorOffset = offset;
      return;
    }

    final userScrolled =
        _anchorOffset != null && (offset - _anchorOffset!).abs() > 0.5;
    if (!_following && !userScrolled && _anchorTop != null) {
      final delta = top - _anchorTop!;
      if (delta.abs() > 0.5) {
        final target = (offset + delta).clamp(
          0.0,
          _scroll.position.maxScrollExtent,
        );
        if ((target - offset).abs() > 0.5) {
          _scroll.jumpTo(target);
          // The jump moves on-screen content up by the correction.
          top = top - (target - offset);
        }
      }
    }
    _anchorTop = top;
    _anchorOffset = offset;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final state = widget.state;
    final items = state.transcript.items;
    final blocks = toBlocks(items);

    // Web Transcript.svelte: while the turn runs and nothing on screen yet
    // shows progress, a small "Working" row stands in at the bottom.
    final working = state.running && !showsProgress(items);

    WidgetsBinding.instance.addPostFrameCallback((_) => _compensateShift());

    final loading = state.phase == SessionPhase.loading && items.isEmpty;
    final showEmpty =
        state.phase == SessionPhase.ready && items.isEmpty && !state.running;

    final children = <Widget>[
      for (final b in blocks.reversed)
        Padding(
          key: _anchorFor(b.key),
          padding: const EdgeInsets.only(bottom: OmpMetrics.s4),
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
                    onInspect: (raw) => showInspectorSheet(context, raw: raw),
                    // Fork at a settled user message: hidden while a turn
                    // runs and for pending/failed/empty bubbles.
                    onFork:
                        b.item is UserItem &&
                            !state.running &&
                            forkable(b.item as UserItem)
                        ? () => forkFromItem(
                            context,
                            ref,
                            state,
                            b.item as UserItem,
                          )
                        : null,
                    onRetrySend:
                        b.item is UserItem &&
                            (b.item as UserItem).failed == true
                        ? _retrySend
                        : null,
                    retryingSend:
                        b.item is UserItem &&
                        state.retryingSends.contains(
                          (b.item as UserItem).localId ??
                              (b.item as UserItem).id,
                        ),
                  ),
                ),
        ),
    ];
    // Reversed list: index 0 paints at the bottom edge, so the working row
    // goes first.
    if (working) {
      children.insert(
        0,
        Padding(
          key: const ValueKey('working'),
          padding: const EdgeInsets.only(bottom: OmpMetrics.s4),
          child: Semantics(
            label: 'Working',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: tokens.accent,
                  ),
                ),
                const SizedBox(width: OmpMetrics.s2),
                Text(
                  'Working',
                  style: TextStyle(
                    color: tokens.ink3,
                    fontSize: OmpMetrics.fsSm,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final list = ListView(
      reverse: true,
      controller: _scroll,
      padding: const EdgeInsets.all(OmpMetrics.s4),
      children: loading
          ? [
              // Padding wraps the sized spinner, not the other way round.
              Padding(
                padding: const EdgeInsets.all(OmpMetrics.s5),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: tokens.accent,
                    ),
                  ),
                ),
              ),
            ]
          : showEmpty
          ? [
              Center(
                child: Text(
                  'No messages yet',
                  style: TextStyle(
                    color: tokens.ink3,
                    fontSize: OmpMetrics.fsBase,
                  ),
                ),
              ),
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
                    child: ConstrainedBox(
                      // Touch target: the pill must be tappable at 48dp.
                      constraints: const BoxConstraints(
                        minHeight: OmpMetrics.hit,
                        minWidth: OmpMetrics.hit,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: OmpMetrics.s4,
                          vertical: OmpMetrics.s2,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.arrow_downward,
                              size: 14,
                              color: tokens.accentInk,
                            ),
                            const SizedBox(width: OmpMetrics.s1),
                            Text(
                              _newCount > 0
                                  ? 'Jump to latest ($_newCount new)'
                                  : 'Jump to latest',
                              style: TextStyle(
                                color: tokens.accentInk,
                                fontSize: OmpMetrics.fsSm,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
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
