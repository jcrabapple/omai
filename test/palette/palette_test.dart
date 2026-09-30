// Ported from web/src/lib/palette/__tests__/palette.test.ts, minus the
// desktop-only items (theme toggle, slash commands, session-scoped actions).
// 6 settings pages, not the web's 7: the app has no Agent config page.

import 'package:flutter_test/flutter_test.dart';
import 'package:ohmypi/api/models.dart';
import 'package:ohmypi/palette/palette.dart';

class _Actions implements PaletteActions {
  String? openedSession;
  SavedSession? resumed;
  String? settingsPage;
  bool newSessionCalled = false;
  bool nextAttentionCalled = false;
  @override
  void newSession() => newSessionCalled = true;
  @override
  void nextAttention() => nextAttentionCalled = true;
  @override
  void openSession(String gwId) => openedSession = gwId;
  @override
  void resume(SavedSession s) => resumed = s;
  @override
  void openSettings(String page) => settingsPage = page;
}

SessionInfo session(
  String gwId, {
  bool isStreaming = false,
  List<Map<String, Object?>> pendingUi = const [],
  bool exited = false,
  String cwd = '/work/x',
  String ompSessionName = '',
  String ompSessionFile = '',
}) {
  return SessionInfo.fromJson({
    'gwId': gwId,
    'cwd': cwd,
    if (ompSessionName.isNotEmpty) 'ompSessionName': ompSessionName,
    if (ompSessionFile.isNotEmpty) 'ompSessionFile': ompSessionFile,
    'isStreaming': isStreaming,
    'exited': exited,
    'pendingUi': pendingUi,
    'lastEventSeq': 0,
  });
}

SavedSession saved(String file, String title) => SavedSession.fromJson({
      'file': file,
      'mtime': 1700000100.0,
      'sizeBytes': 10,
      'cwdFolder': 'x',
      'cwd': '/work/x',
      'title': title,
      'running': false,
    });

PaletteContext _ctx({
  List<SessionInfo>? live,
  List<SavedSession>? saved,
  String? activeGwId,
  _Actions? actions,
}) {
  return PaletteContext(
    live: live ?? const [],
    saved: saved ?? const [],
    activeGwId: activeGwId,
    now: 1700000100000,
    actions: actions ?? _Actions(),
  );
}

