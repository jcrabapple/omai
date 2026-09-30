// Approval panel tests (review round G, finding 9 + 1 + 7 + 12): the exact
// answer payload per request kind per API.md, buttons disabled while an
// answer is in flight and re-enabled on error, 409 drops silently, the
// '1 of N' counter, no layout overflow with the keyboard up (360x640 +
// 330dp inset) and long option labels wrap instead of ellipsizing.
// The controller runs against the shared fakes; no network, no live gateway.

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
import 'package:omai/state/sessions_store.dart';
import 'package:omai/stream/scheduler.dart';
import 'package:omai/stream/session_stream.dart' show StreamSocket;
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

  /// Hold the ui answer POST until completed (in-flight test).
  Completer<void>? answerGate;

  /// Status for the ui answer POST (0 = succeed).
  int answerStatus = 0;

  /// How many ui answer POSTs were made.
  int answerCalls = 0;

  /// Request bodies by path, for asserting answers.
  final Map<String, Object?> bodies = {};

  http.Client client() => MockClient((req) async {
        if (req.body.isNotEmpty) {
          final decoded = jsonDecode(req.body);
          if (decoded is Map<String, Object?>) bodies[req.url.path] = decoded;
        }
        if (req.url.path.contains('/ui/')) {
          answerCalls++;
          final gate = answerGate;
          if (gate != null) await gate.future;
          if (answerStatus != 0) {
            return _json({'error': 'nope'}, status: answerStatus);
          }
          return _json({});
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
        (ref) => (baseUrl, token) => GatewayClient(
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

int _seq = 0;

Future<void> _sendUiRequest(
  WidgetTester tester,
  SocketHub hub,
  Map<String, Object?> request,
) async {
  hub.current.frame(++_seq, {'type': 'extension_ui_request', ...request});
  await tester.pump();
  await tester.pump();
}

/// The FilledButton whose (only) visible label is [text].
FilledButton _button(WidgetTester tester, String text) =>
    tester.widget<FilledButton>(
      find.ancestor(
        of: find.text(text),
        matching: find.byType(FilledButton),
      ).first,
    );

void main() {
  testWidgets('select answers the exact payload {"value": "<option>"}',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final gateway = FakeGateway();
    final container = _container(gateway: gateway, hub: hub);
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    await _sendUiRequest(tester, hub, {
      'id': 'u1',
      'method': 'select',
      'title': 'Pick one',
      'options': ['Approve', 'Deny'],
    });
    expect(find.text('Approve'), findsOneWidget);

    await tester.tap(find.text('Approve'));
    await tester.pump();
    await tester.pump();
    expect(gateway.bodies['/api/sessions/abc/ui/u1'], {'value': 'Approve'});
  });

  testWidgets('confirm answers {"confirmed": bool}; cancel answers '
      '{"cancelled": true}', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final gateway = FakeGateway();
    final container = _container(gateway: gateway, hub: hub);
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    await _sendUiRequest(tester, hub, {
      'id': 'u1',
      'method': 'confirm',
      'title': 'Run command',
    });
    await tester.tap(find.text('No'));
    await tester.pump();
    await tester.pump();
    expect(gateway.bodies['/api/sessions/abc/ui/u1'], {'confirmed': false});

    await _sendUiRequest(tester, hub, {
      'id': 'u2',
      'method': 'confirm',
      'title': 'Run command',
    });
    await tester.tap(find.text('Dismiss (cancel this request)'));
    await tester.pump();
    await tester.pump();
    expect(gateway.bodies['/api/sessions/abc/ui/u2'], {'cancelled': true});
  });

  testWidgets('input answers {"value": <text>} from the button AND from the '
      'keyboard send action', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final gateway = FakeGateway();
    final container = _container(gateway: gateway, hub: hub);
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    await _sendUiRequest(tester, hub, {
      'id': 'u1',
      'method': 'input',
      'title': 'Answer',
    });
    await tester.enterText(find.byType(TextField), 'forty two');
    // Keyboard send action (finding 12): the input action answers, too.
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    await tester.pump();
    expect(gateway.bodies['/api/sessions/abc/ui/u1'], {'value': 'forty two'});
  });

  testWidgets('editor answers {"value": <text>} with the prefill', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final gateway = FakeGateway();
    final container = _container(gateway: gateway, hub: hub);
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    await _sendUiRequest(tester, hub, {
      'id': 'u1',
      'method': 'editor',
      'title': 'Edit file',
      'prefill': 'original contents',
    });
    expect(find.text('original contents'), findsOneWidget);
    await tester.tap(find.text('Send'));
    await tester.pump();
    await tester.pump();
    expect(gateway.bodies['/api/sessions/abc/ui/u1'],
        {'value': 'original contents'});
  });

  testWidgets('buttons disable while the answer is in flight; a non-409 '
      'error re-enables them and shows the message', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final gateway = FakeGateway()..answerGate = Completer<void>();
    final container = _container(gateway: gateway, hub: hub);
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    await _sendUiRequest(tester, hub, {
      'id': 'u1',
      'method': 'confirm',
      'title': 'Run command',
    });
    await tester.tap(find.text('Yes'));
    await tester.pump();
    await tester.pump();

    // In flight: everything disabled.
    expect(_button(tester, 'Yes').onPressed, isNull,
        reason: 'the approve button must not double-answer');
    expect(_button(tester, 'No').onPressed, isNull);
    expect(
      tester.widget<TextButton>(
        find.ancestor(
          of: find.text('Dismiss (cancel this request)'),
          matching: find.byType(TextButton),
        ).first,
      ).onPressed,
      isNull,
    );
    expect(gateway.answerCalls, 1);

    // A plain 500: the buttons come back and the error shows.
    gateway.answerStatus = 500;
    gateway.answerGate!.complete();
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('nope'), findsOneWidget);
    expect(_button(tester, 'Yes').onPressed, isNotNull);
    expect(_button(tester, 'No').onPressed, isNotNull);

    // Retry succeeds: the panel clears.
    gateway.answerStatus = 0;
    await tester.tap(find.text('Yes'));
    await tester.pump();
    await tester.pump();
    expect(gateway.answerCalls, 2);
    expect(find.text('Run command'), findsNothing);
  });

  testWidgets('a 409 drops the dialog silently', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final gateway = FakeGateway()..answerStatus = 409;
    final container = _container(gateway: gateway, hub: hub);
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    await _sendUiRequest(tester, hub, {
      'id': 'u1',
      'method': 'confirm',
      'title': 'Run command',
    });
    expect(find.text('Run command'), findsOneWidget);

    await tester.tap(find.text('Yes'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Run command'), findsNothing,
        reason: '409: someone else answered; drop without a word');
    expect(find.textContaining('nope'), findsNothing);
    expect(find.textContaining('Could not'), findsNothing);
  });

  testWidgets('queued dialogs show the "1 of N" counter', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final gateway = FakeGateway();
    final container = _container(gateway: gateway, hub: hub);
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    hub.current.frame(1, {
      'type': 'extension_ui_request',
      'id': 'u1',
      'method': 'confirm',
      'title': 'First question',
    });
    hub.current.frame(2, {
      'type': 'extension_ui_request',
      'id': 'u2',
      'method': 'confirm',
      'title': 'Second question',
    });
    await tester.pump();
    await tester.pump();

    expect(find.text('1 of 2'), findsOneWidget);
    expect(find.text('First question'), findsOneWidget,
        reason: 'only the first dialog is on screen');
    expect(find.text('Second question'), findsNothing);

    // Answering the first advances to the second.
    await tester.tap(find.text('Yes'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Second question'), findsOneWidget);
    expect(gateway.bodies['/api/sessions/abc/ui/u1'], {'confirmed': true});
  });

  testWidgets('360x640 with a 330dp keyboard: an editor request lays out '
      'without overflow and the Send button is reachable', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    tester.view.viewInsets = FakeViewPadding(bottom: 330);
    tester.view.padding = FakeViewPadding(bottom: 24);
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final gateway = FakeGateway();
    final container = _container(gateway: gateway, hub: hub);
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    final origOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      // Debug: dump the layout error's creator chain.
      // ignore: avoid_print
      print('LAYOUT_ERR:\n${details.toString()}');
      origOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = origOnError);

    await _sendUiRequest(tester, hub, {
      'id': 'u1',
      'method': 'editor',
      'title': 'git commit -m "a very long command line that would have '
          'blown past the panel\\nsecond line of the command"',
      'prefill': List.filled(40, 'word').join(' '),
    });

    final probe = tester.takeException();
    expect(probe, isNull,
        reason: 'no RenderFlex overflow with the keyboard up');

    // The Send action must be on screen inside the shrunken viewport and
    // tappable (buttons stay reachable above the keyboard).
    final sendFinder = find.text('Send');
    expect(sendFinder, findsOneWidget);
    final rect = tester.getRect(sendFinder);
    expect(rect.bottom, lessThanOrEqualTo(640),
        reason: 'the Send button must not be clipped below the keyboard');
    await tester.ensureVisible(sendFinder);
    gateway.bodies.clear();
    await tester.tap(sendFinder, warnIfMissed: false);
    await tester.pump();
    await tester.pump();
    expect(gateway.bodies['/api/sessions/abc/ui/u1'], isNotNull,
        reason: 'answering stays possible with the keyboard up');
  });

  testWidgets('long option labels wrap instead of ellipsizing and keep the '
      '48dp touch target', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final gateway = FakeGateway();
    final container = _container(gateway: gateway, hub: hub);
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    const longLabel = 'Allow read-only execution for this directory and '
        'every subdirectory of the project';
    await _sendUiRequest(tester, hub, {
      'id': 'u1',
      'method': 'select',
      'title': 'Permission',
      'options': [longLabel, 'Deny'],
    });

    final label = tester.widget<Text>(find.text(longLabel));
    expect(label.overflow, isNot(TextOverflow.ellipsis),
        reason: 'the full option text must be readable');
    expect(tester.takeException(), isNull);
    final button = tester.getSize(
      find.ancestor(
          of: find.text(longLabel), matching: find.byType(FilledButton)),
    );
    expect(button.height, greaterThanOrEqualTo(48.0),
        reason: 'the touch target stays at least 48dp tall');
  });
}
