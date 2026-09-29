// Sessions screen widget tests: groups render, empty sections hide, an error
// with an existing list shows the stale-first banner (never a blank page),
// and pull-to-refresh refetches. The gateway is a MockClient; no network.

import 'dart:convert';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ohmypi/api/client.dart';
import 'package:ohmypi/app/app.dart';
import 'package:ohmypi/features/sessions/sessions_screen.dart';
import 'package:ohmypi/state/connection_notifier.dart';
import 'package:ohmypi/state/connection_store.dart';
import 'package:ohmypi/state/reviewed_store.dart';
import 'package:ohmypi/state/sessions_store.dart';
import 'package:ohmypi/theme/presets.dart';

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

/// Scriptable /api/sessions; counts requests so tests can prove refreshes.
class ScriptableGateway {
  ScriptableGateway({this.status = 200, Map<String, Object?>? payload})
      : payload = payload ?? const {'live': [], 'saved': []};

  int status;
  Map<String, Object?> payload;
  int requests = 0;

  http.Client client() => MockClient((req) async {
        requests++;
        return _json(status == 200 ? payload : {'error': 'nope'},
            status: status);
      });
}

Map<String, Object?> liveJson({
  String gwId = 'a',
  bool streaming = false,
  bool exited = false,
  List<Object?> pendingUi = const [],
  String cwd = '/work/prompter',
}) =>
    {
      'gwId': gwId,
      'cwd': cwd,
      'isStreaming': streaming,
      'exited': exited,
      'lastEventSeq': 1,
      'pendingUi': pendingUi,
      'model': {'id': 'test-model', 'provider': 'test', 'name': 'Test Model'},
    };

class _MemoryKv implements ReviewedKv {
  final Map<String, String> _map = {};

  @override
  Future<String?> get(String key) async => _map[key];

  @override
  Future<void> set(String key, String value) async => _map[key] = value;
}

ProviderContainer _container(ScriptableGateway gateway) {
  final container = ProviderContainer(overrides: [
    reviewedKvProvider.overrideWithValue(_MemoryKv()),
    connectionPrefsProvider.overrideWithValue(MemoryPrefs(const [
      ConnectionRecord(id: 'c1', url: 'https://g', label: 'G')
    ])),
    tokenStoreProvider.overrideWithValue(_FixedTokenStore()),
    // A 5 s poll reschedules frames forever and pumpAndSettle never settles.
    sessionsPollIntervalProvider
        .overrideWithValue(const Duration(hours: 1)),
    gatewayClientFactoryProvider.overrideWith((ref) => (baseUrl, token) =>
        GatewayClient(baseUrl: baseUrl, token: token,
            client: gateway.client())),
  ]);
  container.read(connectionNotifierProvider.notifier).state =
      ConnectionState(
          connections: const [
        ConnectionRecord(id: 'c1', url: 'https://g', label: 'G')
      ],
          activeId: 'c1');
  return container;
}

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: OmpTheme.data(OmpPreset.terminal),
      navigatorObservers: [ompRouteObserver],
      home: const SessionsScreen(),
    ),
  ));
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('renders the groups and hides empty sections', (tester) async {
    final gateway = ScriptableGateway(payload: {
      'live': [
        liveJson(gwId: 'need', pendingUi: [
          {'id': 'u1', 'method': 'tool_approval'}
        ]),
        liveJson(gwId: 'run', streaming: true, cwd: '/work/runner'),
      ],
      'saved': [
        {
          'file': '/t/one.jsonl',
          'mtime': DateTime.now().millisecondsSinceEpoch / 1000,
          'sizeBytes': 10,
          'cwdFolder': 'x',
          'title': 'Old chat',
        }
      ],
    });
    final container = _container(gateway);
    addTearDown(container.dispose);
    await _pump(tester, container);

    expect(find.text('NEEDS YOU'), findsOneWidget);
    expect(find.text('RUNNING'), findsOneWidget);
    expect(find.text('TODAY'), findsOneWidget);
    expect(find.text('READY FOR REVIEW'), findsNothing);
    expect(find.text('IDLE'), findsNothing);
    expect(find.text('Old chat'), findsOneWidget);
  });

  testWidgets('an error with an existing list shows a banner, not a blank page',
      (tester) async {
    final gateway = ScriptableGateway(payload: {
      'live': [liveJson(gwId: 'idle')],
      'saved': [],
    });
    final container = _container(gateway);
    addTearDown(container.dispose);
    await _pump(tester, container);
    expect(find.text('prompter'), findsOneWidget);

    gateway.status = 500;
    await container.read(sessionsStoreProvider.notifier).refresh();
    await tester.pump();
    await tester.pump();

    expect(find.text("Can't reach the gateway. Trying again."),
        findsOneWidget);
    expect(find.text('prompter'), findsOneWidget,
        reason: 'the stale list stays on screen');
    expect(container.read(sessionsStoreProvider).error, isNotNull);
  });

  testWidgets('pull-to-refresh refetches the list', (tester) async {
    final gateway = ScriptableGateway(payload: {
      'live': [liveJson()],
      'saved': [],
    });
    final container = _container(gateway);
    addTearDown(container.dispose);
    await _pump(tester, container);
    final before = gateway.requests;

    await tester.fling(find.byType(ListView), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();

    expect(gateway.requests, greaterThan(before));
  });

  testWidgets('empty state when there are no sessions', (tester) async {
    final gateway = ScriptableGateway();
    final container = _container(gateway);
    addTearDown(container.dispose);
    await _pump(tester, container);

    expect(find.text('No sessions yet.'), findsOneWidget);
  });
}