void main() {
  List<String> ids(List<PaletteItem> list) => list.map((i) => i.id).toList();
  List<String> titles(List<PaletteItem> list) => list.map((i) => i.title).toList();

  group('buildPaletteItems', () {
    test('always offers new session and one item per settings page', () {
      final items = buildPaletteItems(_ctx());
      expect(ids(items), contains('a:new'));
      expect(items.where((i) => i.kind == PaletteKind.setting), hasLength(6));
      expect(
        titles(items.where((i) => i.kind == PaletteKind.setting).toList()),
        contains('Appearance settings'),
      );
    });

    test('offers next-attention only when a session is waiting', () {
      expect(ids(buildPaletteItems(_ctx(live: [session('a')]))),
          isNot(contains('a:next')));
      final waiting = session('b', pendingUi: [
        {'id': 'u', 'method': 'confirm'},
      ]);
      final items = buildPaletteItems(_ctx(live: [session('a'), waiting]));
      expect(
        items.firstWhere((i) => i.id == 'a:next').sub,
        '1 waiting',
      );
    });

    test('running the actions calls the injected callbacks', () {
      final a = _Actions();
      final s = saved('/s/b.jsonl', 'Old one');
      final items = buildPaletteItems(_ctx(
        actions: a,
        live: [session('a')],
        saved: [s],
        activeGwId: 'a',
      ));
      for (final id in ['a:new', 'a:next', 's:a', 'h:/s/b.jsonl', 'p:agent']) {
        final found = items.where((i) => i.id == id);
        if (found.isNotEmpty) found.first.run();
      }
      items.firstWhere((i) => i.id == 'a:new').run();
      items.firstWhere((i) => i.id == 's:a').run();
      items.firstWhere((i) => i.id == 'h:/s/b.jsonl').run();
      items
          .firstWhere((i) => i.kind == PaletteKind.setting)
          .run();
      expect(a.newSessionCalled, isTrue);
      expect(a.openedSession, 'a');
      expect(a.resumed, s);
      expect(a.settingsPage, isNotNull);
    });

    test('marks live sessions with a status and the open one as current', () {
      final items = buildPaletteItems(_ctx(
        live: [
          session('a', isStreaming: true),
          session('b', pendingUi: [
            {'id': 'u', 'method': 'confirm'},
          ]),
          session('c'),
        ],
        activeGwId: 'c',
      ));
      PaletteItem by(String id) => items.firstWhere((i) => i.id == 's:$id');
      expect(by('a').status, 'running');
      expect(by('b').status, 'needs');
      expect(by('c').status, 'idle');
      expect(by('c').current, isTrue);
      expect(by('a').current, isFalse);
    });

    test('skips history that is already a live session or running', () {
      final items = buildPaletteItems(_ctx(
        live: [session('a', ompSessionFile: '/s/a.jsonl')],
        saved: [
          SavedSession.fromJson({
            'file': '/s/a.jsonl',
            'mtime': 1700000100.0,
            'sizeBytes': 10,
            'cwdFolder': 'x',
            'title': 'Live one',
            'running': false,
          }),
          SavedSession.fromJson({
            'file': '/s/c.jsonl',
            'mtime': 1700000100.0,
            'sizeBytes': 10,
            'cwdFolder': 'x',
            'title': 'Running one',
            'running': true,
          }),
          saved('/s/b.jsonl', 'Old one'),
        ],
      ));
      expect(
        ids(items.where((i) => i.kind == PaletteKind.history).toList()),
        ['h:/s/b.jsonl'],
      );
    });

    test('live sessions use the session name and cwd folder as sub', () {
      final items = buildPaletteItems(
        _ctx(live: [session('a', ompSessionName: 'Fix login bug', cwd: '/work/ohmypi')]),
      );
      final s = items.firstWhere((i) => i.id == 's:a');
      expect(s.title, 'Fix login bug');
      expect(s.sub, 'ohmypi');
    });
  });

  group('rankItems', () {
    final live = [
      session('a', ompSessionName: 'Fix login bug'),
      session(
        'b',
        ompSessionName: 'Refactor parser',
        pendingUi: [
          {'id': 'u', 'method': 'confirm'},
        ],
      ),
      session('c', ompSessionName: 'Write docs'),
    ];
    final savedList = List.generate(
      9,
      (i) => saved('/s/$i.jsonl', 'Old chat $i'),
    );
    final base = _ctx(live: live, saved: savedList, activeGwId: 'c');
    final items = buildPaletteItems(base);

    test('with no query shows actions, sessions then five history rows', () {
      final out = rankItems(items, '');
      final kinds = out.map((i) => i.kind).toList();
      expect(kinds.indexOf(PaletteKind.action), 0);
      expect(kinds, isNot(contains(PaletteKind.setting)));
      expect(
        out.where((i) => i.kind == PaletteKind.history).length,
        5,
      );
      final sessions =
          out.where((i) => i.kind == PaletteKind.session).toList();
      expect(titles(sessions), [
        'Refactor parser',
        'Fix login bug',
        'Write docs',
      ]);
      expect(sessions.last.current, isTrue);
      final order = kinds.toSet().toList();
      expect(order, [
        PaletteKind.action,
        PaletteKind.session,
        PaletteKind.history,
      ]);
    });

    test('filters by fuzzy title and puts the best match first', () {
      expect(titles(rankItems(items, 'parser')).first, 'Refactor parser');
      expect(titles(rankItems(items, 'login')).first, 'Fix login bug');
    });

    test('matches history sessions too', () {
      final out = rankItems(items, 'old chat 7');
      expect(out.first.kind, PaletteKind.history);
      expect(out.first.title, 'Old chat 7');
    });

    test('matches keywords, so "open" finds New session', () {
      expect(titles(rankItems(items, 'open')), contains('New session'));
    });

    test('breaks ties by kind, then by original order', () {
      final tie = [
        PaletteItem(
          id: '1',
          kind: PaletteKind.history,
          title: 'alpha',
          icon: 'clock',
          run: () {},
        ),
        PaletteItem(
          id: '2',
          kind: PaletteKind.action,
          title: 'alpha',
          icon: 'plus',
          run: () {},
        ),
        PaletteItem(
          id: '3',
          kind: PaletteKind.action,
          title: 'alpha',
          icon: 'plus',
          run: () {},
        ),
      ];
      expect(ids(rankItems(tie, 'alpha')), ['2', '3', '1']);
    });

    test('the > prefix narrows to actions and settings', () {
      final out = rankItems(items, '>');
      expect(
        out.map((i) => i.kind).toSet(),
        {PaletteKind.action, PaletteKind.setting},
      );
      final themed = rankItems(items, '> appearance');
      expect(themed, isNotEmpty);
      expect(
        themed.every(
          (i) =>
              i.kind == PaletteKind.action || i.kind == PaletteKind.setting,
        ),
        isTrue,
      );
      expect(
        themed.where((i) => i.kind == PaletteKind.session),
        isEmpty,
      );
    });

    test('finds settings pages by name', () {
      final appearance = rankItems(items, 'appearance');
      expect(appearance.first.kind, PaletteKind.setting);
      expect(appearance.first.title, 'Appearance settings');
    });

    test('returns nothing when nothing matches, and honours the limit', () {
      expect(rankItems(items, 'qqqqzzzz'), isEmpty);
      expect(rankItems(items, 'o', limit: 3), hasLength(3));
    });
  });
}
