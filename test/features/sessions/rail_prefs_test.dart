// Rail prefs on the sessions screen: pinned section, long-press row actions
// (pin, hide folder with Undo), the folder filter sheet, the hidden-count
// note, and the FAB clearance at the end of the list. Ports the web Rail
// pinned/folder-filter cases. The gateway is a MockClient; no network.

import 'dart:convert';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omai/api/client.dart';
import 'package:omai/app/app.dart';
import 'package:omai/features/search/search_page.dart';
import 'package:omai/features/sessions/sessions_screen.dart';
import 'package:omai/state/connection_notifier.dart';
import 'package:omai/state/connection_store.dart';
import 'package:omai/state/rail_prefs.dart';
import 'package:omai/state/reviewed_store.dart';
import 'package:omai/state/sessions_store.dart';
import 'package:omai/theme/presets.dart';

class _FixedTokenStore implements TokenStore {
  @override
  Future<String?> read(String connectionId) async => 'tok';
  @override
  Future<void> write(String connectionId, String token) async {}
  @override
  Future<void> delete(String connectionId) async {}
}

class _Prefs implements ConnectionPrefs {
  @override
  Future<List<ConnectionRecord>> load() async => const [
    ConnectionRecord(id: 'c1', url: 'https://g', label: 'G'),
  ];
  @override
  Future<void> save(List<ConnectionRecord> connections) async {}
}

class _MemoryKv implements ReviewedKv {
  final Map<String, String> map = {};
  @override
  Future<String?> get(String key) async => map[key];
  @override
  Future<void> set(String key, String value) async => map[key] = value;
}

Map<String, Object?> savedJson(String file, String cwd, {String? title}) => {
  'file': file,
  'mtime': DateTime.now().millisecondsSinceEpoch / 1000,
  'sizeBytes': 1,
  'cwdFolder': cwd.replaceAll('/', '-'),
  'cwd': cwd,
  'title': title ?? 'title $file',
  'running': false,
};

({ProviderContainer container, _MemoryKv kv}) _container(
  List<Map<String, Object?>> saved, {
  Map<String, String> seed = const {},
}) {
  final kv = _MemoryKv()..map.addAll(seed);
  final container = ProviderContainer(
    overrides: [
      reviewedKvProvider.overrideWithValue(kv),
      connectionPrefsProvider.overrideWithValue(_Prefs()),
      tokenStoreProvider.overrideWithValue(_FixedTokenStore()),
      sessionsPollIntervalProvider.overrideWithValue(const Duration(hours: 1)),
      gatewayClientFactoryProvider.overrideWith(
        (ref) =>
            (baseUrl, token) => GatewayClient(
              baseUrl: baseUrl,
              token: token,
              client: MockClient(
                (req) async => http.Response(
                  jsonEncode({'live': [], 'saved': saved}),
                  200,
                  headers: {'content-type': 'application/json'},
                ),
              ),
            ),
      ),
    ],
  );
  container.read(connectionNotifierProvider.notifier).state = ConnectionState(
    connections: const [
      ConnectionRecord(id: 'c1', url: 'https://g', label: 'G'),
    ],
    activeId: 'c1',
  );
  return (container: container, kv: kv);
}

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: OmpTheme.data(OmpPreset.terminal),
        navigatorObservers: [ompRouteObserver],
        home: const SessionsScreen(),
      ),
    ),
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
}

Finder _filterButton() => find.byWidgetPredicate(
  (w) => w is IconButton && (w.tooltip ?? '').startsWith('Filter folders'),
);

