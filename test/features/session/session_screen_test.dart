// Session screen widget tests. The controller runs against the shared fakes
// (FakeSocket + MockClient, mirroring test/state/session_controller_test.dart);
// no network, no live gateway. Covers the RikkaHub #1077 rule (opens at the
// newest, follow, jump pill), the activity line, gone state and the pending
// approval banner.

import 'dart:convert';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ohmypi/api/client.dart';
import 'package:ohmypi/composer/drafts.dart';
import 'package:ohmypi/features/session/session_screen.dart';
import 'package:ohmypi/features/session/session_header.dart';
import 'package:ohmypi/state/connection_notifier.dart';
import 'package:ohmypi/state/connection_store.dart';
import 'package:ohmypi/state/session_controller.dart';
import 'package:ohmypi/state/reviewed_store.dart';
import 'package:ohmypi/state/sessions_store.dart';
import 'package:ohmypi/stream/scheduler.dart';
import 'package:ohmypi/stream/session_stream.dart';
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
  FakeGateway({this.status = 200, this.messages = const []});

  int status;
  List<Object?> messages;

  /// GET /api/sessions/[gwId] payload (SessionInfo), for header tests.
  Map<String, Object?>? info;

  /// Request bodies by path, for asserting prompts and answers.
  final Map<String, Object?> bodies = {};

  http.Client client() => MockClient((req) async {
    if (req.body.isNotEmpty) {
      final decoded = jsonDecode(req.body);
      if (decoded is Map<String, Object?>) bodies[req.url.path] = decoded;
    }
    if (status != 200) {
      return _json({'error': 'nope'}, status: status);
    }
    if (req.url.path.endsWith('/messages')) {
      return _json({'messages': messages});
    }
    if (info != null &&
        (req.url.path == '/api/sessions/abc' ||
            req.url.path.endsWith('/info'))) {
      return _json(info);
    }
    if (req.url.path.endsWith('/state')) return _json({});
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

List<Map<String, Object?>> _history(int n) => [
  for (var i = 0; i < n; i++)
    {'role': 'user', 'content': 'message-$i', 'timestamp': 1700000000000 + i},
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
    if (state.phase == SessionPhase.ready ||
        state.phase == SessionPhase.gone ||
        state.phase == SessionPhase.error) {
      break;
    }
  }
  await tester.pump();
}

void main() {
  testWidgets('a 200-item session opens at the newest item, never the top', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final container = _container(
      gateway: FakeGateway(messages: _history(200)),
      hub: hub,
    );
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    expect(
      find.text('message-199'),
      findsOneWidget,
      reason: 'the newest item is on screen',
    );
    expect(
      find.text('message-0'),
      findsNothing,
      reason: 'the first item is off screen: no stuck-at-top',
    );
    final controller = tester
        .widget<ListView>(find.byType(ListView))
        .controller!;
    expect(controller.offset, 0, reason: 'offset 0 is the bottom (reverse)');
  });

  testWidgets('new content while at the bottom stays followed', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final container = _container(
      gateway: FakeGateway(messages: _history(50)),
      hub: hub,
    );
    addTearDown(container.dispose);
    await _pumpReady(tester, container);
    expect(find.text('message-49'), findsOneWidget);

    hub.current.frame(1, {
      'type': 'message_update',
      'message': {
        'role': 'user',
        'content': 'fresh message',
        'timestamp': 1700000999999,
      },
    });
    await tester.pump();
    await tester.pump();

    expect(find.text('fresh message'), findsOneWidget);
    expect(
      find.text('Jump to latest'),
      findsNothing,
      reason: 'following at the bottom never shows the pill',
    );
  });

  testWidgets(
    'scrolled up: streaming growth + new blocks never move the reading '
    'position; the pill counts exactly the new blocks; tapping returns',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final hub = SocketHub();
      final container = _container(
        gateway: FakeGateway(messages: _history(60)),
        hub: hub,
      );
      addTearDown(container.dispose);
      await _pumpReady(tester, container);

      // Seed an assistant message while still at the bottom (following), so a
      // later streaming run grows an EXISTING block instead of adding one.
      hub.current.frame(1, {
        'type': 'message_update',
        'messageId': 'm-a1',
        'message': {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'streamed answer'},
          ],
          'timestamp': 1700000900000,
        },
      });
      await tester.pump();
      await tester.pump();

      // Reverse list: older items sit above, so reveal them with a downward
      // finger drag.
      await tester.drag(find.byType(ListView), const Offset(0, 1500));
      await tester.pumpAndSettle();
      final controller = tester
          .widget<ListView>(find.byType(ListView))
          .controller!;
      expect(controller.offset, greaterThan(0));

      // What the user is reading, in SCREEN coordinates.
      final reading = find.textContaining('message-').first;
      final dyBefore = tester.getTopLeft(reading).dy;

      // 20 token deltas into the streaming assistant message...
      for (var i = 1; i <= 20; i++) {
        hub.current.frame(1 + i, {
          'type': 'message_update',
          'messageId': 'm-a1',
          'message': {
            'role': 'assistant',
            'content': [
              {
                'type': 'text',
                'text': 'streamed answer ${List.filled(i, 'tok').join(' ')}',
              },
            ],
            'timestamp': 1700000900000,
          },
        });
        // Advance past the markdown throttle so the rendered height tracks
        // the streamed text the way real streaming does.
        await tester.pump(const Duration(milliseconds: 120));
      }
      // ...and 2 whole new blocks.
      hub.current.frame(30, {
        'type': 'message_update',
        'messageId': 'm-a2',
        'message': {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'brand new block one'},
          ],
          'timestamp': 1700000950000,
        },
      });
      hub.current.frame(31, {
        'type': 'message_update',
        'messageId': 'm-u2',
        'message': {
          'role': 'user',
          'content': 'brand new block two',
          'timestamp': 1700000960000,
        },
      });
      // One frame lays out the growth, the next applies the reading-position
      // compensation; a little time lets the markdown throttle settle.
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      final dyAfter = tester
          .getTopLeft(find.textContaining('message-').first)
          .dy;
      expect(
        dyAfter,
        lessThanOrEqualTo(dyBefore + 1.0),
        reason: 'reading position must not be pushed down',
      );
      expect(
        dyAfter,
        greaterThanOrEqualTo(dyBefore - 1.0),
        reason: 'reading position must not be pulled up either',
      );
      expect(
        find.text('Jump to latest (2 new)'),
        findsOneWidget,
        reason: 'exactly the 2 new blocks, not the 20 streaming deltas',
      );
      // Touch target (finding 12): the pill is at least 48dp tall.
      expect(
        tester
            .getSize(
              find.ancestor(
                of: find.textContaining('Jump to latest'),
                matching: find.byType(InkWell),
              ).first,
            )
            .height,
        greaterThanOrEqualTo(48.0),
      );

      await tester.tap(find.textContaining('Jump to latest'));
      await tester.pumpAndSettle();
      expect(controller.offset, 0);
      expect(find.text('brand new block two'), findsOneWidget);
    },
  );

  testWidgets('following: the newest block stays on screen while it streams', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final container = _container(
      gateway: FakeGateway(messages: _history(50)),
      hub: hub,
    );
    addTearDown(container.dispose);
    await _pumpReady(tester, container);
    expect(find.text('message-49'), findsOneWidget);

    final controller = tester
        .widget<ListView>(find.byType(ListView))
        .controller!;
    for (var i = 1; i <= 20; i++) {
      hub.current.frame(i, {
        'type': 'message_update',
        'messageId': 'm-live',
        'message': {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'live chunk $i'},
          ],
          'timestamp': 1700000970000,
        },
      });
      await tester.pump();
      await tester.pump();
    }
    // End the message so streaming stops and the throttle timer flushes.
    hub.current.frame(21, {
      'type': 'message_end',
      'messageId': 'm-live',
      'message': {
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'live chunk 20'},
        ],
        'timestamp': 1700000970000,
      },
    });
    await tester.pump();
    await tester.pump();

    expect(
      controller.offset,
      lessThanOrEqualTo(120.0),
      reason: 'following keeps the viewport in the bottom follow zone',
    );
    expect(
      find.textContaining('live chunk 20', findRichText: true),
      findsOneWidget,
      reason: 'the newest streamed content is on screen',
    );
    expect(find.textContaining('Jump to latest'), findsNothing);
  });

  testWidgets('agent_start shows the activity line; agent_end clears it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final container = _container(
      gateway: FakeGateway(messages: _history(2)),
      hub: hub,
    );
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    hub.current.frame(1, {'type': 'agent_start'});
    await tester.pump();
    await tester.pump();
    expect(
      container.read(sessionControllerProvider('abc')).activity,
      isNotNull,
    );
    expect(find.byType(ActivityLine), findsOneWidget);

    hub.current.frame(2, {'type': 'agent_end'});
    // agent_end schedules a 600 ms stats refresh; let it fire so no timer is
    // left pending.
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    expect(container.read(sessionControllerProvider('abc')).activity, isNull);
    expect(find.byType(ActivityLine), findsNothing);
  });

  testWidgets('running with no visible progress shows an in-transcript '
      'Working row, even on an empty transcript', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final container = _container(
      gateway: FakeGateway(messages: const []),
      hub: hub,
    );
    addTearDown(container.dispose);
    await _pumpReady(tester, container);
    expect(find.text('No messages yet'), findsOneWidget);

    hub.current.frame(1, {'type': 'agent_start'});
    await tester.pump();
    await tester.pump();

    // Web Transcript.svelte: working = running && !showsProgress(items).
    expect(
      find.text('Working'),
      findsOneWidget,
      reason: 'a running turn with no output yet must not read as a hang',
    );
    expect(find.text('No messages yet'), findsNothing);

    hub.current.frame(2, {'type': 'agent_end'});
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    expect(find.text('Working'), findsNothing);
  });

  testWidgets('the app bar accommodates the activity line without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final container = _container(
      gateway: FakeGateway(messages: _history(2)),
      hub: hub,
    );
    addTearDown(container.dispose);
    await _pumpReady(tester, container);
    expect(tester.takeException(), isNull);

    hub.current.frame(1, {'type': 'agent_start'});
    await tester.pump();
    await tester.pump();

    // Regression (finding 6): preferredSize ignored the AppBar bottom, so
    // Scaffold gave the bar 82dp while its internals wanted 104dp.
    expect(
      tester.takeException(),
      isNull,
      reason: 'no RenderFlex overflow with the activity line visible',
    );
    final header = tester.widget<SessionHeader>(find.byType(SessionHeader));
    expect(
      header.preferredSize.height,
      greaterThanOrEqualTo(kToolbarHeight + 24),
    );
    expect(find.byType(ActivityLine), findsOneWidget);

    hub.current.frame(2, {'type': 'agent_end'});
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
  });

  testWidgets('a 360dp header with a long model and a long connection '
      'message ellipsizes instead of overflowing', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final gateway = FakeGateway(messages: _history(2));
    // A long display model name for the metadata row.
    gateway.info = {
      'gwId': 'abc',
      'cwd': '/work/prompter',
      'model': {
        'id': 'z-ai/glm-5.3-flashx',
        'provider': 'z-ai',
        'name': 'GLM 5.3 FlashX Ultra Premium Extended Edition Model',
      },
    };
    final container = _container(gateway: gateway, hub: hub);
    addTearDown(container.dispose);
    await _pumpReady(tester, container);
    expect(find.textContaining('GLM 5.3 FlashX'), findsOneWidget);

    // Lockout close: the connection dot shows the long reason text.
    hub.current.serverClose(
      4429,
      'HTTP OK, but the WebSocket failed. Proxies can pass HTTP and break WS.',
    );
    await tester.pump();
    await tester.pump();

    expect(
      tester.takeException(),
      isNull,
      reason: 'the metadata row must ellipsize, not overflow at 360dp',
    );
    // The dot's text is constrained: maxLines 1 with ellipsis.
    final dotText = tester.widget<Text>(
      find.byWidgetPredicate(
        (w) => w is Text && (w.data?.contains('WebSocket failed') ?? false),
      ),
    );
    expect(dotText.overflow, TextOverflow.ellipsis);
    expect(dotText.maxLines, 1);

    // Clean up: unmount so the controller's stream timers are cancelled.
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: OmpTheme.data(OmpPreset.terminal)),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the activity ticker pauses when the app is hidden', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final container = _container(
      gateway: FakeGateway(messages: _history(2)),
      hub: hub,
    );
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    hub.current.frame(1, {'type': 'agent_start'});
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(ActivityLine), findsOneWidget);
    String elapsed() => tester
        .widget<Text>(
          find.descendant(
            of: find.byType(ActivityLine),
            matching: find.byType(Text),
          ),
        )
        .data!;
    int parseMs(String s) {
      final m = RegExp(r'(\d+) ms').firstMatch(s);
      if (m != null) return int.parse(m.group(1)!);
      final s2 = RegExp(r'(\d+) s').firstMatch(s);
      return s2 == null ? 0 : int.parse(s2.group(1)!) * 1000;
    }

    final beforeMs = parseMs(elapsed());

    // Background the app the way the platform does, then come back.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    // The ticker must be cancelled here: while the process sits paused the
    // fake clock below advances 5 s, and a live ticker would accumulate it.
    await tester.pump(const Duration(seconds: 5));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    await tester.pump(const Duration(seconds: 2));
    final afterMs = parseMs(elapsed());
    // Elapsed is wall-clock from turn start: a ticker that had kept running
    // through the paused window would read before + 5 s + 2 s; a paused one
    // only before + 2 s (plus scheduling slop).
    expect(
      afterMs,
      lessThan(beforeMs + 5000 + 2000),
      reason: 'the ticker did not run while the app was hidden/paused',
    );
    expect(
      afterMs,
      greaterThan(beforeMs),
      reason: 'the ticker resumes with the app',
    );

    hub.current.frame(2, {'type': 'agent_end'});
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
  });

  testWidgets('sending a message while scrolled up re-follows to the sent '
      'message', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final container = _container(
      gateway: FakeGateway(messages: _history(60)),
      hub: hub,
    );
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    await tester.drag(find.byType(ListView), const Offset(0, 1500));
    await tester.pumpAndSettle();
    expect(
      tester.widget<ListView>(find.byType(ListView)).controller!.offset,
      greaterThan(0),
    );

    // Web Transcript: "Sending always brings you back to the bottom."
    await tester.enterText(find.byType(TextField), 'hello from the top');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final controller = tester
        .widget<ListView>(find.byType(ListView))
        .controller!;
    expect(
      controller.offset,
      lessThanOrEqualTo(120.0),
      reason: 'sending re-follows to the bottom of the list',
    );
    expect(
      find.text('hello from the top'),
      findsOneWidget,
      reason: 'the sent message is on screen',
    );
    final sentRect = tester.getRect(find.text('hello from the top'));
    expect(
      sentRect.bottom,
      lessThanOrEqualTo(1600.0),
      reason: 'the sent message is fully visible',
    );
    expect(find.textContaining('Jump to latest'), findsNothing);
  });

  testWidgets('gone state renders a clear message', (tester) async {
    final hub = SocketHub();
    final container = _container(gateway: FakeGateway(status: 404), hub: hub);
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    expect(find.text('This session has ended'), findsOneWidget);
    expect(find.text('Back'), findsOneWidget);
  });

  testWidgets('error state offers a retry', (tester) async {
    final hub = SocketHub();
    final container = _container(gateway: FakeGateway(status: 500), hub: hub);
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    expect(find.text('Could not open this session'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('a blocking approval takes over the composer with Yes / No', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final gateway = FakeGateway(messages: _history(2));
    final container = _container(gateway: gateway, hub: hub);
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    // The controller applies pendingUi from info; a live extension_ui_request
    // exercises the stream path instead.
    hub.current.frame(1, {
      'type': 'extension_ui_request',
      'id': 'u1',
      'method': 'confirm',
      'title': 'Run command',
      'message': 'rm -rf build',
    });
    await tester.pump();
    await tester.pump();

    // The approval panel replaced the composer.
    expect(find.text('Run command'), findsOneWidget);
    expect(find.text('rm -rf build'), findsOneWidget);
    expect(find.text('Needs you'), findsOneWidget);
    expect(find.text('Yes'), findsOneWidget);
    expect(find.text('No'), findsOneWidget);
    expect(
      find.text('Message omp'),
      findsNothing,
      reason: 'the takeover replaces the composer entirely',
    );

    // Answering posts the answer and clears the panel.
    gateway.bodies.clear();
    await tester.tap(find.text('Yes'));
    await tester.pump();
    await tester.pump();
    expect(gateway.bodies['/api/sessions/abc/ui/u1'], {'confirmed': true});
  });
}
