// Message actions at the session level: Inspect opens the raw-JSON sheet and
// Retry (idle only) sends omp's /retry command through the controller's send
// path. Ported from the web MessageActions inspector wiring.
import 'dart:convert';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ohmypi/api/client.dart';
import 'package:ohmypi/features/session/session_screen.dart';
import 'package:ohmypi/state/connection_notifier.dart';
import 'package:ohmypi/state/connection_store.dart';
import 'package:ohmypi/state/reviewed_store.dart';
import 'package:ohmypi/state/session_controller.dart';
import 'package:ohmypi/stream/scheduler.dart';
import 'package:ohmypi/stream/session_stream.dart';
import 'package:ohmypi/theme/presets.dart';
import 'package:ohmypi/composer/drafts.dart';

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
  final Map<String, Object?> bodies = {};

  http.Client client() => MockClient((req) async {
        if (req.body.isNotEmpty) {
          final decoded = jsonDecode(req.body);
          if (decoded is Map<String, Object?>) bodies[req.url.path] = decoded;
        }
        if (req.url.path.endsWith('/messages')) {
          return _json({'messages': messages});
        }
        if (req.url.path.endsWith('/state')) return _json({});
        if (req.url.path.endsWith('/stats')) return _json({'data': {}});
        if (req.url.path.endsWith('/commands')) {
          return _json({'data': {'commands': []}});
        }
        return _json({
          'gwId': 'abc',
          'cwd': '/work/x',
          'isStreaming': false,
          'lastEventSeq': 0,
        });
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
  final container = ProviderContainer(overrides: [
    connectionPrefsProvider.overrideWithValue(
      MemoryPrefs(const [ConnectionRecord(id: 'c1', url: 'https://g', label: 'G')]),
    ),
    tokenStoreProvider.overrideWithValue(_FixedTokenStore()),
    reviewedKvProvider.overrideWithValue(MemoryReviewedKv()),
    draftKvProvider.overrideWithValue(MemoryDraftKv()),
    sessionEnvProvider.overrideWith((ref) async => env),
  ]);
  container.read(connectionNotifierProvider.notifier).state = ConnectionState(
    connections: const [
      ConnectionRecord(id: 'c1', url: 'https://g', label: 'G'),
    ],
    activeId: 'c1',
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pumpReady(WidgetTester tester, ProviderContainer container,
    {String gwId = 'abc'}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: OmpTheme.data(OmpPreset.terminal),
        home: SessionScreen(gwId: gwId),
      ),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump();
    await tester.pump();
    final state = container.read(sessionControllerProvider(gwId));
    if (state.phase == SessionPhase.ready) break;
  }
  await tester.pump();
}

Future<void> _openMessageMenu(WidgetTester tester) async {
  await tester.longPress(find.text('Answer from the agent'));
  // Fixed pumps: a running session's spinners repaint forever, so
  // pumpAndSettle would never settle.
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  final history = <Object?>[
    {'role': 'user', 'content': 'question', 'timestamp': 1700000000000},
    {
      'role': 'assistant',
      'content': [
        {'type': 'text', 'text': 'Answer from the agent'},
      ],
      'timestamp': 1700000001000,
    },
  ];

  testWidgets('Inspect opens a sheet with the item raw JSON', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final gateway = FakeGateway(messages: history);
    final container = _container(
      gateway: gateway,
      hub: SocketHub(),
    );
    await _pumpReady(tester, container);

    await _openMessageMenu(tester);
    await tester.tap(find.text('Inspect'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Raw JSON'), findsOneWidget);
    expect(find.textContaining('"role": "assistant"'), findsOneWidget);
  });

  testWidgets('Retry turn sends /retry when the session is idle',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final gateway = FakeGateway(messages: history);
    final container = _container(
      gateway: gateway,
      hub: SocketHub(),
    );
    await _pumpReady(tester, container);

    await _openMessageMenu(tester);
    expect(find.text('Retry turn'), findsOneWidget);
    await tester.tap(find.text('Retry turn'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final body = gateway.bodies['/api/sessions/abc/prompt'];
    expect(body is Map ? body['message'] : null, '/retry');
  });

  testWidgets('no Retry turn while a turn is running', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final gateway = FakeGateway(messages: history);
    final container = _container(gateway: gateway, hub: hub);
    await _pumpReady(tester, container);

    hub.current.frame(1, {'type': 'agent_start'});
    await tester.pump();
    await tester.pump();

    await _openMessageMenu(tester);
    expect(find.text('Retry turn'), findsNothing);
    expect(find.text('Inspect'), findsOneWidget);

    hub.current.frame(2, {'type': 'agent_end'});
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
  });
}
