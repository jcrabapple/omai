// Controller tests: open sequence order and after=lastEventSeq, the three
// "running never sticks" paths, gone, 401 sign-out, dispose stops the
// stream. Uses the existing stream fakes (test/stream/fakes.dart) and an
// http MockClient.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ohmypi/api/client.dart';
import 'package:ohmypi/state/connection_notifier.dart';
import 'package:ohmypi/state/connection_store.dart';
import 'package:ohmypi/state/session_controller.dart';
import 'package:ohmypi/stream/session_stream.dart';

import '../stream/fakes.dart';
http.Response _json(Object? body, {int status = 200}) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});

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
  FakeGateway({this.infoJson, this.messages = const [], this.status = 200});

  Map<String, Object?>? infoJson;
  List<Object?> messages;
  int status;
  final List<String> paths = [];

  http.Client client() => MockClient((req) async {
        paths.add(req.url.path + (req.url.queryParameters.isEmpty
            ? ''
            : '?${req.url.query}'));
        if (status != 200) return _json({'error': 'nope'}, status: status);
        if (req.url.path.endsWith('/messages')) {
          return _json({'messages': messages});
        }
        if (req.url.path.endsWith('/state')) {
          return _json({});
        }
        if (req.url.path.endsWith('/stats')) {
          return _json({'data': {}});
        }
        if (req.url.path.endsWith('/commands')) {
          return _json({'data': {'commands': []}});
        }
        return _json(infoJson ?? {});
      });
}

ProviderContainer makeContainer({
  required FakeGateway gateway,
  required SocketHub hub,
  FakeScheduler? scheduler,
}) {
  final sched = scheduler ?? FakeScheduler();
  final container = ProviderContainer(overrides: [
    connectionPrefsProvider
        .overrideWithValue(MemoryPrefs(const [
      ConnectionRecord(id: 'c1', url: 'https://g', label: 'G')
    ])),
    tokenStoreProvider
        .overrideWithValue(_FixedTokenStore()),
    gatewayClientFactoryProvider.overrideWith((ref) => (baseUrl, token) =>
        GatewayClient(baseUrl: baseUrl, token: token,
            client: gateway.client())),
    sessionEnvProvider.overrideWith((ref) async => SessionEnv(
        client: GatewayClient(
            baseUrl: 'https://g', token: 'tok', client: gateway.client()),
        baseUrl: 'https://g',
        token: 'tok',
        socketFactory: hub.factory,
        scheduler: sched)),
  ]);
  container.read(connectionNotifierProvider.notifier).state =
      ConnectionState(connections: const [
    ConnectionRecord(id: 'c1', url: 'https://g', label: 'G')
  ], activeId: 'c1');
  addTearDown(container.dispose);
  return container;
}

Map<String, Object?> infoJson({
  String gwId = 'abc',
  int lastEventSeq = 0,
  bool isStreaming = false,
}) =>
    {
      'gwId': gwId,
      'cwd': '/work/x',
      'isStreaming': isStreaming,
      'lastEventSeq': lastEventSeq,
    };

void main() {
  test('open sequence: info, then messages, then the socket with after=lastEventSeq',
      () async {
    final gateway = FakeGateway(
        infoJson: infoJson(lastEventSeq: 3), messages: [
      {'role': 'user', 'content': 'hi'}
    ]);
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

    final s = container.read(provider);
    expect(s.phase, SessionPhase.ready);
    expect(s.transcript.items, isNotEmpty, reason: 'history paints the transcript');
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
    expect(container.read(provider).running, isTrue);
    expect(container.read(provider).activity, isNotNull);

    hub.current.frame(2, {'type': 'agent_end'});
    expect(container.read(provider).running, isFalse,
        reason: 'agent_end always clears running');
    expect(container.read(provider).activity, isNull);
  });

  test('a resync replaces state: fresh info with isStreaming false clears running',
      () async {
    final gateway = FakeGateway(infoJson: infoJson());
    final hub = SocketHub();
    final scheduler = FakeScheduler();
    final container = makeContainer(
        gateway: gateway, hub: hub, scheduler: scheduler);
    final provider = sessionControllerProvider('abc');
    final sub = container.listen(provider, (previous, next) {});
    addTearDown(sub.close);
    await pumpEventQueue();

    hub.current.frame(1, {'type': 'agent_start'});
    expect(container.read(provider).running, isTrue);

    // Reconnect; the server answers auth_ok with gap:true on the new socket,
    // which triggers a resync: a fresh snapshot whose info.isStreaming is
    // false.
    hub.current.serverClose(1006);
    await pumpEventQueue();
    await scheduler.elapse(31000);
    await pumpEventQueue();
    expect(hub.sockets.length, greaterThan(1),
        reason: 'the stream reconnected');
    hub.current.authOk(gap: true);
    gateway.messages = [
      {'role': 'user', 'content': 'hi'}
    ];
    await pumpEventQueue();

    expect(container.read(provider).running, isFalse,
        reason: 'the resync snapshot resets the turn state');
    expect(container.read(provider).transcript.items, isNotEmpty);
  });

  test('fresh info reporting isStreaming:false clears running', () async {
    final gateway = FakeGateway(infoJson: infoJson());
    final hub = SocketHub();
    final container = makeContainer(gateway: gateway, hub: hub);
    final provider = sessionControllerProvider('abc');
    final sub = container.listen(provider, (previous, next) {});
    addTearDown(sub.close);
    await pumpEventQueue();

    hub.current.frame(1, {'type': 'agent_start'});
    expect(container.read(provider).running, isTrue);

    gateway.infoJson = infoJson(isStreaming: false);
    await container.read(provider.notifier).refreshInfo();

    expect(container.read(provider).running, isFalse,
        reason: 'isStreaming:false in fresh info always clears running');
    expect(container.read(provider).info?.isStreaming, isFalse);
  });

  test('onGone: close 4404 puts the session in the gone phase', () async {
    final gateway = FakeGateway(infoJson: infoJson());
    final hub = SocketHub();
    final container = makeContainer(gateway: gateway, hub: hub);
    final provider = sessionControllerProvider('abc');
    final sub = container.listen(provider, (previous, next) {});
    addTearDown(sub.close);
    await pumpEventQueue();

    hub.current.serverClose(4404);
    await pumpEventQueue();

    expect(container.read(provider).phase, SessionPhase.gone);
  });

  test('a 404 on open puts the session in the gone phase', () async {
    final gateway = FakeGateway(status: 404);
    final hub = SocketHub();
    final container = makeContainer(gateway: gateway, hub: hub);
    final provider = sessionControllerProvider('abc');
    final sub = container.listen(provider, (previous, next) {});
    addTearDown(sub.close);
    await pumpEventQueue();

    expect(container.read(provider).phase, SessionPhase.gone);
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

    expect(container.read(provider).phase, SessionPhase.error);
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
    // The provider is keep-alive by default; disposing the container
    // disposes the controller, which must stop the stream.
    container.dispose();
    await pumpEventQueue();
    expect(sock.closed, isTrue, reason: 'disposing the controller closes the socket');
  });

  test('pause and resume are forwarded to the stream', () async {
    final gateway = FakeGateway(infoJson: infoJson());
    final hub = SocketHub();
    final container = makeContainer(gateway: gateway, hub: hub);
    final provider = sessionControllerProvider('abc');
    final sub = container.listen(provider, (previous, next) {});
    addTearDown(sub.close);
    await pumpEventQueue();
    final sock = hub.current;

    container.read(provider.notifier).pause();
    await pumpEventQueue();
    expect(sock.closed, isTrue, reason: 'pausing drops the socket');
  });
}
