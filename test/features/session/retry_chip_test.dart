// The backend Retry chip in the composer: visible only after a backend turn
// failure, hidden while a turn runs and after a retry is accepted, and the
// tap POSTs /retry (never a '/retry' prompt). Ported from web
// components/__tests__/Composer.test.ts chip cases.
import 'dart:async';
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
import 'package:omai/state/reviewed_store.dart';
import 'package:omai/state/session_controller.dart';
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

class RetryGateway {
  RetryGateway({this.messages = const [], this.retryStatus = 200});

  List<Object?> messages;
  int retryStatus;

  /// When set, /retry requests are held until [completeRetry].
  bool holdRetry = false;
  Completer<http.Response>? _heldRetry;

  void completeRetry() {
    _heldRetry?.complete(_json({'ok': true}));
    _heldRetry = null;
  }

  final Map<String, Object?> bodies = {};
  final Set<String> visited = {};

  http.Client client() => MockClient((req) async {
    visited.add(req.url.path);
    if (req.body.isNotEmpty) {
      final decoded = jsonDecode(req.body);
      if (decoded is Map<String, Object?>) bodies[req.url.path] = decoded;
    }
    if (req.url.path.endsWith('/retry')) {
      if (holdRetry) {
        final held = Completer<http.Response>();
        _heldRetry = held;
        return held.future;
      }
      return _json({'ok': true}, status: retryStatus);
    }
    if (req.url.path.endsWith('/messages')) {
      return _json({'messages': messages});
    }
    if (req.url.path.endsWith('/state')) return _json({});
    if (req.url.path.endsWith('/stats')) return _json({'data': {}});
    if (req.url.path.endsWith('/commands')) {
      return _json({
        'data': {'commands': []},
      });
    }
    return _json({
      'gwId': 'abc',
      'cwd': '/work/x',
      'isStreaming': false,
      'lastEventSeq': 0,
    });
  });
}

/// A healthy turn: user question, clean assistant answer.
const List<Object?> _healthy = [
  {'role': 'user', 'content': 'question', 'timestamp': 1700000000000},
  {
    'role': 'assistant',
    'content': [
      {'type': 'text', 'text': 'Answer'},
    ],
    'timestamp': 1700000001000,
  },
];

/// The same turn that ended in a BACKEND failure: the assistant message
/// carries an errorMessage (the reducer's failure marker).
final List<Object?> _failedTurn = [
  _healthy[0],
  {
    'role': 'assistant',
    'content': [
      {'type': 'text', 'text': 'partial'},
    ],
    'errorMessage': 'model exploded',
    'timestamp': 1700000001000,
  },
];

ProviderContainer _container({
  required RetryGateway gateway,
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
      reviewedKvProvider.overrideWithValue(MemoryReviewedKv()),
      draftKvProvider.overrideWithValue(MemoryDraftKv()),
      sessionEnvProvider.overrideWith((ref) async => env),
    ],
  );
  container.read(connectionNotifierProvider.notifier).state = ConnectionState(
    connections: const [
      ConnectionRecord(id: 'c1', url: 'https://g', label: 'G'),
    ],
    activeId: 'c1',
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pumpReady(
  WidgetTester tester,
  ProviderContainer container, {
  String gwId = 'abc',
}) async {
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

void main() {
  testWidgets('no Retry chip on a healthy transcript', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = _container(
      gateway: RetryGateway(messages: _healthy),
      hub: SocketHub(),
    );
    await _pumpReady(tester, container);
    expect(find.text('Retry turn'), findsNothing);
  });

  testWidgets('the chip appears after a backend turn failure', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = _container(
      gateway: RetryGateway(messages: _failedTurn),
      hub: SocketHub(),
    );
    await _pumpReady(tester, container);
    expect(find.text('Retry turn'), findsOneWidget);
  });

  testWidgets('the chip hides while a turn is running', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final container = _container(
      gateway: RetryGateway(messages: _failedTurn),
      hub: hub,
    );
    await _pumpReady(tester, container);
    expect(find.text('Retry turn'), findsOneWidget);

    hub.current.frame(1, {'type': 'agent_start'});
    await tester.pump();
    await tester.pump();
    expect(find.text('Retry turn'), findsNothing);
  });

  testWidgets('tapping the chip POSTs /retry and never sends a /retry prompt', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final gateway = RetryGateway(messages: _failedTurn);
    final container = _container(gateway: gateway, hub: hub);
    await _pumpReady(tester, container);

    await tester.tap(find.text('Retry turn'));
    await tester.pump();
    await tester.pump();

    expect(gateway.visited.any((p) => p == '/api/sessions/abc/retry'), isTrue);
    // The old hack sent '/retry' as a prompt; that must never happen.
    final prompt = gateway.bodies['/api/sessions/abc/prompt'];
    expect(prompt is Map ? prompt['message'] : null, isNot('/retry'));
    expect(prompt, isNull);
  });

  testWidgets(
    'the chip hides after a retry is accepted, until the new turn starts',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final hub = SocketHub();
      final gateway = RetryGateway(messages: _failedTurn);
      final container = _container(gateway: gateway, hub: hub);
      await _pumpReady(tester, container);

      await tester.tap(find.text('Retry turn'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Retry turn'), findsNothing);

      // omp picking the retry up (agent_start) hands the transcript back to
      // its events: the failure stays until then, but the chip only ever
      // returns with a NEW failure after the turn ends.
      hub.current.frame(2, {'type': 'agent_start'});
      await tester.pump();
      await tester.pump();
      expect(find.text('Retry turn'), findsNothing);
    },
  );

  testWidgets('a failed retry shows the Could not retry snack', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final gateway = RetryGateway(messages: _failedTurn, retryStatus: 400);
    final container = _container(gateway: gateway, hub: SocketHub());
    await _pumpReady(tester, container);

    await tester.tap(find.text('Retry turn'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Could not retry'), findsOneWidget);
  });

  testWidgets('popping the session while a retry is pending throws nothing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final gateway = RetryGateway(messages: _failedTurn)..holdRetry = true;
    final container = _container(gateway: gateway, hub: hub);
    await _pumpReady(tester, container);

    // The retry request is in flight when the user leaves the session.
    await tester.tap(find.text('Retry turn'));
    await tester.pump();
    expect(gateway.visited.any((p) => p == '/api/sessions/abc/retry'), isTrue);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // The request completes AFTER the screen (and its controller) is gone.
    gateway.completeRetry();
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
