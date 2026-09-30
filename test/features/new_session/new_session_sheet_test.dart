// New session sheet widget tests: empty-cwd validation, recent-cwd chips,
// create posts the API.md body and opens the new session, and a 429 session
// cap shows the gateway's own message inline. The gateway is a MockClient;
// the session screen runs on the shared fakes; no network.

import 'dart:convert';

import 'dart:ui' show CheckedState;

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ohmypi/api/client.dart';
import 'package:ohmypi/api/models.dart';
import 'package:ohmypi/app/app.dart';
import 'package:ohmypi/composer/drafts.dart';
import 'package:ohmypi/features/new_session/new_session_sheet.dart';
import 'package:ohmypi/features/session/session_screen.dart';
import 'package:ohmypi/state/connection_notifier.dart';
import 'package:ohmypi/state/connection_store.dart';
import 'package:ohmypi/state/hidden_cwds.dart';
import 'package:ohmypi/state/reviewed_store.dart';
import 'package:ohmypi/state/session_controller.dart';
import 'package:ohmypi/state/sessions_store.dart';
import 'package:ohmypi/stream/scheduler.dart';
import 'package:ohmypi/theme/presets.dart';

import '../../stream/fakes.dart';

http.Response _json(Object? body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

class _FixedTokenStore implements TokenStore {
  @override
  Future<String?> read(String connectionId) async => 'tok';
  @override
  Future<void> write(String connectionId, String token) async {}
  @override
  Future<void> delete(String connectionId) async {}
}

class MemoryPrefs implements ConnectionPrefs {
  MemoryPrefs(this.records);
  final List<ConnectionRecord> records;
  @override
  Future<List<ConnectionRecord>> load() async => records;
  @override
  Future<void> save(List<ConnectionRecord> connections) async {}
}

class FakeGateway {
  FakeGateway({
    this.createStatus = 200,
    this.createBody,
    this.saved = const [],
  });
  int createStatus;
  Map<String, Object?>? createBody;

  /// Saved entries served by GET /api/sessions.
  final List<Map<String, Object?>> saved;
  final List<Object?> bodies = [];

  http.Client client() => MockClient((req) async {
    if (req.method == 'POST' && req.url.path == '/api/sessions') {
      bodies.add(jsonDecode(req.body));
      if (createStatus != 200) {
        return _json(createBody ?? {'error': 'nope'}, status: createStatus);
      }
      return _json(
        createBody ??
            {'gwId': 'gw-new', 'cwd': '/work/prompter', 'approvalMode': 'yolo'},
      );
    }
    if (req.url.path == '/api/sessions') {
      return _json({
        'live': [
          {'gwId': 'live-1', 'cwd': '/work/prompter'},
        ],
        'saved': saved,
      });
    }
    if (req.url.path.endsWith('/messages')) {
      return _json({'messages': []});
    }
    return _json({'live': const [], 'saved': const []});
  });
}

class _MemoryDraftKv implements DraftKv {
  final Map<String, String> _map = {};
  @override
  Future<String?> get(String key) async => _map[key];
  @override
  Future<void> set(String key, String value) async => _map[key] = value;
  @override
  Future<void> remove(String key) async => _map.remove(key);
}

class _MemoryKv implements ReviewedKv {
  final Map<String, String> _map = {};
  @override
  Future<String?> get(String key) async => _map[key];
  @override
  Future<void> set(String key, String value) async => _map[key] = value;
}

ProviderContainer _container(FakeGateway gateway, {_MemoryKv? kv}) {
  final env = SessionEnv(
    client: GatewayClient(
      baseUrl: 'https://g',
      token: 'tok',
      client: gateway.client(),
    ),
    baseUrl: 'https://g',
    token: 'tok',
    socketFactory: (url, headers) async {
      final sock = FakeSocket(url, headers);
      return sock;
    },
    scheduler: const SystemScheduler(),
  );
  final container = ProviderContainer(
    overrides: [
      reviewedKvProvider.overrideWithValue(kv ?? _MemoryKv()),
      draftKvProvider.overrideWithValue(_MemoryDraftKv()),
      connectionPrefsProvider.overrideWithValue(
        MemoryPrefs(const [
          ConnectionRecord(id: 'c1', url: 'https://g', label: 'G'),
        ]),
      ),
      tokenStoreProvider.overrideWithValue(_FixedTokenStore()),
      sessionsPollIntervalProvider.overrideWithValue(const Duration(hours: 1)),
      gatewayClientFactoryProvider.overrideWith(
        (ref) =>
            (baseUrl, token) => GatewayClient(
              baseUrl: baseUrl,
              token: token,
              client: gateway.client(),
            ),
      ),
      sessionEnvProvider.overrideWith((ref) async => env),
    ],
  );
  container.read(connectionNotifierProvider.notifier).state = ConnectionState(
    connections: const [
      ConnectionRecord(id: 'c1', url: 'https://g', label: 'G'),
    ],
    activeId: 'c1',
  );
  return container;
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container, {
  ValueChanged<Object>? onCreated,
}) async {
  // A tall surface: the sheet is scrollable and Start must be on-screen.
  tester.view.physicalSize = const Size(800, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: OmpTheme.data(OmpPreset.terminal),
        navigatorObservers: [ompRouteObserver],
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: const SizedBox.shrink(),
            floatingActionButton: FloatingActionButton(
              onPressed: () => showNewSessionSheet(
                context,
                ref,
                onCreated: (info) {
                  if (onCreated != null) {
                    onCreated(info);
                    return;
                  }
                  // Mirror the sessions screen: open the new session.
                  ref
                      .read(sessionsStoreProvider.notifier)
                      .setOpenSession(info.gwId);
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => SessionScreen(gwId: info.gwId),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    ),
  );
  // Let the sessions store settle so the recent-cwd chips are there.
  await tester.pump();
  await tester.pump();
  await tester.pump();
  await tester.tap(find.byType(FloatingActionButton));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an empty cwd defaults to the web default (~/projects) and '
      'posts it', (tester) async {
    final gateway = FakeGateway();
    final container = _container(gateway);
    addTearDown(container.dispose);
    await _pump(tester, container);

    await tester.enterText(find.byType(TextField).first, '   ');
    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.pump();

    // Web NewSessionSheet: `const dir = cwd.trim() || DEFAULT_CWD`.
    expect((gateway.bodies.single as Map)['cwd'], '~/projects');
  });

  testWidgets('a recent cwd chip fills the folder field', (tester) async {
    final gateway = FakeGateway();
    final container = _container(gateway);
    addTearDown(container.dispose);
    await _pump(tester, container);

    await tester.tap(find.text('prompter'));
    await tester.pump();
    expect(find.widgetWithText(TextField, '/work/prompter'), findsOneWidget);
  });

  testWidgets('create posts the API.md body and opens the new session', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final container = _container(gateway);
    addTearDown(container.dispose);
    await _pump(tester, container);

    await tester.enterText(find.byType(TextField).first, '/work/newproj');
    // Pick a non-default approval mode to prove the body carries it.
    await tester.tap(find.text('Always ask'));
    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 350));

    expect(gateway.bodies.single, {
      'cwd': '/work/newproj',
      'approvalMode': 'always-ask',
    });
    expect(find.byType(SessionScreen), findsOneWidget);
    // The session screen opened with the new gateway id.
    expect(
      tester.widget<SessionScreen>(find.byType(SessionScreen)).gwId,
      'gw-new',
    );
  });

  testWidgets('a 429 session cap shows the gateway message inline', (
    tester,
  ) async {
    final gateway = FakeGateway(
      createStatus: 429,
      createBody: {'error': 'session limit reached (8); stop one first'},
    );
    final container = _container(gateway);
    addTearDown(container.dispose);
    await _pump(tester, container);

    await tester.enterText(find.byType(TextField).first, '/work/newproj');
    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.pump();

    expect(
      find.text('session limit reached (8); stop one first'),
      findsOneWidget,
    );
    expect(find.byType(SessionScreen), findsNothing);
    // The sheet stays open, so the user can go stop one and retry.
    expect(find.text('New session'), findsOneWidget);
  });

  testWidgets(
    'thinking is a dropdown; the picked level goes in the create body',
    (tester) async {
      final gateway = FakeGateway();
      final container = _container(gateway);
      addTearDown(container.dispose);
      await _pump(tester, container);

      // One field, not a row of chips.
      expect(find.text('medium'), findsNothing);
      final field = find.byType(DropdownButtonFormField<String>);
      expect(field, findsOneWidget);
      expect(
        tester.getSize(field).height,
        greaterThanOrEqualTo(48.0),
        reason: 'the dropdown must meet the 48dp hit target',
      );

      await tester.ensureVisible(field);
      await tester.tap(field);
      await tester.pumpAndSettle();
      for (final level in ['off', 'minimal', 'low', 'high', 'xhigh', 'max']) {
        expect(find.text(level).last, findsOneWidget);
      }
      await tester.tap(find.text('xhigh').last);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '/work/newproj');
      await tester.tap(find.text('Start'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 350));

      expect((gateway.bodies.single as Map)['thinking'], 'xhigh');
    },
  );

  testWidgets('leaving thinking on Default omits it from the create body', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final container = _container(gateway);
    addTearDown(container.dispose);
    await _pump(tester, container);

    expect(find.text('Default'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '/work/newproj');
    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 350));

    expect((gateway.bodies.single as Map).containsKey('thinking'), isFalse);
  });

  testWidgets(
    'the selected approval mode is marked by icon, border and color',
    (tester) async {
      final gateway = FakeGateway();
      final container = _container(gateway);
      addTearDown(container.dispose);
      await _pump(tester, container);

      Finder row(String label) => find
          .ancestor(of: find.text(label), matching: find.byType(Material))
          .first;
      Finder radioIn(String label, IconData icon) =>
          find.descendant(of: row(label), matching: find.byIcon(icon));

      // Yolo is the default: filled radio, accent border; the others empty.
      expect(radioIn('Yolo', Icons.radio_button_checked), findsOneWidget);
      expect(
        radioIn('Always ask', Icons.radio_button_unchecked),
        findsOneWidget,
      );
      final theme = Theme.of(tester.element(find.text('Yolo')));
      final accent = theme.colorScheme.primary;
      RoundedRectangleBorder shape(String label) =>
          tester.widget<Material>(row(label)).shape! as RoundedRectangleBorder;
      expect(shape('Yolo').side.color, accent);
      expect(shape('Yolo').side.width, 2);
      expect(shape('Always ask').side.width, lessThan(2));

      await tester.ensureVisible(find.text('Always ask'));
      await tester.tap(find.text('Always ask'));
      await tester.pump();
      expect(radioIn('Always ask', Icons.radio_button_checked), findsOneWidget);
      expect(radioIn('Yolo', Icons.radio_button_unchecked), findsOneWidget);
      expect(shape('Always ask').side.color, accent);

      // TalkBack hears it as a checked option in a group.
      final node = tester.getSemantics(
        find
            .ancestor(of: row('Always ask'), matching: find.byType(Semantics))
            .first,
      );
      expect(node.flagsCollection.isChecked, CheckedState.isTrue);
    },
  );

  Map<String, Object?> savedEntry(
    String? cwd, {
    bool? exists,
    String folder = 'x',
  }) => {
    'file': '/sessions/$folder.jsonl',
    'mtime': 1,
    'sizeBytes': 1,
    'cwdFolder': '--mangled-$folder--',
    'cwd': cwd,
    'cwdExists': ?exists,
    'title': 't',
    'running': false,
  };

  testWidgets('recent folder chips skip folders that no longer exist', (
    tester,
  ) async {
    final gateway = FakeGateway(
      saved: [
        savedEntry('/work/gone-e2e', exists: false, folder: 'a'),
        savedEntry('/work/kept', exists: true, folder: 'b'),
        // Older gateway: no cwdExists key -> unknown -> kept.
        savedEntry('/work/unknown', folder: 'c'),
        // No recorded cwd: cwdFolder is omp's mangled name, not a path.
        savedEntry(null, folder: 'd'),
      ],
    );
    final container = _container(gateway);
    addTearDown(container.dispose);
    await _pump(tester, container);

    expect(find.text('prompter'), findsOneWidget); // live session
    expect(find.text('kept'), findsOneWidget);
    expect(find.text('unknown'), findsOneWidget);
    expect(find.text('gone-e2e'), findsNothing);
    expect(find.textContaining('mangled'), findsNothing);
  });

  test('recentCwds drops a live session in a deleted folder too', () {
    final live = [
      SessionInfo.fromJson({'gwId': 'l1', 'cwd': '/work/gone'}),
      SessionInfo.fromJson({'gwId': 'l2', 'cwd': '/work/here'}),
    ];
    final saved = [
      SavedSession.fromJson(savedEntry('/work/gone', exists: false)),
    ];
    expect(recentCwds(live, saved), ['/work/here']);
  });

  testWidgets(
    'a remembered folder that was deleted falls back to the default',
    (tester) async {
      final gateway = FakeGateway(
        saved: [savedEntry('/work/gone-e2e', exists: false)],
      );
      final container = _container(gateway);
      addTearDown(container.dispose);
      container.read(lastCwdProvider.notifier).set('/work/gone-e2e');
      await _pump(tester, container);

      // Check the field's actual text: its hint is also the default folder.
      final field = tester.widget<TextField>(find.byType(TextField).first);
      expect(field.controller!.text, defaultCwd);
    },
  );

  test('recentCwds keeps an unknown folder and skips an uncaptured cwd', () {
    final saved = [
      SavedSession.fromJson(savedEntry('/work/unknown')),
      SavedSession.fromJson(savedEntry(null, folder: 'z')),
    ];
    expect(recentCwds(const [], saved), ['/work/unknown']);
  });

  testWidgets('a folder the user typed is never replaced', (tester) async {
    final gateway = FakeGateway(
      saved: [savedEntry('/work/gone-e2e', exists: false)],
    );
    final container = _container(gateway);
    addTearDown(container.dispose);
    await _pump(tester, container);

    await tester.enterText(find.byType(TextField).first, '/work/gone-e2e');
    await container.read(sessionsStoreProvider.notifier).refresh();
    await tester.pump();
    final field = tester.widget<TextField>(find.byType(TextField).first);
    expect(field.controller!.text, '/work/gone-e2e');
  });

  group('long-press removes a recent folder', () {
    FakeGateway gw() => FakeGateway(
      saved: [
        savedEntry('/work/alpha', exists: true, folder: 'a'),
        savedEntry('/work/beta', exists: true, folder: 'b'),
      ],
    );

    testWidgets('hides it, persists per connection, and survives a reopen', (
      tester,
    ) async {
      final kv = _MemoryKv();
      final container = _container(gw(), kv: kv);
      addTearDown(container.dispose);
      await _pump(tester, container);

      expect(find.text('alpha'), findsOneWidget);
      await tester.longPress(find.text('alpha'));
      await tester.pumpAndSettle();
      expect(find.text('alpha'), findsNothing);
      expect(find.text('beta'), findsOneWidget);
      expect(find.text('Removed alpha from recent folders'), findsOneWidget);
      // A long-press must not also fill the field.
      final field = tester.widget<TextField>(find.byType(TextField).first);
      expect(field.controller!.text, isNot('/work/alpha'));
      expect(await kv.get(hiddenCwdsKey('c1')), contains('/work/alpha'));

      // A fresh app run (new container, same storage) still hides it.
      final again = _container(gw(), kv: kv);
      addTearDown(again.dispose);
      // Tear the old tree down first: re-pumping the same MaterialApp would
      // keep the first run's open sheet route alive.
      await tester.pumpWidget(const SizedBox());
      again.read(hiddenCwdsProvider);
      await tester.pump();
      await _pump(tester, again);
      expect(find.text('alpha'), findsNothing);
      expect(find.text('beta'), findsOneWidget);
    });

    testWidgets('Undo brings it back', (tester) async {
      final container = _container(gw());
      addTearDown(container.dispose);
      await _pump(tester, container);

      await tester.longPress(find.text('alpha'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(find.text('alpha'), findsOneWidget);
      expect(find.text('Undo'), findsNothing);
      expect(container.read(hiddenCwdsProvider), isEmpty);
    });

    testWidgets('a tap still fills the field', (tester) async {
      final container = _container(gw());
      addTearDown(container.dispose);
      await _pump(tester, container);

      await tester.tap(find.text('beta'));
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField).first);
      expect(field.controller!.text, '/work/beta');
      expect(container.read(hiddenCwdsProvider), isEmpty);
    });

    testWidgets('starting a session in a hidden folder makes it recent again', (
      tester,
    ) async {
      final container = _container(gw());
      addTearDown(container.dispose);
      await _pump(tester, container);

      await tester.longPress(find.text('alpha'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '/work/alpha');
      await tester.tap(find.text('Start'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        container.read(hiddenCwdsProvider),
        isNot(contains('/work/alpha')),
      );
    });

    test('recentCwds fills the freed slot with the next folder', () {
      final saved = [
        for (var i = 0; i < 7; i++)
          SavedSession.fromJson(savedEntry('/w/f$i', exists: true)),
      ];
      expect(recentCwds(const [], saved, hidden: {'/w/f1'}), [
        '/w/f0',
        '/w/f2',
        '/w/f3',
        '/w/f4',
        '/w/f5',
      ]);
    });
  });
}
