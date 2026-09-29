// Composer + approval panel widget tests. The controller runs against the
// shared fakes; no network. Covers: auto-grow, Enter = newline, durable send
// (text clears only after the ack), running shows Steer / Queue / Stop,
// slash menu filter + insert, drafts restored after a rebuild, and the
// approval takeover payloads.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ohmypi/api/client.dart';
import 'package:ohmypi/composer/drafts.dart';
import 'package:ohmypi/features/session/session_screen.dart';
import 'package:ohmypi/state/connection_notifier.dart';
import 'package:ohmypi/state/connection_store.dart';
import 'package:ohmypi/state/reviewed_store.dart';
import 'package:ohmypi/state/session_controller.dart';
import 'package:ohmypi/state/sessions_store.dart';
import 'package:ohmypi/stream/scheduler.dart';
import 'package:ohmypi/stream/session_stream.dart';
import 'package:ohmypi/theme/presets.dart';
import 'package:ohmypi/widgets/items/user_bubble.dart';

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
  FakeGateway({this.messages = const [], this.commands = const []});

  List<Object?> messages;
  List<Object?> commands;
  final Map<String, Object?> bodies = {};

  /// Paths that fail with 500.
  final Set<String> failPaths = {};

  /// Hold /prompt until completed (durable send test).
  Completer<void>? promptGate;

  /// How many /prompt calls were made.
  int promptCalls = 0;

  http.Client client() => MockClient((req) async {
        if (req.body.isNotEmpty) {
          final decoded = jsonDecode(req.body);
          if (decoded is Map<String, Object?>) bodies[req.url.path] = decoded;
        }
        if (failPaths.any(req.url.path.endsWith)) {
          return _json({'error': 'nope'}, status: 500);
        }
        if (req.url.path.endsWith('/prompt')) {
          promptCalls++;
          final gate = promptGate;
          if (gate != null) await gate.future;
          return _json({
            'gwId': 'abc',
            'cwd': '/work/x',
            'isStreaming': false,
            'lastEventSeq': 0,
          });
        }
        if (req.url.path.endsWith('/messages')) {
          return _json({'messages': messages});
        }
        if (req.url.path.endsWith('/state')) return _json({});
        if (req.url.path.endsWith('/stats')) return _json({'data': {}});
        if (req.url.path.endsWith('/commands')) {
          return _json({
            'data': {
              'commands': commands,
            }
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
  required FakeGateway gateway,
  required SocketHub hub,
  MemoryDraftKv? drafts,
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
    sessionsPollIntervalProvider.overrideWithValue(const Duration(hours: 1)),
    reviewedKvProvider.overrideWithValue(MemoryReviewedKv()),
    draftKvProvider.overrideWithValue(drafts ?? MemoryDraftKv()),
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

/// The composer's field. While running (or when a draft exists) the hint is
/// different, so match the first TextField instead.
Finder _composerField() {
  final byHint = find.widgetWithText(TextField, 'Message omp');
  return byHint.evaluate().isNotEmpty ? byHint : find.byType(TextField).first;
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(_composerField(), text);
  await tester.pump();
}

void main() {
  testWidgets('composer grows and Enter inserts a newline (touch)',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = _container(
        gateway: FakeGateway(), hub: SocketHub());
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    final field = tester.widget<TextField>(_composerField());
    expect(field.maxLines, 6, reason: 'grows up to ~6 lines then scrolls');
    expect(field.minLines, 1);
    expect(field.textInputAction, TextInputAction.newline,
        reason: 'on touch, Enter inserts a newline');

    await _type(tester, 'line one\nline two');
    final controller =
        tester.widget<TextField>(_composerField()).controller!;
    expect(controller.text, 'line one\nline two');
    expect(controller.text.split('\n'), ['line one', 'line two'],
        reason: 'Enter inserted a newline, both lines kept');
  });

  testWidgets('send clears the text only after the gateway acks',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final gateway = FakeGateway()..promptGate = Completer<void>();
    final container = _container(gateway: gateway, hub: SocketHub());
    addTearDown(container.dispose);
    final semantics = tester.ensureSemantics();
    await _pumpReady(tester, container);

    await _type(tester, 'durable words');
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();

    // No ack yet: the words stay in the field (durable send).
    expect(
        tester.widget<TextField>(_composerField()).controller!.text,
        'durable words');
    expect((gateway.bodies['/api/sessions/abc/prompt'] as Map)['message'],
        'durable words');

    gateway.promptGate!.complete();
    await tester.pump();
    await tester.pump();
    expect(tester.widget<TextField>(_composerField()).controller!.text, '',
        reason: 'the text clears only after the ack');
    semantics.dispose();
  });

  testWidgets('a failed send puts the words back and shows Retry on the '
      'failed bubble', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final gateway = FakeGateway()..failPaths.add('/prompt');
    final container = _container(gateway: gateway, hub: SocketHub());
    addTearDown(container.dispose);
    final semantics = tester.ensureSemantics();
    await _pumpReady(tester, container);

    await _type(tester, 'retry me');
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    await tester.pump();

    // The words are in the composer field AND on the failed bubble.
    expect(find.text('retry me'), findsNWidgets(2),
        reason: 'the words come back into the composer');
    expect(find.textContaining('Not sent'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget,
        reason: 'the failed bubble offers Retry');
    // Retry succeeds this time.
    gateway.failPaths.clear();
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();
    expect(gateway.promptCalls, 1,
        reason: 'the retry posted a fresh prompt');
    semantics.dispose();
  });

  testWidgets('running: the composer shows Steer, Queue and Stop',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = SocketHub();
    final gateway = FakeGateway();
    final container = _container(gateway: gateway, hub: hub);
    addTearDown(container.dispose);
    final semantics = tester.ensureSemantics();
    await _pumpReady(tester, container);

    expect(find.byIcon(Icons.send), findsNothing);
    hub.current.frame(1, {'type': 'agent_start'});
    await tester.pump();
    await tester.pump();

    expect(find.byIcon(Icons.send), findsOneWidget);
    expect(find.byIcon(Icons.low_priority), findsOneWidget);
    expect(find.byIcon(Icons.stop), findsOneWidget);
    expect(find.byIcon(Icons.arrow_upward), findsNothing,
        reason: 'while running the split action replaces the round send');

    // Steering posts mode steer.
    await _type(tester, 'try the other way');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    await tester.pump();
    expect((gateway.bodies['/api/sessions/abc/prompt'] as Map)['mode'],
        'steer');
    semantics.dispose();
  });

  testWidgets('slash menu filters and executes or inserts', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final gateway = FakeGateway(commands: [
      {'name': 'model', 'description': 'Pick a model', 'source': 'builtin'},
      {
        'name': 'deploy',
        'description': 'Deploy it',
        'source': 'extension',
        'input': {'hint': '<env>'}
      },
    ]);
    final container = _container(gateway: gateway, hub: SocketHub());
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    await _type(tester, '/mo');
    expect(find.text('/model'), findsOneWidget);
    expect(find.text('/deploy'), findsNothing,
        reason: 'the menu filters as you type');
    expect(find.text('COMMANDS'), findsOneWidget,
        reason: 'the menu groups by source');

    // A command that takes no input executes immediately.
    await tester.tap(find.text('/model'));
    await tester.pump();
    await tester.pump();
    expect((gateway.bodies['/api/sessions/abc/prompt'] as Map)['message'],
        '/model');

    // A command that wants arguments is inserted, not sent.
    await _type(tester, '/dep');
    await tester.tap(find.text('/deploy'));
    await tester.pump();
    expect(
        tester.widget<TextField>(_composerField()).controller!.text,
        '/deploy ',
        reason: 'selecting an input-taking command inserts the text');
  });

  testWidgets('a draft is restored after the composer is rebuilt',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final drafts = MemoryDraftKv();
    final container =
        _container(gateway: FakeGateway(), hub: SocketHub(), drafts: drafts);
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    await _type(tester, 'half-typed thought');
    // Let the debounced save (250ms) run.
    await tester.pump(const Duration(milliseconds: 400));

    // The provider is rebuilt from scratch (e.g. app restart): a fresh
    // container reading the same storage sees the draft.
    final fresh = _container(
        gateway: FakeGateway(), hub: SocketHub(), drafts: drafts);
    addTearDown(fresh.dispose);
    final semantics = tester.ensureSemantics();
    await _pumpReady(tester, fresh, gwId: 'abc');
    expect(
        tester.widget<TextField>(_composerField()).controller!.text,
        'half-typed thought',
        reason: 'the draft survives the rebuild');

    // A successful send clears the draft.
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    await tester.pump();
    expect(drafts.map.containsKey(draftKey('c1', 'abc')), isFalse,
        reason: 'a successful send clears the stored draft');
    // Let Riverpod's dispose timers flush before the test ends.
    await tester.pump(const Duration(minutes: 1));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(minutes: 1));
    semantics.dispose();
  });

  testWidgets('a double-tapped retry fires exactly one POST and keeps one '
      'bubble (controller-level guard)', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final gateway = FakeGateway()..failPaths.add('/prompt');
    final container = _container(gateway: gateway, hub: SocketHub());
    addTearDown(container.dispose);
    final semantics = tester.ensureSemantics();
    await _pumpReady(tester, container);

    await _type(tester, 'retry me');
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    await tester.pump();
    expect(find.text('Retry'), findsOneWidget);
    expect(gateway.promptCalls, 0,
        reason: 'the mock only counts prompts that reach the success branch; '
            'the failed send never gets there');

    // The retry goes through, but is held in flight by the fake gateway.
    gateway.failPaths.clear();
    gateway.promptGate = Completer<void>();
    // Two rapid taps: the second lands while the first is still in flight.
    await tester.tap(find.text('Retry'));
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();

    expect(gateway.promptCalls, 1,
        reason: 'exactly ONE retry POST despite the double tap');

    // The retry flips the SAME bubble back to pending: the Retry affordance
    // is gone (disabled/absent) while the retry is in flight.
    expect(find.text('Retry'), findsNothing,
        reason: 'the Retry button disables while the retry is in flight');

    // The ack arrives: the SAME bubble is now pending/sent, no second one,
    // and the failure note is gone.
    gateway.promptGate!.complete();
    await tester.pump();
    await tester.pump();
    expect(find.byType(UserBubble), findsOneWidget,
        reason: 'the failed bubble is reused, not duplicated');
    expect(find.textContaining('Not sent'), findsNothing);
    semantics.dispose();
  });

  testWidgets('an ack arriving after the composer unmounted still clears '
      'the draft', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final drafts = MemoryDraftKv();
    final gateway = FakeGateway()..promptGate = Completer<void>();
    final container =
        _container(gateway: gateway, hub: SocketHub(), drafts: drafts);
    addTearDown(container.dispose);
    final semantics = tester.ensureSemantics();
    await _pumpReady(tester, container);

    await _type(tester, 'gone before the ack');
    await tester.tap(find.byIcon(Icons.arrow_upward));
    // Let the debounced draft save (250ms) land while the send is gated.
    await tester.pump(const Duration(milliseconds: 400));
    expect(drafts.map.containsKey(draftKey('c1', 'abc')), isTrue);

    // Leave the session screen mid-send (the composer is disposed).
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: OmpTheme.data(OmpPreset.terminal)),
      ),
    );
    await tester.pump();

    // The ack arrives with nobody home: the draft must clear anyway.
    gateway.promptGate!.complete();
    await tester.pump();
    await tester.pump();
    expect(drafts.map.containsKey(draftKey('c1', 'abc')), isFalse,
        reason: 'the draft clear must not depend on the composer being '
            'mounted');

    // Reopening shows an empty composer: no accidental duplicate sends.
    await _pumpReady(tester, container);
    expect(
      tester.widget<TextField>(_composerField()).controller!.text,
      '',
      reason: 'the sent words must not come back as a draft',
    );
    semantics.dispose();
  });

  testWidgets('Escape dismisses the slash menu (hardware keyboard)',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final gateway = FakeGateway(commands: [
      {'name': 'model', 'description': 'Pick a model', 'source': 'builtin'},
    ]);
    final container = _container(gateway: gateway, hub: SocketHub());
    addTearDown(container.dispose);
    await _pumpReady(tester, container);

    await _type(tester, '/mo');
    expect(find.text('/model'), findsOneWidget,
        reason: 'the menu is open');

    // Web Composer.svelte: Escape sets dismissedFor = text.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('/model'), findsNothing,
        reason: 'Escape dismisses the menu');
    expect(
      tester.widget<TextField>(_composerField()).controller!.text,
      '/mo',
      reason: 'the text itself is untouched',
    );

    // Typing again re-opens the menu.
    await _type(tester, '/mod');
    expect(find.text('/model'), findsOneWidget);
  });

  testWidgets('the composer respects the bottom system inset with the '
      'keyboard down, and stays flush with the keyboard up',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = FakeViewPadding(bottom: 24);
    addTearDown(tester.view.reset);
    final container = _container(gateway: FakeGateway(), hub: SocketHub());
    addTearDown(container.dispose);
    await _pumpReady(tester, container);
    await _type(tester, 'hi');

    double sendBottom() =>
        tester.getBottomRight(find.byIcon(Icons.arrow_upward)).dy;

    // Keyboard down: the gesture-nav inset keeps the send button off the
    // system pill: 24dp inset + the composer's own 12dp bottom padding,
    // i.e. at most 640 - 24 - 12 = 604. (Pre-fix: 607, the button sits in
    // the gesture area.)
    expect(sendBottom(), lessThanOrEqualTo(604),
        reason: 'SafeArea(top:false) pads by the system inset');

    // Keyboard up: the inset collapses (the keyboard owns the bottom edge).
    tester.view.viewInsets = FakeViewPadding(bottom: 330);
    await tester.pump();
    expect(sendBottom(), lessThanOrEqualTo(640),
        reason: 'keyboard up: the composer stays flush, no double padding');
    expect(tester.takeException(), isNull);
  });
}
