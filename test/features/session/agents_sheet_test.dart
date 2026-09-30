// Agents sheet widget tests. Same harness as
// test/features/session/background_work_banner_test.dart (FakeSocket +
// MockClient). Covers: the overflow menu item opens the sheet, the banner's
// 'Show agents' button opens it, the empty state, live updates while the
// sheet is open (subagent_progress frames), the per-agent transcript with
// Load more paging, the transcript error state with retry, TalkBack row
// labels, and the 360dp / 1.3 text scale no-overflow rule.
import 'dart:convert';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omai/api/client.dart';
import 'package:omai/composer/drafts.dart';
import 'package:omai/features/session/agents_sheet.dart';
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

  /// GET /subagents payload (the registry snapshot the roster seeds from).
  Object? subagentsBody = {'subagents': []};

  /// Transcript pages by `from` query param (null = first page).
  Map<String?, Object?> transcriptPages = {};
  final List<String?> transcriptRequests = [];

  /// When set, transcript requests fail with this status.
  int failTranscriptStatus = 0;

  http.Client client() => MockClient((req) async {
    if (req.url.path.endsWith('/subagents')) return _json(subagentsBody);
    if (req.url.path.contains('/subagents/') &&
        req.url.path.endsWith('/messages')) {
      if (failTranscriptStatus != 0) {
        return _json({'error': 'nope'}, status: failTranscriptStatus);
      }
      final from = req.url.queryParameters['from'];
      transcriptRequests.add(from);
      return _json(transcriptPages[from] ?? {'messages': []});
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
  Size size = const Size(900, 1600),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MediaQuery(
        // Size must ride along: the sheet caps its height at 80 % of the
        // screen, and a default MediaQueryData reports Size.zero.
        data: MediaQueryData(size: size, textScaler: textScaler),
        child: MaterialApp(
          theme: OmpTheme.data(OmpPreset.terminal),
          home: SessionScreen(gwId: gwId),
        ),
      ),
    ),
  );
  for (var i = 0; i < 30; i++) {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final state = container.read(sessionControllerProvider(gwId));
    if (state.phase == SessionPhase.ready ||
        state.phase == SessionPhase.gone ||
        state.phase == SessionPhase.error) {
      break;
    }
  }
  await tester.pump();
}