Future<void> _longPress(WidgetTester tester, String text) async {
  await tester.longPress(find.text(text));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('long-press Pin moves a row into a Pinned section and persists '
      'it', (tester) async {
    final c = _container([
      savedJson('/s/a.jsonl', '/w/p'),
      savedJson('/s/b.jsonl', '/w/p'),
    ]);
    addTearDown(c.container.dispose);
    await _pump(tester, c.container);
    expect(find.text('PINNED'), findsNothing);

    await _longPress(tester, 'title /s/b.jsonl');
    await tester.tap(find.text('Pin to top of list'));
    await tester.pumpAndSettle();

    expect(find.text('PINNED'), findsOneWidget);
    final pinnedY = tester.getTopLeft(find.text('PINNED')).dy;
    final bY = tester.getTopLeft(find.text('title /s/b.jsonl')).dy;
    final aY = tester.getTopLeft(find.text('title /s/a.jsonl')).dy;
    expect(bY, greaterThan(pinnedY));
    expect(aY, greaterThan(bY), reason: 'pinned row sits above the history');
    expect(jsonDecode(c.kv.map[pinnedSessionsKey('c1')]!), ['/s/b.jsonl']);

    // Pinned rows offer Unpin and no folder hiding.
    await _longPress(tester, 'title /s/b.jsonl');
    expect(find.textContaining('Hide sessions in'), findsNothing);
    await tester.tap(find.text('Unpin from list'));
    await tester.pumpAndSettle();
    expect(find.text('PINNED'), findsNothing);
  });

  testWidgets('long-press Hide folder hides its rows, counts them, and Undo '
      'restores', (tester) async {
    final c = _container([
      savedJson('/s/keep.jsonl', '/w/projects'),
      savedJson('/s/cron1.jsonl', '/home/j'),
      savedJson('/s/cron2.jsonl', '/home/j'),
    ]);
    addTearDown(c.container.dispose);
    await _pump(tester, c.container);

    await _longPress(tester, 'title /s/cron1.jsonl');
    await tester.tap(find.text('Hide sessions in j'));
    await tester.pumpAndSettle();

    expect(find.text('title /s/cron1.jsonl'), findsNothing);
    expect(find.text('title /s/cron2.jsonl'), findsNothing);
    expect(find.text('title /s/keep.jsonl'), findsOneWidget);
    expect(find.text('2 hidden by folder filter'), findsOneWidget);
    expect(jsonDecode(c.kv.map[hiddenFoldersKey('c1')]!), ['/home/j']);
    final button = tester.widget<IconButton>(_filterButton());
    expect(button.tooltip, 'Filter folders, some hidden');

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('title /s/cron1.jsonl'), findsOneWidget);
    expect(find.textContaining('hidden by folder filter'), findsNothing);
  });

  testWidgets('no filter button when every saved session shares one folder', (
    tester,
  ) async {
    final one = _container([
      savedJson('/s/a.jsonl', '/w/p'),
      savedJson('/s/b.jsonl', '/w/p'),
    ]);
    addTearDown(one.container.dispose);
    await _pump(tester, one.container);
    expect(_filterButton(), findsNothing);
  });

  testWidgets('a filter button once saved sessions span two folders', (
    tester,
  ) async {
    final two = _container([
      savedJson('/s/a.jsonl', '/w/p'),
      savedJson('/s/b.jsonl', '/w/q'),
    ]);
    addTearDown(two.container.dispose);
    await _pump(tester, two.container);
    expect(_filterButton(), findsOneWidget);
  });

  testWidgets('the filter sheet toggles several folders without closing, and '
      'Show all clears them', (tester) async {
    final c = _container([
      savedJson('/s/a.jsonl', '/w/p'),
      savedJson('/s/b.jsonl', '/w/q'),
      savedJson('/s/c.jsonl', '/w/r'),
    ]);
    addTearDown(c.container.dispose);
    await _pump(tester, c.container);

    await tester.tap(_filterButton());
    await tester.pumpAndSettle();
    expect(find.text('Show folders'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('folder:/w/p')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('folder:/w/q')));
    await tester.pumpAndSettle();
    expect(find.text('Show folders'), findsOneWidget, reason: 'still open');
    expect(c.container.read(hiddenFoldersProvider), {'/w/p', '/w/q'});
    final q = tester.widget<CheckboxListTile>(
      find.byKey(const ValueKey('folder:/w/q')),
    );
    expect(q.value, isFalse);

    await tester.tap(
      find.descendant(
        of: find.byType(FolderFilterSheet),
        matching: find.widgetWithText(TextButton, 'Show all'),
      ),
    );
    await tester.pumpAndSettle();
    expect(c.container.read(hiddenFoldersProvider), isEmpty);
  });

  testWidgets('a stale hidden key for a folder no longer listed does not '
      'light the button', (tester) async {
    final c = _container(
      [savedJson('/s/a.jsonl', '/w/p'), savedJson('/s/b.jsonl', '/w/q')],
      seed: {
        hiddenFoldersKey('c1'): jsonEncode(['/gone']),
      },
    );
    addTearDown(c.container.dispose);
    await _pump(tester, c.container);
    expect(c.container.read(hiddenFoldersProvider), {'/gone'});
    expect(
      tester.widget<IconButton>(_filterButton()).tooltip,
      'Filter folders',
    );
  });

  testWidgets('everything filtered out is not "No sessions yet"', (
    tester,
  ) async {
    final c = _container(
      [savedJson('/s/a.jsonl', '/home/j')],
      seed: {
        hiddenFoldersKey('c1'): jsonEncode(['/home/j']),
      },
    );
    addTearDown(c.container.dispose);
    await _pump(tester, c.container);
    expect(find.text('No sessions yet.'), findsNothing);
    expect(find.text('1 hidden by folder filter'), findsOneWidget);
    // The button stays reachable to undo with a single folder.
    expect(_filterButton(), findsOneWidget);
  });

  testWidgets('the overflow menu opens transcript search', (tester) async {
    final c = _container([savedJson('/s/a.jsonl', '/w/p')]);
    addTearDown(c.container.dispose);
    await _pump(tester, c.container);
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Search transcripts'));
    await tester.pumpAndSettle();
    expect(find.byType(SearchPage), findsOneWidget);
  });

  testWidgets('the last row scrolls clear of the New session button', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final c = _container([
      for (var i = 0; i < 30; i++) savedJson('/s/$i.jsonl', '/w/p'),
    ]);
    addTearDown(c.container.dispose);
    await _pump(tester, c.container);

    await tester.drag(find.byType(ListView), const Offset(0, -20000));
    await tester.pumpAndSettle();
    // Sorted newest first with equal mtimes: find whichever row is last.
    final rows = find.byType(SessionRow).evaluate().toList();
    final lastBottom = rows
        .map((e) => tester.getRect(find.byWidget(e.widget)).bottom)
        .reduce((a, b) => a > b ? a : b);
    final fabTop = tester.getRect(find.byType(FloatingActionButton)).top;
    expect(lastBottom, lessThanOrEqualTo(fabTop));
  });
}
