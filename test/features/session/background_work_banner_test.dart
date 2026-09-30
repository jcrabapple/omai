// Background-work banner widget tests. Same harness as
// test/features/session/session_screen_test.dart (FakeSocket + MockClient).
// Covers: visible when idle + backgroundWork, hidden while running, hidden
// when the flag is false, hidden under a pending approval, the Stop session
// flow (confirm then DELETE /api/sessions/{id}), and the 360dp / 1.3 text
// scale no-overflow rule.
import 'dart:convert';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omai/api/client.dart';
import 'package:omai/composer/drafts.dart';
import 'package:omai/features/session/session_screen.dart';
import 'package:omai/state/connection_notifier.dart';
import 'package:omai/state/connection_store.dart';
import 'package:omai/state/session_controller.dart';
import 'package:omai/state/reviewed_store.dart';
import 'package:omai/state/sessions_store.dart';
import 'package:omai/stream/scheduler.dart';
import 'package:omai/stream/session_stream.dart';
import 'package:omai/theme/presets.dart';

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

class MemoryReviewedKv implements ReviewedKv {
  final map = <String, String>{};
  @override
  Future<String?> get(String key) async => map[key];
  @override
  Future<void> set(String key, String value) async => map[key] = value;
}

class MemoryDraftKv implements DraftKv {
  final map = <String, String>{};
  @override
  Future<String?> get(String key) async => map[key];
  @override
  Future<void> set(String key, String value) async => map[key] = value;
  @override
  Future<void> remove(String key) async => map.remove(key);
}

class SocketHub {
  final List<FakeSocket> sockets = [];
  FakeSocket get current => sockets.last;

  Future<StreamSocket> factory(Uri url, Map<String, String> headers) async {
    final sock = FakeSocket(url, headers);
    sockets.add(sock);
    return sock;
  }
}

class FakeGateway {
  FakeGateway({this.messages = const []});

  List<Object?> messages;

  /// GET /state payload (hasPendingAsyncWork, queued count, todoPhases).
  Map<String, Object?> stateBody = {};

  /// Every DELETE request path, for asserting the stop flow.
  final List<String> deletes = [];

  /// When set, the delete fails (500).
  bool failDelete = false;

  http.Client client() => MockClient((req) async {
    if (req.method == 'DELETE') {
      deletes.add(req.url.path);
      if (failDelete) return _json({'error': 'nope'}, status: 500);
      return _json({});
    }
    if (req.url.path.endsWith('/messages')) {
      return _json({'messages': messages});
    }
    if (req.url.path.endsWith('/state')) return _json(stateBody);
    if (req.url.path.endsWith('/stats')) return _json({'data': {}});
    if (req.url.path.endsWith('/commands')) {
      return _json({
        'data': {'commands': []},
      });
    }
    return _json({});
  });
}

ProviderContainer _container({
  required FakeGateway gateway,
  required SocketHub hub,
}) {
  final env = SessionEnv(
    client: GatewayClient(
      baseUrl: 'https://g',
      token: 'tok',
      client: gateway.client(),
    ),
    baseUrl: 'https://g',
    token: 'tok',
    socketFactory: hub.factory,
    scheduler: const SystemScheduler(),
  );
  final container = ProviderContainer(
    overrides: [
      connectionPrefsProvider.overrideWithValue(
        MemoryPrefs(const [
          ConnectionRecord(id: 'c1', url: 'https://g', label: 'G'),
        ]),
      ),
      tokenStoreProvider.overrideWithValue(_FixedTokenStore()),
      sessionsPollIntervalProvider.overrideWithValue(const Duration(hours: 1)),
      reviewedKvProvider.overrideWithValue(MemoryReviewedKv()),
      draftKvProvider.overrideWithValue(MemoryDraftKv()),
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

Future<void> _pumpReady(
  WidgetTester tester,
  ProviderContainer container, {
  String gwId = 'abc',
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MediaQuery(
        data: MediaQueryData(textScaler: textScaler),
        child: MaterialApp(
          theme: OmpTheme.data(OmpPreset.terminal),
          home: SessionScreen(gwId: gwId),
        ),
      ),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump();
    await tester.pump();
    final state = container.read(sessionControllerProvider(gwId));
    if (state.phase == SessionPhase.ready ||
        state.phase == SessionPhase.gone ||
        state.phase == SessionPhase.error) {
      break;
    }
  }
  await tester.pump();
}

const _bannerText =
    'Background work is still running. When it finishes, the agent will '
    'start again.';

void main() {
  testWidgets('visible when the session is idle with background work', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final gateway = FakeGateway()..stateBody = {'hasPendingAsyncWork': true};
    final container = _container(gateway: gateway, hub: hub);
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    expect(find.text(_bannerText), findsOneWidget);
    expect(find.text('Stop session'), findsOneWidget);
  });

  testWidgets('hidden while the session is running', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final gateway = FakeGateway()..stateBody = {'hasPendingAsyncWork': true};
    final container = _container(gateway: gateway, hub: hub);
    addTearDown(container.dispose);
    await _pumpReady(tester, container);
    expect(find.text(_bannerText), findsOneWidget);

    hub.current.frame(1, {'type': 'agent_start'});
    await tester.pump();
    await tester.pump();

    expect(
      find.text(_bannerText),
      findsNothing,
      reason: 'the banner is for the idle state only',
    );
  });

  testWidgets('hidden when backgroundWork is false', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final container = _container(gateway: FakeGateway(), hub: hub);
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    expect(find.text(_bannerText), findsNothing);
    expect(find.text('Stop session'), findsNothing);
  });

  testWidgets('hidden when an approval is pending', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final gateway = FakeGateway()..stateBody = {'hasPendingAsyncWork': true};
    final container = _container(gateway: gateway, hub: hub);
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    hub.current.frame(1, {
      'type': 'extension_ui_request',
      'id': 'u1',
      'method': 'confirm',
      'title': 'Run command',
      'message': 'rm -rf build',
    });
    await tester.pump();
    await tester.pump();

    expect(find.text('Run command'), findsOneWidget);
    expect(
      find.text(_bannerText),
      findsNothing,
      reason: 'the approval panel wins the slot',
    );
  });

  testWidgets(
    'tapping Stop session confirms, then DELETEs this gwId and pops',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final hub = SocketHub();
      final gateway = FakeGateway()..stateBody = {'hasPendingAsyncWork': true};
      final container = _container(gateway: gateway, hub: hub);
      addTearDown(container.dispose);
      await _pumpReady(tester, container);

      await tester.tap(find.text('Stop session'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Stop session'), findsNWidgets(2));
      expect(
        find.text('The agent stops. The transcript is saved in History.'),
        findsOneWidget,
      );

      gateway.deletes.clear();
      await tester.tap(find.text('Stop').last);
      await tester.pump();
      await tester.pump();

      expect(gateway.deletes, ['/api/sessions/abc']);
    },
  );

  testWidgets('cancelling the dialog sends no delete', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final gateway = FakeGateway()..stateBody = {'hasPendingAsyncWork': true};
    final container = _container(gateway: gateway, hub: hub);
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    await tester.tap(find.text('Stop session'));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump();

    expect(gateway.deletes, isEmpty);
  });

  testWidgets('fits a 360dp screen at text scale 1.3 without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final gateway = FakeGateway()..stateBody = {'hasPendingAsyncWork': true};
    final container = _container(gateway: gateway, hub: hub);
    addTearDown(container.dispose);
    await _pumpReady(tester, container, textScaler: TextScaler.linear(1.3));

    expect(find.text(_bannerText), findsOneWidget);
    expect(find.text('Stop session'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
