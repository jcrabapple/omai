// New session sheet widget tests: empty-cwd validation, recent-cwd chips,
// create posts the API.md body and opens the new session, and a 429 session
// cap shows the gateway's own message inline. The gateway is a MockClient;
// the session screen runs on the shared fakes; no network.

import 'dart:convert';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ohmypi/api/client.dart';
import 'package:ohmypi/app/app.dart';
import 'package:ohmypi/composer/drafts.dart';
import 'package:ohmypi/features/new_session/new_session_sheet.dart';
import 'package:ohmypi/features/session/session_screen.dart';
import 'package:ohmypi/state/connection_notifier.dart';
import 'package:ohmypi/state/connection_store.dart';
import 'package:ohmypi/state/reviewed_store.dart';
import 'package:ohmypi/state/session_controller.dart';
import 'package:ohmypi/state/sessions_store.dart';
import 'package:ohmypi/stream/scheduler.dart';
import 'package:ohmypi/theme/presets.dart';

import '../../stream/fakes.dart';

http.Response _json(Object? body, {int status = 200}) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});

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
  FakeGateway({this.createStatus = 200, this.createBody});
  int createStatus;
  Map<String, Object?>? createBody;
  final List<Object?> bodies = [];

  http.Client client() => MockClient((req) async {
        if (req.method == 'POST' && req.url.path == '/api/sessions') {
          bodies.add(jsonDecode(req.body));
          if (createStatus != 200) {
            return _json(createBody ?? {'error': 'nope'}, status: createStatus);
          }
          return _json(createBody ??
              {
                'gwId': 'gw-new',
                'cwd': '/work/prompter',
                'approvalMode': 'yolo',
              });
        }
        if (req.url.path == '/api/sessions') {
          return _json({
            'live': [
              {'gwId': 'live-1', 'cwd': '/work/prompter'}
            ],
            'saved': const [],
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

ProviderContainer _container(FakeGateway gateway) {
  final env = SessionEnv(
      client: GatewayClient(
          baseUrl: 'https://g', token: 'tok', client: gateway.client()),
      baseUrl: 'https://g',
      token: 'tok',
      socketFactory: (url, headers) async {
        final sock = FakeSocket(url, headers);
        return sock;
      },
      scheduler: const SystemScheduler());
  final container = ProviderContainer(overrides: [
    reviewedKvProvider.overrideWithValue(_MemoryKv()),
    draftKvProvider.overrideWithValue(_MemoryDraftKv()),
    connectionPrefsProvider.overrideWithValue(MemoryPrefs(const [
      ConnectionRecord(id: 'c1', url: 'https://g', label: 'G')
    ])),
    tokenStoreProvider.overrideWithValue(_FixedTokenStore()),
    sessionsPollIntervalProvider
        .overrideWithValue(const Duration(hours: 1)),
    gatewayClientFactoryProvider.overrideWith((ref) => (baseUrl, token) =>
        GatewayClient(baseUrl: baseUrl, token: token,
            client: gateway.client())),
    sessionEnvProvider.overrideWith((ref) async => env),
  ]);
  container.read(connectionNotifierProvider.notifier).state = ConnectionState(
      connections:
          const [ConnectionRecord(id: 'c1', url: 'https://g', label: 'G')],
      activeId: 'c1');
  return container;
}

Future<void> _pump(WidgetTester tester, ProviderContainer container,
    {ValueChanged<Object>? onCreated}) async {
  // A tall surface: the sheet is scrollable and Start must be on-screen.
  tester.view.physicalSize = const Size(800, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: OmpTheme.data(OmpPreset.terminal),
      navigatorObservers: [ompRouteObserver],
      home: Consumer(builder: (context, ref, _) => Scaffold(
        body: const SizedBox.shrink(),
        floatingActionButton: FloatingActionButton(
          onPressed: () => showNewSessionSheet(context, ref,
              onCreated: (info) {
            if (onCreated != null) {
              onCreated(info);
              return;
            }
            // Mirror the sessions screen: open the new session.
            ref.read(sessionsStoreProvider.notifier).setOpenSession(info.gwId);
            Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => SessionScreen(gwId: info.gwId)));
          }),
        ),
      )),
    ),
  ));
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

  testWidgets('create posts the API.md body and opens the new session',
      (tester) async {
    final gateway = FakeGateway();
    final container = _container(gateway);
    addTearDown(container.dispose);
    await _pump(tester, container);

    await tester.enterText(
        find.byType(TextField).first, '/work/newproj');
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
        'gw-new');
  });

  testWidgets('a 429 session cap shows the gateway message inline',
      (tester) async {
    final gateway = FakeGateway(
        createStatus: 429,
        createBody: {'error': 'session limit reached (8); stop one first'});
    final container = _container(gateway);
    addTearDown(container.dispose);
    await _pump(tester, container);

    await tester.enterText(find.byType(TextField).first, '/work/newproj');
    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.pump();

    expect(find.text('session limit reached (8); stop one first'),
        findsOneWidget);
    expect(find.byType(SessionScreen), findsNothing);
    // The sheet stays open, so the user can go stop one and retry.
    expect(find.text('New session'), findsOneWidget);
  });

  testWidgets('thinking chips are at least 48dp tall (touch target)',
      (tester) async {
    final gateway = FakeGateway();
    final container = _container(gateway);
    addTearDown(container.dispose);
    await _pump(tester, container);

    final chip = tester.getSize(
      find.ancestor(
        of: find.text('medium'),
        matching: find.byType(InkWell),
      ).first,
    );
    expect(chip.height, greaterThanOrEqualTo(48.0),
        reason: 'thinking-level chips must meet the 48dp hit target');
  });
}
