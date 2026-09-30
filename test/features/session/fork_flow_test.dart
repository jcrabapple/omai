// Fork from a message: visibility rules, navigation with a seeded draft, and
// error snacks. Ported from web MessageFork.test.ts / fork-flow.test.ts
// behaviour; the pump helpers follow message_actions_session_test.dart.
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
import 'package:omai/widgets/items/user_bubble.dart';

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

class ForkGateway {
  ForkGateway({
    this.messages = const [],
    this.entries = const [],
    this.forkStatus = 200,
    this.forkBody = const {
      'gwId': 'kid',
      'forkedFrom': 'abc',
      'text': 'from the gateway',
    },
    this.holdPrompt = false,
  });

  List<Object?> messages;
  List<Object?> entries;
  int forkStatus;
  Object? forkBody;
  bool holdPrompt;

  /// A prompt held by [holdPrompt], released by [completePrompt] so the test
  /// can end without a pending timer.
  Completer<http.Response>? _held;
  final Map<String, Object?> bodies = {};
  final Set<String> visited = {};

  void completePrompt() {
    _held?.complete(_json({'ok': true}));
    _held = null;
  }

  http.Client client() => MockClient((req) async {
    visited.add(req.url.path);
    if (req.body.isNotEmpty) {
      final decoded = jsonDecode(req.body);
      if (decoded is Map<String, Object?>) bodies[req.url.path] = decoded;
    }
    if (req.url.path.endsWith('/prompt')) {
      if (holdPrompt) {
        final held = Completer<http.Response>();
        _held = held;
        return held.future;
      }
      return _json({'ok': true});
    }
    if (req.url.path.endsWith('/entries')) {
      return _json({'entries': entries});
    }
    if (req.url.path.endsWith('/fork')) {
      return _json(forkBody, status: forkStatus);
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

ProviderContainer _container({
  required ForkGateway gateway,
  required SocketHub hub,
  required MemoryDraftKv drafts,
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
      draftKvProvider.overrideWithValue(drafts),
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

final List<Object?> _history = [
  {'role': 'user', 'content': 'question', 'timestamp': 1700000000000},
  {
    'role': 'assistant',
    'content': [
      {'type': 'text', 'text': 'Answer from the agent'},
    ],
    'timestamp': 1700000001000,
  },
];

final List<Object?> _entries = [
  {'entryId': 'e1', 'role': 'user', 'timestamp': 1700000000000},
  {'entryId': 'e2', 'role': 'assistant', 'timestamp': 1700000001000},
];

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

Future<void> _openUserMenu(WidgetTester tester) async {
  final overflow = find.descendant(
    of: find.byType(UserBubble),
    matching: find.byTooltip('Message actions'),
  );
  await tester.tap(overflow.first);
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('Fork from here is offered on a settled user message', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final gateway = ForkGateway(messages: _history, entries: _entries);
    final container = _container(
      gateway: gateway,
      hub: hub,
      drafts: MemoryDraftKv(),
    );
    await _pumpReady(tester, container);

    await _openUserMenu(tester);
    expect(find.text('Fork from here'), findsOneWidget);
  });

  testWidgets('no Fork from here while a turn is running', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final gateway = ForkGateway(messages: _history, entries: _entries);
    final container = _container(
      gateway: gateway,
      hub: hub,
      drafts: MemoryDraftKv(),
    );
    await _pumpReady(tester, container);

    hub.current.frame(1, {'type': 'agent_start'});
    await tester.pump();
    await tester.pump();

    await _openUserMenu(tester);
    expect(find.text('Fork from here'), findsNothing);
  });

  testWidgets('no Fork from here on a pending bubble', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    // The prompt never acks, so the just-sent bubble stays pending.
    final gateway = ForkGateway(messages: _history, holdPrompt: true);
    final container = _container(
      gateway: gateway,
      hub: hub,
      drafts: MemoryDraftKv(),
    );
    await _pumpReady(tester, container);

    await tester.enterText(find.byType(TextField).first, 'a new message');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    await tester.pump();

    expect(find.byType(UserBubble), findsNWidgets(2));
    final pendingBubble = find.widgetWithText(UserBubble, 'a new message');
    expect(pendingBubble, findsOneWidget);
    final overflow = find.descendant(
      of: pendingBubble,
      matching: find.byTooltip('Message actions'),
    );
    await tester.tap(overflow);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Fork from here'), findsNothing);

    // Let the held send finish so no timer outlives the test.
    gateway.completePrompt();
    await tester.pump();
    await tester.pump();
  });

  testWidgets('fork navigates to the new session with the draft seeded', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final gateway = ForkGateway(messages: _history, entries: _entries);
    final drafts = MemoryDraftKv();
    final container = _container(gateway: gateway, hub: hub, drafts: drafts);
    await _pumpReady(tester, container);

    await _openUserMenu(tester);
    await tester.tap(find.text('Fork from here'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // The gateway saw the fork at the matched user entry.
    expect(gateway.bodies['/api/sessions/abc/fork'], {'entryId': 'e1'});
    await tester.pump();
    await tester.pump();
    // Let the route transition finish so the replaced parent is disposed.
    await tester.pumpAndSettle();

    // The new session screen replaced the parent on the navigator.
    final screens = tester
        .widgetList<SessionScreen>(find.byType(SessionScreen))
        .toList();
    expect(screens, hasLength(1));
    expect(screens.single.gwId, 'kid');
    // The composer of the new session loaded the seeded draft.
    expect(
      find.byType(TextField),
      findsWidgets,
      reason: 'the composer is on screen',
    );
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      'question',
    );
    // The snack rides the NEW route's scaffold, not the replaced one.
    expect(find.text('Forked to new session'), findsOneWidget);
  });

  testWidgets('a busy session shows the 409 snack and stays', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final gateway = ForkGateway(
      messages: _history,
      entries: _entries,
      forkStatus: 409,
      forkBody: {'error': 'busy'},
    );
    final container = _container(
      gateway: gateway,
      hub: hub,
      drafts: MemoryDraftKv(),
    );
    await _pumpReady(tester, container);

    await _openUserMenu(tester);
    await tester.tap(find.text('Fork from here'));
    await tester.pump();
    await tester.pump();

    expect(find.text('The session is busy'), findsOneWidget);
    // Still on the parent session.
    expect(gateway.visited.contains('/api/sessions/kid/messages'), isFalse);
  });
}