Future<void> _openViaMenu(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Session actions'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  expect(find.text('Agents'), findsOneWidget, reason: 'menu item present');
  await tester.tap(find.text('Agents'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Bounded settle for sheets that contain a running-agent spinner (which
/// never settles).
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Map<String, Object?> _userMsg(String id, String text) => {
  'id': id,
  'role': 'user',
  'content': [
    {'type': 'text', 'text': text},
  ],
};

Map<String, Object?> _assistantMsg(String id, String text) => {
  'id': id,
  'role': 'assistant',
  'content': [
    {'type': 'text', 'text': text},
  ],
};

void main() {
  testWidgets('empty state when the session has no background agents', (
    tester,
  ) async {
    final hub = SocketHub();
    final container = _container(gateway: FakeGateway(), hub: hub);
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    await _openViaMenu(tester);

    expect(find.text('Agents'), findsWidgets);
    expect(find.text('No background agents in this session.'), findsOneWidget);
  });

  testWidgets('the overflow menu item Agents opens the sheet', (tester) async {
    final hub = SocketHub();
    final gateway = FakeGateway()
      ..subagentsBody = {
        'subagents': [
          {
            'id': 'sa1',
            'index': 0,
            'agent': 'explore',
            'status': 'running',
            'task': 'map the surface',
            'tokens': 1200,
          },
        ],
      };
    final container = _container(gateway: gateway, hub: hub);
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    await _openViaMenu(tester);

    expect(find.text('explore'), findsOneWidget);
    expect(find.text('No background agents in this session.'), findsNothing);
  });

  testWidgets("the banner's Show agents button opens the sheet", (
    tester,
  ) async {
    final hub = SocketHub();
    final gateway = FakeGateway()..stateBody = {'hasPendingAsyncWork': true};
    final container = _container(gateway: gateway, hub: hub);
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    expect(find.byKey(const ValueKey('banner-show-agents')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('banner-show-agents')));
    await _settle(tester);

    expect(find.text('No background agents in this session.'), findsOneWidget);
  });

  testWidgets('rows update live while the sheet is open', (tester) async {
    final hub = SocketHub();
    final container = _container(gateway: FakeGateway(), hub: hub);
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    await _openViaMenu(tester);
    expect(find.text('No background agents in this session.'), findsOneWidget);
    final semantics = tester.ensureSemantics();

    hub.current.frame(5, {
      'type': 'subagent_progress',
      'payload': {
        'index': 0,
        'progress': {
          'id': 'sa9',
          'index': 0,
          'agent': 'explore',
          'status': 'running',
          'task': 'map the surface',
        },
      },
    });
    await tester.pump();
    await tester.pump();

    expect(find.text('explore'), findsOneWidget);
    expect(find.text('map the surface'), findsOneWidget);
    // Running rows carry the status word in the semantic label.
    expect(
      find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == 'explore: Running',
      ),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('tapping a row opens the transcript with Load more paging', (
    tester,
  ) async {
    final hub = SocketHub();
    final gateway = FakeGateway()
      ..subagentsBody = {
        'subagents': [
          {
            'id': 'sa1',
            'index': 0,
            'agent': 'explore',
            'status': 'running',
            'task': 'map the surface',
          },
        ],
      }
      ..transcriptPages = {
        null: {
          'messages': [_userMsg('m1', 'hello subagent')],
          'nextByte': 1024,
          'reset': false,
        },
        '1024': {
          'messages': [_assistantMsg('m2', 'subagent reply')],
          'nextByte': null,
          'reset': false,
        },
      };
    final container = _container(gateway: gateway, hub: hub);
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    await _openViaMenu(tester);
    final inkwell = find.descendant(
      of: find.byKey(const ValueKey('agent-row-sa1')),
      matching: find.byType(InkWell),
    );
    // ignore: avoid_print
    print(
      'INK_RECT=${tester.getRect(inkwell.first)} POINTS=${tester.getRect(find.text('explore'))}',
    );
    await tester.tap(inkwell.first, warnIfMissed: false);
    await _settle(tester);
    // ignore: avoid_print
    print(
      'PAGE=${find.byType(SubagentTranscriptPage).evaluate().length} REQ=${gateway.transcriptRequests}',
    );

    // Page 1 is in.
    expect(find.text('hello subagent'), findsOneWidget);
    expect(gateway.transcriptRequests, [null]);
    expect(find.byKey(const ValueKey('agents-load-more')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('agents-load-more')));
    await _settle(tester);

    // Page 2 appended, Load more gone (nextByte exhausted).
    expect(find.text('subagent reply'), findsOneWidget);
    expect(find.text('hello subagent'), findsOneWidget);
    expect(gateway.transcriptRequests, [null, '1024']);
    expect(find.byKey(const ValueKey('agents-load-more')), findsNothing);
  });

  testWidgets('transcript load failure shows an error state with retry', (
    tester,
  ) async {
    final hub = SocketHub();
    final gateway = FakeGateway()
      ..subagentsBody = {
        'subagents': [
          {
            'id': 'sa1',
            'index': 0,
            'agent': 'explore',
            'status': 'running',
            'task': 'map the surface',
          },
        ],
      }
      ..failTranscriptStatus = 500;
    final container = _container(gateway: gateway, hub: hub);
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    await _openViaMenu(tester);
    await tester.tap(find.text('explore'));
    await _settle(tester);

    // A 5xx reads as a connectivity error; the error branch shows Retry.
    expect(
      find.byKey(const ValueKey('agents-transcript-retry')),
      findsOneWidget,
    );

    gateway.failTranscriptStatus = 0;
    gateway.transcriptPages[null] = {
      'messages': [_userMsg('m1', 'hello subagent')],
      'nextByte': null,
      'reset': false,
    };
    await tester.tap(find.byKey(const ValueKey('agents-transcript-retry')));
    await _settle(tester);

    expect(find.text('hello subagent'), findsOneWidget);
  });

  testWidgets('fits a 360dp screen at text scale 1.3 without overflow', (
    tester,
  ) async {
    final hub = SocketHub();
    final gateway = FakeGateway()
      ..subagentsBody = {
        'subagents': [
          {
            'id': 'sa1-long-identifier',
            'index': 0,
            'agent': 'explore',
            'status': 'running',
            'task': 'a very long task description that will not fit on one line at all',
            'tokens': 12345,
            'cost': 0.42,
            'resolvedModel': 'anthropic/claude-opus-4-6',
          },
          {
            'id': 'sa2',
            'index': 1,
            'agent': 'fix',
            'status': 'completed',
            'task': 'short task',
          },
        ],
      };
    final container = _container(gateway: gateway, hub: hub);
    addTearDown(container.dispose);
    await _pumpReady(
      tester,
      container,
      textScaler: TextScaler.linear(1.3),
      size: const Size(360, 740),
    );

    await _openViaMenu(tester);

    expect(find.text('explore'), findsOneWidget);
    expect(find.text('fix'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
