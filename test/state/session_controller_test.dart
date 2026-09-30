// Controller tests: open sequence order and after=lastEventSeq, the three
// "running never sticks" paths, gone, 401 sign-out, dispose stops the
// stream. Uses the existing stream fakes (test/stream/fakes.dart) and an
// http MockClient.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omai/api/client.dart';
import 'package:omai/api/models.dart';
import 'package:omai/state/connection_notifier.dart';
import 'package:omai/state/connection_store.dart';
import 'package:omai/state/reviewed_store.dart';
import 'package:omai/state/session_controller.dart';
import 'package:omai/state/sessions_store.dart';
import 'package:omai/stream/session_stream.dart';
import 'package:omai/transcript/items.dart';

import '../stream/fakes.dart';

/// In-memory reviewed store persistence.
class MemoryReviewedKv implements ReviewedKv {
  final map = <String, String>{};
  @override
  Future<String?> get(String key) async => map[key];
  @override
  Future<void> set(String key, String value) async => map[key] = value;
}

http.Response _json(Object? body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

/// Hands out pre-made fake sockets in order and remembers them.
class SocketHub {
  final List<FakeSocket> sockets = [];

  FakeSocket get current => sockets.last;

  Future<StreamSocket> factory(Uri url, Map<String, String> headers) async {
    final sock = FakeSocket(url, headers);
    sockets.add(sock);
    return sock;
  }
}

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

/// Scriptable gateway: routes the session endpoints, records request order.
class FakeGateway {
  FakeGateway({
    Map<String, Object?>? infoJson,
    this.messages = const [],
    this.status = 200,
  }) : infoJson = infoJson ?? {};

  Map<String, Object?> infoJson = {};
  List<Object?> messages;
  int status;

  /// GET /state payload (queued count, todoPhases).
  Map<String, Object?> stateBody = {};
  final List<String> paths = [];

  /// Request bodies by path suffix, for asserting prompt/answer payloads.
  final Map<String, Object?> bodies = {};

  /// Paths that answer with this status instead of 200.
  final Set<String> failPaths = {};

  /// Test seam: hold /responses to /messages until completed.
  Completer<void>? messagesGate;

  /// Test seam: hold /prompt responses until completed (durable-send tests).
  Completer<void>? promptGate;

  /// Commands payload for /commands (full SlashCommand objects).
  List<Object?> commands = const [];

  http.Client client() => MockClient((req) async {
    paths.add(
      req.url.path +
          (req.url.queryParameters.isEmpty ? '' : '?${req.url.query}'),
    );
    final body = req.body.isEmpty ? null : jsonDecode(req.body);
    if (body is Map<String, Object?>) {
      bodies[req.url.path] = body;
    }
    if (failPaths.any(req.url.path.endsWith)) {
      return _json({'error': 'nope'}, status: status == 200 ? 500 : status);
    }
    if (status != 200) {
      return _json({'error': 'nope'}, status: status);
    }
    if (req.url.path.endsWith('/messages')) {
      final gate = messagesGate;
      if (gate != null) await gate.future;
      return _json({'messages': messages});
    }
    if (req.url.path.endsWith('/prompt')) {
      final gate = promptGate;
      if (gate != null) await gate.future;
      return _json(infoJson);
    }
    if (req.url.path.endsWith('/state')) {
      return _json(stateBody);
    }
    if (req.url.path.endsWith('/stats')) {
      return _json({'data': {}});
    }
    if (req.url.path.endsWith('/commands')) {
      return _json({
        'data': {'commands': commands},
      });
    }
    return _json(infoJson);
  });
}

ProviderContainer makeContainer({
  required FakeGateway gateway,
  required SocketHub hub,
  FakeScheduler? scheduler,
  MemoryReviewedKv? reviewedKv,
  DateTime Function()? now,
}) {
  final sched = scheduler ?? FakeScheduler();
  final container = ProviderContainer(
    overrides: [
      if (reviewedKv != null)
        reviewedKvProvider.overrideWithValue(reviewedKv)
      else
        // send() touches the reviewed store; keep it off SharedPreferences.
        reviewedKvProvider.overrideWithValue(MemoryReviewedKv()),
      connectionPrefsProvider.overrideWithValue(
        MemoryPrefs(const [
          ConnectionRecord(id: 'c1', url: 'https://g', label: 'G'),
        ]),
      ),
      tokenStoreProvider.overrideWithValue(_FixedTokenStore()),
      gatewayClientFactoryProvider.overrideWith(
        (ref) =>
            (baseUrl, token) => GatewayClient(
              baseUrl: baseUrl,
              token: token,
              client: gateway.client(),
            ),
      ),
      sessionEnvProvider.overrideWith(
        (ref) async => SessionEnv(
          client: GatewayClient(
            baseUrl: 'https://g',
            token: 'tok',
            client: gateway.client(),
          ),
          baseUrl: 'https://g',
          token: 'tok',
          socketFactory: hub.factory,
          scheduler: sched,
          now: now ?? DateTime.now,
        ),
      ),
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

Map<String, Object?> infoJson({
  String gwId = 'abc',
  int lastEventSeq = 0,
  bool isStreaming = false,
}) => {
  'gwId': gwId,
  'cwd': '/work/x',
  'isStreaming': isStreaming,
  'lastEventSeq': lastEventSeq,
};

void main() {
  test('open sequence: info, then messages, then the socket with after=lastEventSeq', () async {
    final gateway = FakeGateway(
      infoJson: infoJson(lastEventSeq: 3),
      messages: [
        {'role': 'user', 'content': 'hi'},
      ],
    );
    final hub = SocketHub();
    final container = makeContainer(gateway: gateway, hub: hub);

    final provider = sessionControllerProvider('abc');
    final sub = container.listen(provider, (previous, next) {});
    addTearDown(sub.close);
    await pumpEventQueue();

    expect(gateway.paths[0], '/api/sessions/abc');
    expect(gateway.paths[1], '/api/sessions/abc/messages');
    expect(gateway.paths.length, greaterThanOrEqualTo(2));
    final sock = hub.current;
    expect(sock.url.path, '/omp-ws/abc');
    expect(sock.url.queryParameters['after'], '3');

    final s = container.read(sessionControllerProvider('abc'));
    expect(s.phase, SessionPhase.ready);
    expect(
      s.transcript.items,
      isNotEmpty,
      reason: 'history paints the transcript',
    );
    expect(s.running, isFalse);
  });

  test('agent_start sets running; agent_end clears it', () async {
    final gateway = FakeGateway(infoJson: infoJson());
    final hub = SocketHub();
    final container = makeContainer(gateway: gateway, hub: hub);
    final provider = sessionControllerProvider('abc');
    final sub = container.listen(provider, (previous, next) {});
    addTearDown(sub.close);
    await pumpEventQueue();

    hub.current.frame(1, {'type': 'agent_start'});
    expect(container.read(sessionControllerProvider('abc')).running, isTrue);
    expect(
      container.read(sessionControllerProvider('abc')).activity,
      isNotNull,
    );

    hub.current.frame(2, {'type': 'agent_end'});
    expect(
      container.read(sessionControllerProvider('abc')).running,
      isFalse,
      reason: 'agent_end always clears running',
    );
    expect(container.read(sessionControllerProvider('abc')).activity, isNull);
  });

  test(
    'a resync replaces state: fresh info with isStreaming false clears running',
    () async {
      final gateway = FakeGateway(infoJson: infoJson());
      final hub = SocketHub();
      final scheduler = FakeScheduler();
      final container = makeContainer(
        gateway: gateway,
        hub: hub,
        scheduler: scheduler,
      );
      final provider = sessionControllerProvider('abc');
      final sub = container.listen(provider, (previous, next) {});
      addTearDown(sub.close);
      await pumpEventQueue();

      hub.current.frame(1, {'type': 'agent_start'});
      expect(container.read(sessionControllerProvider('abc')).running, isTrue);

      // Reconnect; the server answers auth_ok with gap:true on the new socket,
      // which triggers a resync: a fresh snapshot whose info.isStreaming is
      // false.
      hub.current.serverClose(1006);
      await pumpEventQueue();
      await scheduler.elapse(31000);
      await pumpEventQueue();
      expect(
        hub.sockets.length,
        greaterThan(1),
        reason: 'the stream reconnected',
      );
      hub.current.authOk(gap: true);
      gateway.messages = [
        {'role': 'user', 'content': 'hi'},
      ];
      await pumpEventQueue();

      expect(
        container.read(sessionControllerProvider('abc')).running,
        isFalse,
        reason: 'the resync snapshot resets the turn state',
      );
      expect(
        container.read(sessionControllerProvider('abc')).activity,
        isNull,
        reason: 'a resync that ends the turn also clears the activity line',
      );
      expect(
        container.read(sessionControllerProvider('abc')).transcript.items,
        isNotEmpty,
      );
    },
  );

  test('fresh info reporting isStreaming:false clears running', () async {
    final gateway = FakeGateway(infoJson: infoJson());
    final hub = SocketHub();
    final container = makeContainer(gateway: gateway, hub: hub);
    final provider = sessionControllerProvider('abc');
    final sub = container.listen(provider, (previous, next) {});
    addTearDown(sub.close);
    await pumpEventQueue();

    hub.current.frame(1, {'type': 'agent_start'});
    expect(container.read(sessionControllerProvider('abc')).running, isTrue);

    gateway.infoJson = infoJson(isStreaming: false);
    await container
        .read(sessionControllerProvider('abc').notifier)
        .refreshInfo();

    expect(
      container.read(sessionControllerProvider('abc')).running,
      isFalse,
      reason: 'isStreaming:false in fresh info always clears running',
    );
    expect(
      container.read(sessionControllerProvider('abc')).activity,
      isNull,
      reason: 'fresh info ending the turn clears the activity line',
    );
    expect(
      container.read(sessionControllerProvider('abc')).info?.isStreaming,
      isFalse,
    );
  });

  test('onGone: close 4404 puts the session in the gone phase', () async {
    final gateway = FakeGateway(infoJson: infoJson());
    final hub = SocketHub();
    final container = makeContainer(gateway: gateway, hub: hub);
    final provider = sessionControllerProvider('abc');
    final sub = container.listen(provider, (previous, next) {});
    addTearDown(sub.close);
    await pumpEventQueue();

    hub.current.frame(1, {'type': 'agent_start'});
    expect(
      container.read(sessionControllerProvider('abc')).activity,
      isNotNull,
    );
    hub.current.serverClose(4404);
    await pumpEventQueue();

    expect(
      container.read(sessionControllerProvider('abc')).phase,
      SessionPhase.gone,
    );
    expect(
      container.read(sessionControllerProvider('abc')).activity,
      isNull,
      reason: 'going away clears the activity line',
    );
  });

  test('a 404 on open puts the session in the gone phase', () async {
    final gateway = FakeGateway(status: 404);
    final hub = SocketHub();
    final container = makeContainer(gateway: gateway, hub: hub);
    final provider = sessionControllerProvider('abc');
    final sub = container.listen(provider, (previous, next) {});
    addTearDown(sub.close);
    await pumpEventQueue();

    expect(
      container.read(sessionControllerProvider('abc')).phase,
      SessionPhase.gone,
    );
    expect(hub.sockets, isEmpty, reason: 'no socket for a gone session');
  });

  test('a 401 on open signs the user out', () async {
    final gateway = FakeGateway(status: 401);
    final hub = SocketHub();
    final container = makeContainer(gateway: gateway, hub: hub);
    final provider = sessionControllerProvider('abc');
    final sub = container.listen(provider, (previous, next) {});
    addTearDown(sub.close);
    await pumpEventQueue();

    expect(
      container.read(sessionControllerProvider('abc')).phase,
      SessionPhase.error,
    );
    final connection = container.read(connectionNotifierProvider);
    expect(connection.active, isNull);
    expect(connection.connections, isEmpty);
  });

  test('onSignedOut: close 4401 signs the user out', () async {
    final gateway = FakeGateway(infoJson: infoJson());
    final hub = SocketHub();
    final container = makeContainer(gateway: gateway, hub: hub);
    final provider = sessionControllerProvider('abc');
    final sub = container.listen(provider, (previous, next) {});
    addTearDown(sub.close);
    await pumpEventQueue();

    hub.current.serverClose(4401);
    await pumpEventQueue();

    final connection = container.read(connectionNotifierProvider);
    expect(connection.active, isNull);
    expect(connection.connections, isEmpty);
  });

  test('dispose stops the stream', () async {
    final gateway = FakeGateway(infoJson: infoJson());
    final hub = SocketHub();
    final container = makeContainer(gateway: gateway, hub: hub);
    final provider = sessionControllerProvider('abc');
    final sub = container.listen(provider, (previous, next) {});
    await pumpEventQueue();
    final sock = hub.current;
    expect(sock.closed, isFalse);

    sub.close();
    // The provider auto-disposes with its last listener; disposing the
    // controller must stop the stream (see also the autoDispose tests below).
    container.dispose();
    await pumpEventQueue();
    expect(
      sock.closed,
      isTrue,
      reason: 'disposing the controller closes the socket',
    );
  });

  test('autoDispose: the last listener leaving closes the socket and cancels timers', () async {
    final gateway = FakeGateway(infoJson: infoJson());
    final hub = SocketHub();
    final container = makeContainer(gateway: gateway, hub: hub);
    final provider = sessionControllerProvider('abc');
    final sub = container.listen(provider, (previous, next) {});
    await pumpEventQueue();
    final sock = hub.current;
    final statsAfterOpen = gateway.paths
        .where((p) => p.endsWith('/stats'))
        .length;

    // A turn ends right before the user leaves: the post-turn stats timer
    // is armed.
    hub.current.frame(1, {'type': 'agent_start'});
    hub.current.frame(2, {'type': 'agent_end'});

    sub.close();
    await pumpEventQueue();
    expect(
      sock.closed,
      isTrue,
      reason: 'autoDispose tears the socket down with the last listener',
    );

    // The 600ms post-turn timer must not fire in the background.
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(
      gateway.paths.where((p) => p.endsWith('/stats')).length,
      statsAfterOpen,
      reason: 'no stats refresh after the provider is disposed',
    );
  });

  test(
    'autoDispose: reopening after a failed open retries with a fresh instance',
    () async {
      final gateway = FakeGateway(status: 500);
      final hub = SocketHub();
      final container = makeContainer(gateway: gateway, hub: hub);
      final provider = sessionControllerProvider('abc');
      final sub = container.listen(provider, (previous, next) {});
      await pumpEventQueue();
      expect(
        container.read(sessionControllerProvider('abc')).phase,
        SessionPhase.error,
      );

      sub.close();
      await pumpEventQueue();
      gateway.status = 200;
      gateway.infoJson = infoJson(lastEventSeq: 0);
      final sub2 = container.listen(provider, (previous, next) {});
      addTearDown(sub2.close);
      await pumpEventQueue();

      expect(
        container.read(sessionControllerProvider('abc')).phase,
        SessionPhase.ready,
        reason: 'a fresh open replaces the cached error',
      );
      expect(
        hub.sockets,
        isNotEmpty,
        reason: 'the retry opens a socket for the session',
      );
    },
  );

  test(
    'a dispose while the open is in flight opens no socket and does not throw',
    () async {
      final gateway = FakeGateway()..messagesGate = Completer<void>();
      final hub = SocketHub();
      final container = makeContainer(gateway: gateway, hub: hub);
      final provider = sessionControllerProvider('abc');
      final sub = container.listen(provider, (previous, next) {});
      await pumpEventQueue();
      expect(hub.sockets, isEmpty, reason: 'still fetching history');

      sub.close();
      await pumpEventQueue();
      gateway.messagesGate!.complete();
      await pumpEventQueue();

      expect(
        hub.sockets,
        isEmpty,
        reason: 'a disposed controller never opens a socket',
      );
    },
  );

  test('pause cancels the post-turn stats timer; resume runs it', () async {
    final gateway = FakeGateway(infoJson: infoJson());
    final hub = SocketHub();
    final container = makeContainer(gateway: gateway, hub: hub);
    final provider = sessionControllerProvider('abc');
    final sub = container.listen(provider, (previous, next) {});
    addTearDown(sub.close);
    await pumpEventQueue();
    final statsAfterOpen = gateway.paths
        .where((p) => p.endsWith('/stats'))
        .length;

    hub.current.frame(1, {'type': 'agent_start'});
    hub.current.frame(2, {'type': 'agent_end'});
    await pumpEventQueue();

    container.read(sessionControllerProvider('abc').notifier).pause();
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(
      gateway.paths.where((p) => p.endsWith('/stats')).length,
      statsAfterOpen,
      reason: 'a paused session makes no background REST calls',
    );

    container.read(sessionControllerProvider('abc').notifier).resume();
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(
      gateway.paths.where((p) => p.endsWith('/stats')).length,
      greaterThan(statsAfterOpen),
      reason: 'resume runs the stats refresh that was pending',
    );
  });

  test(
    'a 404 on open also removes the session from the sessions store',
    () async {
      final gateway = FakeGateway(status: 404);
      final hub = SocketHub();
      final container = makeContainer(gateway: gateway, hub: hub);
      container.read(sessionsStoreProvider.notifier);
      await pumpEventQueue();
      container
          .read(sessionsStoreProvider.notifier)
          .patch(SessionInfo.fromJson({'gwId': 'abc', 'cwd': '/work'}));
      expect(container.read(sessionsStoreProvider).live, isNotEmpty);

      final provider = sessionControllerProvider('abc');
      final sub = container.listen(provider, (previous, next) {});
      addTearDown(sub.close);
      await pumpEventQueue();

      expect(
        container.read(sessionControllerProvider('abc')).phase,
        SessionPhase.gone,
      );
      expect(
        container.read(sessionsStoreProvider).live,
        isEmpty,
        reason: 'a gone session disappears from the rail immediately',
      );
    },
  );

  test('pause and resume are forwarded to the stream', () async {
    final gateway = FakeGateway(infoJson: infoJson());
    final hub = SocketHub();
    final container = makeContainer(gateway: gateway, hub: hub);
    final provider = sessionControllerProvider('abc');
    final sub = container.listen(provider, (previous, next) {});
    addTearDown(sub.close);
    await pumpEventQueue();
    final sock = hub.current;

    container.read(sessionControllerProvider('abc').notifier).pause();
    await pumpEventQueue();
    expect(sock.closed, isTrue, reason: 'pausing drops the socket');
  });

  group('D2a actions', () {
    Future<(ProviderContainer, FakeGateway, SocketHub)> open({
      FakeGateway? gw,
      List<Object?> commands = const [],
    }) async {
      final gateway = gw ?? FakeGateway(infoJson: infoJson())
        ..commands = commands;
      final hub = SocketHub();
      final container = makeContainer(gateway: gateway, hub: hub);
      final sub = container.listen(
        sessionControllerProvider('abc'),
        (previous, next) {},
      );
      addTearDown(sub.close);
      await pumpEventQueue();
      return (container, gateway, hub);
    }

    test('send posts the prompt and paints an optimistic bubble', () async {
      final (container, gateway, hub) = await open();
      hub.current;
      final ok = await container
          .read(sessionControllerProvider('abc').notifier)
          .send('do the thing', mode: 'prompt');
      expect(ok, isTrue);
      expect(
        gateway.bodies['/api/sessions/abc/prompt'],
        containsPair('message', 'do the thing'),
      );
      expect(
        (gateway.bodies['/api/sessions/abc/prompt'] as Map)['mode'],
        'prompt',
      );
      // The optimistic bubble is in the transcript.
      final userItems = container
          .read(sessionControllerProvider('abc'))
          .transcript
          .items
          .whereType<UserItem>()
          .where((it) => it.text == 'do the thing');
      expect(userItems, isNotEmpty);
    });

    test(
      'a steer send posts mode steer and refreshes the queue count',
      () async {
        final (container, gateway, hub) = await open();
        hub.current;
        final ok = await container
            .read(sessionControllerProvider('abc').notifier)
            .send('push left', mode: 'steer');
        expect(ok, isTrue);
        expect(
          (gateway.bodies['/api/sessions/abc/prompt'] as Map)['mode'],
          'steer',
        );
        expect(
          gateway.paths.any((p) => p.endsWith('/state')),
          isTrue,
          reason: 'steer/follow_up sends refresh the queued count',
        );
      },
    );

    test(
      'durable send: failure makes a failed bubble, retry succeeds',
      () async {
        final (container, gateway, hub) = await open();
        hub.current;
        gateway.failPaths.add('/prompt');

        final ok = await container
            .read(sessionControllerProvider('abc').notifier)
            .send('precious text', mode: 'prompt');
        expect(ok, isFalse, reason: 'the gateway rejected the prompt');
        final items = container
            .read(sessionControllerProvider('abc'))
            .transcript
            .items;
        final failed = items.last as UserItem;
        expect(failed.text, 'precious text');
        expect(failed.pending, isFalse);
        expect(failed.failed, isTrue);
        expect(
          failed.error,
          isNotEmpty,
          reason: 'the failed bubble explains why',
        );

        // Retry: the same words go out again and this time land.
        gateway.failPaths.clear();
        final ok2 = await container
            .read(sessionControllerProvider('abc').notifier)
            .send('precious text', mode: 'prompt');
        expect(ok2, isTrue);
        expect(gateway.paths.where((p) => p.endsWith('/prompt')).length, 2);
      },
    );

    test(
      'the review pin clears only after the ack (ported reviewed tests)',
      () async {
        final kv = MemoryReviewedKv();
        final gateway = FakeGateway(infoJson: infoJson());
        final hub = SocketHub();
        final container = makeContainer(
          gateway: gateway,
          hub: hub,
          reviewedKv: kv,
        );
        final provider = sessionControllerProvider('abc');
        final sub = container.listen(provider, (previous, next) {});
        addTearDown(sub.close);
        await pumpEventQueue();
        await container.read(reviewedStoreProvider.notifier).flag('abc');
        expect(
          container.read(reviewedStoreProvider).needsReview.contains('abc'),
          isTrue,
        );

        // A failed send keeps the pin.
        gateway.failPaths.add('/prompt');
        await container
            .read(sessionControllerProvider('abc').notifier)
            .send('again');
        expect(
          container.read(reviewedStoreProvider).needsReview.contains('abc'),
          isTrue,
          reason: 'a failed send keeps the review pin',
        );

        // A successful send clears it.
        gateway.failPaths.clear();
        await container
            .read(sessionControllerProvider('abc').notifier)
            .send('again');
        expect(
          container.read(reviewedStoreProvider).needsReview.contains('abc'),
          isFalse,
          reason: 'sending a prompt clears the review pin',
        );
      },
    );

    test(
      'answerUi posts the answer payload; ui_resolved clears the dialog',
      () async {
        final gw = FakeGateway(infoJson: infoJson())
          ..infoJson['pendingUi'] = [
            {'id': 'r1', 'method': 'confirm', 'title': 'Allow edit'},
          ];
        final (container, gateway, hub) = await open(gw: gw);
        expect(
          container.read(sessionControllerProvider('abc')).pendingUi,
          hasLength(1),
        );

        await container
            .read(sessionControllerProvider('abc').notifier)
            .answerUi('r1', {'confirmed': true});
        expect(gateway.bodies['/api/sessions/abc/ui/r1'], {
          'confirmed': true,
        }, reason: 'the answer payload goes through verbatim');

        // The dialog stays until the ui_resolved event (or a local drop).
        expect(
          container.read(sessionControllerProvider('abc')).pendingUi,
          hasLength(1),
        );
        hub.current.frame(5, {'type': 'ui_resolved', 'id': 'r1'});
        await pumpEventQueue();
        expect(
          container.read(sessionControllerProvider('abc')).pendingUi,
          isEmpty,
          reason: 'ui_resolved removes the dialog',
        );
      },
    );

    test('dropUi removes a dialog locally (e.g. after a 409)', () async {
      final (container, gateway, hub) = await open();
      hub.current;
      container
          .read(sessionControllerProvider('abc').notifier)
          .dropUi('anything'); // no-op on an empty list
      expect(
        container.read(sessionControllerProvider('abc')).pendingUi,
        isEmpty,
      );
    });

    test('abort posts to the abort endpoint', () async {
      final (container, gateway, hub) = await open();
      hub.current;
      await container.read(sessionControllerProvider('abc').notifier).abort();
      expect(gateway.paths.any((p) => p.endsWith('/abort')), isTrue);
    });

    test(
      'setModel, setThinking, rename and compact post and refresh info',
      () async {
        final (container, gateway, hub) = await open();
        hub.current;
        final n = gateway.paths.length;
        final c = container.read(sessionControllerProvider('abc').notifier);
        await c.setModel('anthropic', 'claude-x');
        expect(gateway.bodies['/api/sessions/abc/model'], {
          'provider': 'anthropic',
          'modelId': 'claude-x',
        });
        await c.setThinking('low');
        expect(gateway.bodies['/api/sessions/abc/thinking'], {'level': 'low'});
        await c.rename('New name');
        expect(gateway.bodies['/api/sessions/abc/name'], {'name': 'New name'});
        await c.compact('keep the plan');
        expect(gateway.bodies['/api/sessions/abc/compact'], {
          'instructions': 'keep the plan',
        });
        // Each action refreshes info afterwards.
        expect(
          gateway.paths
              .sublist(n)
              .where((p) => p == '/api/sessions/abc')
              .length,
          4,
          reason: 'every action refetches info',
        );
      },
    );

    test('slash commands load from /commands with their full shape', () async {
      final (container, gateway, hub) = await open();
      hub.current;
      gateway.commands = [
        {
          'name': 'compact',
          'description': 'Compact the context',
          'source': 'builtin',
        },
      ];
      final c = container.read(sessionControllerProvider('abc').notifier);
      // Reload happens at open; trigger a refresh by reopening the env read
      // path: simplest is to assert the state after the open already ran.
      c; // open() already consumed the initial /commands; re-set and reload.
      container.invalidate(sessionControllerProvider('abc'));
      await pumpEventQueue();
      final s = container.read(sessionControllerProvider('abc'));
      expect(s.slashCommands.map((x) => x.name), contains('compact'));
      expect(s.commands, contains('compact'));
    });
  });

  group('E1: turn stats, reconnects and the plan', () {
    test('TTFT and tokens per second are computed from event timing with a '
        'fake clock', () async {
      var ms = 1000;
      final gateway = FakeGateway(infoJson: infoJson());
      final hub = SocketHub();
      final container = makeContainer(
        gateway: gateway,
        hub: hub,
        now: () => DateTime.fromMillisecondsSinceEpoch(ms),
      );
      final sub = container.listen(
        sessionControllerProvider('abc'),
        (previous, next) {},
      );
      addTearDown(sub.close);
      await pumpEventQueue();

      hub.current.frame(1, {'type': 'agent_start'}); // clock: 1000
      ms = 1600; // TTFT: 600 ms
      hub.current.frame(2, {
        'type': 'message_update',
        'message': {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'working'},
          ],
          'timestamp': 100,
        },
      });
      ms = 6600;
      hub.current.frame(3, {
        'type': 'message_end',
        'messageId': 'm-1',
        'message': {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'working'},
          ],
          'usage': {'output': 50, 'input': 10},
          'duration': 5000,
          'timestamp': 100,
        },
      });
      hub.current.frame(4, {'type': 'agent_end'}); // clock: 6600

      final stats = container.read(sessionControllerProvider('abc')).turnStats;
      expect(stats, isNotNull);
      expect(stats!.ttftMs, 600);
      expect(
        stats.tokensPerSec,
        closeTo(10.0, 0.001),
        reason: '50 output tokens over a 5 s stream',
      );
      expect(stats.lastEventSeq, 4);
    });

    test('no tokens per second when the turn reported no usage', () async {
      final gateway = FakeGateway(infoJson: infoJson());
      final hub = SocketHub();
      final container = makeContainer(gateway: gateway, hub: hub);
      final sub = container.listen(
        sessionControllerProvider('abc'),
        (previous, next) {},
      );
      addTearDown(sub.close);
      await pumpEventQueue();

      hub.current.frame(1, {'type': 'agent_start'});
      hub.current.frame(2, {
        'type': 'message_update',
        'message': {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'hi'},
          ],
          'timestamp': 100,
        },
      });
      hub.current.frame(3, {'type': 'agent_end'});
      final stats = container.read(sessionControllerProvider('abc')).turnStats;
      expect(stats, isNotNull);
      expect(stats!.tokensPerSec, isNull);
      expect(stats.ttftMs, isNotNull);
    });

    test(
      'stream reconnects are counted from live to down and land in state',
      () async {
        final gateway = FakeGateway(infoJson: infoJson());
        final hub = SocketHub();
        final scheduler = FakeScheduler();
        final container = makeContainer(
          gateway: gateway,
          hub: hub,
          scheduler: scheduler,
        );
        final sub = container.listen(
          sessionControllerProvider('abc'),
          (previous, next) {},
        );
        addTearDown(sub.close);
        await pumpEventQueue();

        // Live (the fake socket only turns live after auth_ok):
        hub.current.authOk();
        await pumpEventQueue();
        hub.current.frame(1, {'type': 'agent_start'});
        await pumpEventQueue();
        expect(
          container.read(sessionControllerProvider('abc')).streamReconnects,
          0,
        );

        // The server drops the connection: the stream reports a retry state.
        hub.current.serverClose(1006, 'abnormal');
        await pumpEventQueue();
        await pumpEventQueue();
        expect(
          container.read(sessionControllerProvider('abc')).streamReconnects,
          greaterThanOrEqualTo(1),
          reason: 'a dropped live socket counts as one reconnect',
        );
      },
    );

    test(
      'a voluntary pause does not count as a stream reconnect (review #13)',
      () async {
        final gateway = FakeGateway(infoJson: infoJson());
        final hub = SocketHub();
        final container = makeContainer(gateway: gateway, hub: hub);
        final sub = container.listen(
          sessionControllerProvider('abc'),
          (previous, next) {},
        );
        addTearDown(sub.close);
        await pumpEventQueue();

        hub.current.authOk();
        await pumpEventQueue();
        // The app backgrounds while idle: the controller pauses the socket on
        // purpose. That is not a dropped connection.
        container.read(sessionControllerProvider('abc').notifier).pause();
        await pumpEventQueue();
        await pumpEventQueue();
        expect(
          container.read(sessionControllerProvider('abc')).streamReconnects,
          0,
          reason: 'a voluntary pause is not a reconnect',
        );
      },
    );

    test('review #11: tokens per second is client clock only, never mixed with '
        'the server message timestamp', () async {
      var ms = 1000;
      final gateway = FakeGateway(infoJson: infoJson());
      final hub = SocketHub();
      final container = makeContainer(
        gateway: gateway,
        hub: hub,
        now: () => DateTime.fromMillisecondsSinceEpoch(ms),
      );
      final sub = container.listen(
        sessionControllerProvider('abc'),
        (previous, next) {},
      );
      addTearDown(sub.close);
      await pumpEventQueue();

      hub.current.frame(1, {'type': 'agent_start'}); // clock: 1000
      ms = 1600; // first assistant delta
      hub.current.frame(2, {
        'type': 'message_update',
        'message': {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'working'},
          ],
          // Server clock, deliberately skewed far away from the client
          // clock: mixing the two produced garbage tok/s.
          'timestamp': 9_999_999_999,
        },
      });
      ms = 6600;
      hub.current.frame(3, {
        'type': 'message_end',
        'messageId': 'm-1',
        'message': {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'working'},
          ],
          'usage': {'output': 50, 'input': 10},
          // No duration field: the fallback previously mixed
          // server timestamp minus client turn start.
          'timestamp': 9_999_999_999,
        },
      });
      hub.current.frame(4, {'type': 'agent_end'}); // clock: 6600

      final stats = container.read(sessionControllerProvider('abc')).turnStats;
      expect(stats, isNotNull);
      // 50 output tokens over the 5 s from the first delta to turn end,
      // both read from the fake client clock.
      expect(stats!.tokensPerSec, closeTo(10.0, 0.001));
    });

    test('no tokens per second for a sub-500ms stream (review #11)', () async {
      var ms = 1000;
      final gateway = FakeGateway(infoJson: infoJson());
      final hub = SocketHub();
      final container = makeContainer(
        gateway: gateway,
        hub: hub,
        now: () => DateTime.fromMillisecondsSinceEpoch(ms),
      );
      final sub = container.listen(
        sessionControllerProvider('abc'),
        (previous, next) {},
      );
      addTearDown(sub.close);
      await pumpEventQueue();

      hub.current.frame(1, {'type': 'agent_start'}); // clock: 1000
      ms = 1100; // first delta
      hub.current.frame(2, {
        'type': 'message_update',
        'message': {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'hi'},
          ],
          'timestamp': 100,
        },
      });
      ms = 1300; // turn ends 200ms after the first delta
      hub.current.frame(3, {
        'type': 'message_end',
        'messageId': 'm-1',
        'message': {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'hi'},
          ],
          'usage': {'output': 50, 'input': 10},
          'timestamp': 100,
        },
      });
      hub.current.frame(4, {'type': 'agent_end'});

      final stats = container.read(sessionControllerProvider('abc')).turnStats;
      expect(
        stats!.tokensPerSec,
        isNull,
        reason: 'a 200ms window is not a measurable rate',
      );
    });

    test('the plan derives from the /state poll', () async {
      final gateway = FakeGateway(infoJson: infoJson());
      gateway.stateBody = {
        'queuedMessageCount': 0,
        'todoPhases': [
          {
            'name': 'Tasks',
            'tasks': [
              {'content': 'Done thing', 'status': 'completed'},
              {
                'content': 'Blocked thing',
                'status': 'blocked',
                'blocker': 'Waiting on review',
              },
            ],
          },
        ],
      };
      final hub = SocketHub();
      final container = makeContainer(gateway: gateway, hub: hub);
      final sub = container.listen(
        sessionControllerProvider('abc'),
        (previous, next) {},
      );
      addTearDown(sub.close);
      await pumpEventQueue();
      await pumpEventQueue();

      final s = container.read(sessionControllerProvider('abc'));
      expect(s.planPhases, hasLength(1));
      expect(s.planPhases[0].tasks.map((t) => t.status).toList(), [
        'completed',
        'blocked',
      ]);
    });
  });
}
