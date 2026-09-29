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
import 'package:ohmypi/features/session/session_screen.dart';
import 'package:ohmypi/features/session/session_header.dart';
import 'package:ohmypi/state/connection_notifier.dart';
import 'package:ohmypi/state/connection_store.dart';
import 'package:ohmypi/state/session_controller.dart';
import 'package:ohmypi/state/sessions_store.dart';
import 'package:ohmypi/stream/scheduler.dart';
import 'package:ohmypi/stream/session_stream.dart';
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

  http.Client client() => MockClient((req) async {
        if (status != 200) {
          return _json({'error': 'nope'}, status: status);
        }
        if (req.url.path.endsWith('/messages')) {
          return _json({'messages': messages});
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
          baseUrl: 'https://g', token: 'tok', client: gateway.client()),
      baseUrl: 'https://g',
      token: 'tok',
      socketFactory: hub.factory,
      scheduler: const SystemScheduler());
  final container = ProviderContainer(overrides: [
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
  container.read(connectionNotifierProvider.notifier).state =
      ConnectionState(
          connections: const [
        ConnectionRecord(id: 'c1', url: 'https://g', label: 'G')
      ],
          activeId: 'c1');
  return container;
}

List<Map<String, Object?>> _history(int n) => [
      for (var i = 0; i < n; i++)
        {'role': 'user', 'content': 'message-$i', 'timestamp': 1700000000000 + i},
    ];

Future<void> _pumpReady(WidgetTester tester, ProviderContainer container,
    {String gwId = 'abc'}) async {
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: OmpTheme.data(OmpPreset.terminal),
      home: SessionScreen(gwId: gwId),
    ),
  ));
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
  testWidgets('a 200-item session opens at the newest item, never the top',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final container = _container(
        gateway: FakeGateway(messages: _history(200)), hub: hub);
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    expect(find.text('message-199'), findsOneWidget,
        reason: 'the newest item is on screen');
    expect(find.text('message-0'), findsNothing,
        reason: 'the first item is off screen: no stuck-at-top');
    final controller =
        tester.widget<ListView>(find.byType(ListView)).controller!;
    expect(controller.offset, 0, reason: 'offset 0 is the bottom (reverse)');
  });

  testWidgets('new content while at the bottom stays followed', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final container =
        _container(gateway: FakeGateway(messages: _history(50)), hub: hub);
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
    expect(find.text('Jump to latest'), findsNothing,
        reason: 'following at the bottom never shows the pill');
  });

  testWidgets('scrolled up: new content shows the pill and does not move the '
      'viewport; the pill returns to the bottom', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final container =
        _container(gateway: FakeGateway(messages: _history(60)), hub: hub);
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    // Reverse list: older items sit above, so reveal them with a downward
    // finger drag.
    await tester.drag(find.byType(ListView), const Offset(0, 1500));
    await tester.pumpAndSettle();
    final controller =
        tester.widget<ListView>(find.byType(ListView)).controller!;
    final offsetBefore = controller.offset;
    expect(offsetBefore, greaterThan(0));

    hub.current.frame(1, {
      'type': 'message_update',
      'message': {
        'role': 'user',
        'content': 'while away message',
        'timestamp': 1700000999999,
      },
    });
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('Jump to latest'), findsOneWidget);
    expect(controller.offset, offsetBefore,
        reason: 'reading position is never yanked down');

    await tester.tap(find.textContaining('Jump to latest'));
    await tester.pumpAndSettle();
    expect(controller.offset, 0);
    expect(find.text('while away message'), findsOneWidget);
  });

  testWidgets('agent_start shows the activity line; agent_end clears it',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final container =
        _container(gateway: FakeGateway(messages: _history(2)), hub: hub);
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    hub.current.frame(1, {'type': 'agent_start'});
    await tester.pump();
    await tester.pump();
    expect(container.read(sessionControllerProvider('abc')).activity,
        isNotNull);
    expect(find.byType(ActivityLine), findsOneWidget);

    hub.current.frame(2, {'type': 'agent_end'});
    // agent_end schedules a 600 ms stats refresh; let it fire so no timer is
    // left pending.
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    expect(container.read(sessionControllerProvider('abc')).activity, isNull);
    expect(find.byType(ActivityLine), findsNothing);
  });

  testWidgets('gone state renders a clear message', (tester) async {
    final hub = SocketHub();
    final container =
        _container(gateway: FakeGateway(status: 404), hub: hub);
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    expect(find.text('This session has ended'), findsOneWidget);
    expect(find.text('Back'), findsOneWidget);
  });

  testWidgets('error state offers a retry', (tester) async {
    final hub = SocketHub();
    final container =
        _container(gateway: FakeGateway(status: 500), hub: hub);
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    expect(find.text('Could not open this session'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('a pending approval renders the read-only banner', (tester) async {
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

    expect(find.text('Run command'), findsOneWidget);
    expect(find.text('rm -rf build'), findsOneWidget);
    expect(find.text('Approve and Deny arrive in the next build.'),
        findsOneWidget);
  });
}
