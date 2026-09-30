// The search palette's data: which items exist right now and how a query
// ranks them. Ported from web/src/lib/palette/palette.ts, minus the
// desktop-only items (keyboard shortcuts, theme toggle, slash commands and
// the session-scoped actions info/rename/compact/stop/changes). Pure Dart so
// the sheet is a thin list over it and the ranking is tested without
// widgets.

import '../api/models.dart';
import '../format.dart';
import 'fuzzy.dart';

enum PaletteKind { action, session, setting, history }

/// Tie-break order, and the order of the sections when nothing is typed.
const List<PaletteKind> kindOrder = [
  PaletteKind.action,
  PaletteKind.session,
  PaletteKind.setting,
  PaletteKind.history,
];

/// The settings pages the palette offers, as string ids so this module does
/// not depend on the settings code. Title pattern: `<name> settings`.
const List<({String id, String name})> paletteSettingsPages = [
  (id: 'appearance', name: 'Appearance'),
  (id: 'connection', name: 'Connection'),
  (id: 'diagnostics', name: 'Diagnostics'),
  (id: 'models', name: 'Models'),
  (id: 'skills', name: 'Skills'),
  (id: 'usage', name: 'Usage'),
];

/// Icon name from the web palette; the sheet maps it to a Material icon.
typedef PaletteIconName = String;

class PaletteItem {
  const PaletteItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.run,
    this.sub,
    this.keywords = const [],
    this.icon = 'terminal',
    this.status,
    this.current = false,
  });

  final String id;
  final PaletteKind kind;
  final String title;
  final String? sub;
  final List<String> keywords;
  final PaletteIconName icon;

  /// Live sessions only: how it should be marked ('needs' | 'running' | 'idle').
  final String? status;

  /// The session currently on screen.
  final bool current;

  final void Function() run;
}

abstract class PaletteActions {
  void newSession();
  void nextAttention();
  void openSession(String gwId);
  void resume(SavedSession s);
  void openSettings(String page);
}

class PaletteContext {
  const PaletteContext({
    required this.live,
    required this.saved,
    required this.now,
    required this.actions,
    this.activeGwId,
  });

  final List<SessionInfo> live;
  final List<SavedSession> saved;

  /// Client clock, epoch ms, for the history relative times.
  final int now;
  final PaletteActions actions;

  /// The session currently on screen, if any.
  final String? activeGwId;
}

String? _liveStatus(SessionInfo s) {
  if (s.pendingUi.isNotEmpty) return 'needs';
  return s.isStreaming ? 'running' : 'idle';
}

List<PaletteItem> buildPaletteItems(PaletteContext ctx) {
  final a = ctx.actions;
  final live = [for (final s in ctx.live) if (!s.exited) s];
  final needing = [for (final s in live) if (s.pendingUi.isNotEmpty) s];
  final items = <PaletteItem>[];

  items.add(PaletteItem(
    id: 'a:new',
    kind: PaletteKind.action,
    title: 'New session',
    icon: 'plus',
    keywords: const ['start', 'create', 'open'],
    run: a.newSession,
  ));
  if (needing.isNotEmpty) {
    items.add(PaletteItem(
      id: 'a:next',
      kind: PaletteKind.action,
      title: 'Next session that needs you',
      icon: 'alert',
      sub: '${needing.length} waiting',
      keywords: const ['attention', 'approval', 'waiting', 'blocked'],
      run: a.nextAttention,
    ));
  }

  for (final s in live) {
    final model = s.model?.displayName;
    items.add(PaletteItem(
      id: 's:${s.gwId}',
      kind: PaletteKind.session,
      title: s.title,
      sub: [basename(s.cwd), if (model != null && model.isNotEmpty) model]
          .join(' · '),
      keywords: [if (s.cwd.isNotEmpty) s.cwd],
      icon: 'terminal',
      status: _liveStatus(s),
      current: s.gwId == ctx.activeGwId,
      run: () => a.openSession(s.gwId),
    ));
  }

  for (final p in paletteSettingsPages) {
    items.add(PaletteItem(
      id: 'p:${p.id}',
      kind: PaletteKind.setting,
      title: '${p.name} settings',
      sub: 'Settings',
      icon: 'sliders',
      run: () => a.openSettings(p.id),
    ));
  }

  final liveFiles = {
    for (final s in live)
      if (s.ompSessionFile != null) s.ompSessionFile!,
  };
  for (final s in ctx.saved) {
    if (liveFiles.contains(s.file)) continue;
    if (s.running) continue;
    final folder = basename(s.displayCwd);
    items.add(PaletteItem(
      id: 'h:${s.file}',
      kind: PaletteKind.history,
      title: s.title.isEmpty ? folder : s.title,
      sub: '$folder · ${relativeTime((s.mtime * 1000).round(), ctx.now)}',
      icon: 'clock',
      run: () => a.resume(s),
    ));
  }
  return items;
}

/// Per-kind cap for the empty query, where the palette is a short menu rather
/// than a search.
const Map<PaletteKind, int> emptyCaps = {
  PaletteKind.action: 8,
  PaletteKind.session: 8,
  PaletteKind.setting: 0,
  PaletteKind.history: 5,
};

class _Scored {
  const _Scored(this.item, this.score, this.at);
  final PaletteItem item;
  final double score;
  final int at;
}

/// Filter and order items for a query. `>` narrows to actions and settings.
/// With no query the palette shows actions, live sessions and a few recent
/// transcripts, in that order.
List<PaletteItem> rankItems(
  List<PaletteItem> items,
  String rawQuery, {
  int limit = 40,
}) {
  var query = rawQuery.trim();
  List<PaletteKind>? kinds;
  if (query.startsWith('>')) {
    kinds = [PaletteKind.action, PaletteKind.setting];
    query = query.substring(1).trim();
  }
  final pool = kinds == null
      ? items
      : [for (final i in items) if (kinds.contains(i.kind)) i];

  if (query.isEmpty) {
    final shown = <PaletteKind, int>{};
    final out = <PaletteItem>[];
    int cap(PaletteKind k) => kinds != null ? limit : emptyCaps[k] ?? 0;
    final sorted = [...pool];
    for (final kind in kindOrder) {
      final group = sorted.where((i) => i.kind == kind).toList();
      if (kind == PaletteKind.session) {
        // Sessions that need you first, and the one already on screen last.
        group.sort((x, y) {
          final byNeeds = (y.status == 'needs' ? 1 : 0) -
              (x.status == 'needs' ? 1 : 0);
          if (byNeeds != 0) return byNeeds;
          return (x.current ? 1 : 0) - (y.current ? 1 : 0);
        });
      }
      for (final item in group) {
        final n = shown[kind] ?? 0;
        if (n >= cap(kind)) break;
        shown[kind] = n + 1;
        out.add(item);
      }
    }
    return out.take(limit).toList();
  }

  final scored = <_Scored>[];
  for (var at = 0; at < pool.length; at++) {
    final item = pool[at];
    final score = fuzzyScoreAll(
      query,
      item.title,
      [item.sub, ...item.keywords],
    );
    if (score >= 0) scored.add(_Scored(item, score.toDouble(), at));
  }
  scored.sort((x, y) {
    final byScore = y.score.compareTo(x.score);
    if (byScore != 0) return byScore;
    final byKind = kindOrder
        .indexOf(x.item.kind)
        .compareTo(kindOrder.indexOf(y.item.kind));
    if (byKind != 0) return byKind;
    return x.at.compareTo(y.at);
  });
  return scored.take(limit).map((s) => s.item).toList();
}
