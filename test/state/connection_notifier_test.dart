import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpServer, WebSocketTransformer;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ohmypi/api/client.dart';
import 'package:ohmypi/state/connection_notifier.dart';
import 'package:ohmypi/state/connection_store.dart';

class MockConnectionPrefs extends Mock implements ConnectionPrefs {}

class MockTokenStore extends Mock implements TokenStore {}

/// ConnectionPrefs that delays load(), to exercise the load/sign-in race.
class DelayedPrefs extends Mock implements ConnectionPrefs {
  DelayedPrefs(this.delay);
  final Duration delay;
  final List<ConnectionRecord> saved = [];

  @override
  Future<List<ConnectionRecord>> load() async {
    await Future<void>.delayed(delay);
    return const [];
  }

  @override
  Future<void> save(List<ConnectionRecord> connections) async {
    saved
      ..clear()
      ..addAll(connections);
  }
}

http.Response _json(Object? body, {int status = 200}) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});

http.Response _liveSessions({String gwId = 'abc'}) => _json({
      'live': [
        {'gwId': gwId, 'cwd': '/home/user/x'}
      ],
      'saved': []
    });

http.Response _okChain(http.Request req) {
  if (req.url.path == '/healthz') return _json({'ok': true});
  if (req.url.path == '/api/me') return _json({'method': 'bearer'});
  if (req.url.path == '/api/sessions') return _liveSessions();
  return _json({});
}

void main() {
  late MockConnectionPrefs prefs;
  late MockTokenStore tokens;

  setUpAll(() {
    registerFallbackValue(const ConnectionRecord(id: 'x', url: 'u', label: 'l'));
  });

  setUp(() {
    prefs = MockConnectionPrefs();
    tokens = MockTokenStore();
    when(() => prefs.load()).thenAnswer((_) async => const []);
    when(() => prefs.save(any())).thenAnswer((_) async {});
    when(() => tokens.read(any())).thenAnswer((_) async => null);
    when(() => tokens.write(any(), any())).thenAnswer((_) async {});
    when(() => tokens.delete(any())).thenAnswer((_) async {});
  });

  ProviderContainer container({
    GatewayClientFactory? clientFactory,
    WsProbe? probe,
    ConnectionPrefs? prefsOverride,
  }) {
    final c = ProviderContainer(overrides: [
      connectionPrefsProvider.overrideWithValue(prefsOverride ?? prefs),
      tokenStoreProvider.overrideWithValue(tokens),
      if (clientFactory != null)
        gatewayClientFactoryProvider.overrideWithValue(clientFactory),
      if (probe != null) wsProbeProvider.overrideWithValue(probe),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  Future<void> settle(ProviderContainer c) async {
    c.read(connectionNotifierProvider);
    await Future<void>.delayed(Duration.zero);
  }

  GatewayClientFactory stubClient(
      Future<http.Response> Function(http.Request) fn) {
    return (url, token) => GatewayClient(
        baseUrl: url,
        token: token,
        client: MockClient(fn),
        timeout: const Duration(seconds: 2));
  }

  test('loads saved connections and picks the signed-in one', () async {
    when(() => prefs.load()).thenAnswer((_) async => [
          const ConnectionRecord(
              id: 'gw.example.com', url: 'https://gw.example.com', label: 'gw'),
        ]);
    when(() => tokens.read('gw.example.com')).thenAnswer((_) async => 'tok');
    final c = container();
    await settle(c);
    final state = c.read(connectionNotifierProvider);
    expect(state.busy, isFalse);
    expect(state.signedIn, isTrue);
    expect(state.active!.id, 'gw.example.com');
  });

  test('saved connection without a stored token stays signed out', () async {
    when(() => prefs.load()).thenAnswer((_) async => [
          const ConnectionRecord(
              id: 'gw.example.com', url: 'https://gw.example.com', label: 'gw'),
        ]);
    when(() => tokens.read('gw.example.com')).thenAnswer((_) async => null);
    final c = container();
    await settle(c);
    expect(c.read(connectionNotifierProvider).signedIn, isFalse);
  });

  test('sign in completing before a slow load is not overwritten by it',
      () async {
    // The delayed load finishes AFTER signIn has applied its state.
    final delayed = DelayedPrefs(const Duration(milliseconds: 120));
    final c = container(prefsOverride: delayed);
    final notifier = c.read(connectionNotifierProvider.notifier);

    final signing = notifier.signIn(
        url: 'https://gw.example.com', label: 'gw', token: 'sekrit');
    final signed = (await signing)!;

    expect(c.read(connectionNotifierProvider).signedIn, isTrue);
    expect(c.read(connectionNotifierProvider).active!.id, signed.record.id);
    expect(c.read(connectionNotifierProvider).active!.url,
        'https://gw.example.com');

    // Let the slow load land; it must not clobber the sign-in.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(c.read(connectionNotifierProvider).signedIn, isTrue);
    expect(c.read(connectionNotifierProvider).active!.id, signed.record.id);
  });

  test('sign in persists url (trailing slash stripped) and token by id',
      () async {
    final c = container();
    await settle(c);
    final notifier = c.read(connectionNotifierProvider.notifier);

    final signed = (await notifier.signIn(
        url: 'https://gw.example.com/', label: 'home gw', token: 'sekrit'))!;
    expect(signed.record.url, 'https://gw.example.com');
    verify(() => tokens.write(signed.record.id, 'sekrit')).called(1);
    verify(() => prefs.save(any(that: hasLength(1)))).called(1);
    expect(c.read(connectionNotifierProvider).signedIn, isTrue);
  });

  test('sign in deduplicates: a second concurrent call is a no-op', () async {
    final gate = Completer<void>();
    addTearDown(() { if (!gate.isCompleted) gate.complete(); });
    // Slow the first sign-in down so the second call overlaps it.
    when(() => prefs.save(any())).thenAnswer((_) => gate.future);
    final c = container();
    await settle(c);
    final notifier = c.read(connectionNotifierProvider.notifier);

    final first = notifier.signIn(
        url: 'https://gw.example.com', label: 'gw', token: 't1');
    final second = notifier.signIn(
        url: 'https://gw.example.com', label: 'gw', token: 't2');
    gate.complete();
    final signed = await first;
    final secondResult = await second;

    expect(identical(signed, secondResult), isTrue,
        reason: 'the double tap returns the first sign-in, not a second run');
    verify(() => prefs.save(any())).called(1);
    verify(() => tokens.write(any(), any())).called(1);
  });

  test('sign in sets busy while running and clears it when done', () async {
    final gate = Completer<void>();
    addTearDown(() { if (!gate.isCompleted) gate.complete(); });
    when(() => prefs.save(any())).thenAnswer((_) => gate.future);
    final c = container();
    await settle(c);
    final notifier = c.read(connectionNotifierProvider.notifier);

    final signing = notifier.signIn(
        url: 'https://gw.example.com', label: 'gw', token: 't1');
    await Future<void>.delayed(Duration.zero);
    expect(c.read(connectionNotifierProvider).busy, isTrue,
        reason: 'busy is set for the duration of sign in');
    if (!gate.isCompleted) gate.complete();
    await signing;
    expect(c.read(connectionNotifierProvider).busy, isFalse);
  });
  test('new connections get a permanent random id; the same url reuses it',
      () async {
    final c = container();
    await settle(c);
    final notifier = c.read(connectionNotifierProvider.notifier);

    final first = (await notifier.signIn(
        url: 'https://gw.example.com', label: 'gw', token: 't1'))!;
    expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(first.record.id), isTrue,
        reason: 'id is 16 hex chars, not derived from the url');

    // Re-signing the same url (with a trailing slash) keeps the id, so the
    // secure-storage token key cannot drift.
    final second = (await notifier.signIn(
        url: 'https://gw.example.com/', label: 'gw2', token: 't2'))!;
    expect(second.record.id, first.record.id);
    verify(() => tokens.write(first.record.id, 't2')).called(1);

    // A different url gets a different id.
    final other = (await notifier.signIn(
        url: 'https://other.example.com', label: 'o', token: 't3'))!;
    expect(other.record.id, isNot(first.record.id));
  });

  test('sign out updates state before touching storage', () async {
    final c = container();
    await settle(c);
    final notifier = c.read(connectionNotifierProvider.notifier);

    await notifier.signIn(url: 'https://gw.example.com', label: 'gw', token: 'tok');
    expect(c.read(connectionNotifierProvider).signedIn, isTrue);

    // Make the storage delete slow: state must already be signed out.
    final gate = Completer<void>();
    when(() => tokens.delete(any())).thenAnswer((_) => gate.future);
    final signingOut = notifier.signOut();
    await Future<void>.delayed(Duration.zero);

    expect(c.read(connectionNotifierProvider).signedIn, isFalse,
        reason: 'state clears before the storage delete resolves');

    gate.complete();
    await signingOut;
    verify(() => tokens.delete(any())).called(1);
    verify(() => prefs.save(const <ConnectionRecord>[])).called(1);
  });

  test('load failure does not break sign in', () async {
    when(() => prefs.load()).thenThrow(Exception('disk unavailable'));
    final c = container();
    final notifier = c.read(connectionNotifierProvider.notifier);
    await Future<void>.delayed(Duration.zero);

    final state = c.read(connectionNotifierProvider);
    expect(state.busy, isFalse, reason: 'the failed load must not wedge busy');
    expect(state.signedIn, isFalse);
    expect(state.loadError, 'Could not load saved connections.');

    final signed = (await notifier.signIn(
        url: 'https://gw.example.com', label: 'gw', token: 'tok'))!;
    expect(signed.record.url, 'https://gw.example.com');
    expect(c.read(connectionNotifierProvider).signedIn, isTrue);
  });

  test('a load that never completes does not hang sign in past the bound',
      () async {
    final never = Completer<List<ConnectionRecord>>();
    addTearDown(() {
      if (!never.isCompleted) never.complete(const []);
    });
    ConnectionNotifier.settleBound = const Duration(milliseconds: 50);
    addTearDown(() => ConnectionNotifier.settleBound = const Duration(seconds: 4));
    when(() => prefs.load()).thenAnswer((_) => never.future);
    final c = container();
    final notifier = c.read(connectionNotifierProvider.notifier);

    final sw = Stopwatch()..start();
    final signed = await notifier.signIn(
        url: 'https://gw.example.com', label: 'gw', token: 'tok');
    sw.stop();
    expect(signed, isNotNull, reason: 'sign in proceeds once the bound passes');
    expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
  });

  test('normalizeGatewayUrl table', () {
    String n(String u) => normalizeGatewayUrl(u);
    expect(n('https://GW.Example.com'), n('https://gw.example.com/'));
    expect(n('http://h:80'), n('http://h'));
    expect(n('https://h:443/'), n('https://h'));
    expect(n('http://h:443'), isNot(n('http://h')));
    expect(n('https://h:8443'), 'https://h:8443');
    expect(n('https://h/sub/'), 'https://h/sub');
    expect(n('HTTPS://H.COM'), 'https://h.com');
  });

  test('test connection guards empty url and token without HTTP calls',
      () async {
    var httpCalled = false;
    final c = container(
      clientFactory: stubClient((_) async {
        httpCalled = true;
        return _json({});
      }),
    );
    await settle(c);
    final notifier = c.read(connectionNotifierProvider.notifier);

    final noUrl = await notifier.testConnection('', 'tok');
    expect(noUrl, isA<TestError>());
    expect(noUrl.message, 'Enter the gateway URL first.');
    final noToken = await notifier.testConnection('https://gw.example.com', '  ');
    expect(noToken, isA<TestError>());
    expect(noToken.message, 'Enter the gateway token first.');
    expect(httpCalled, isFalse);
    // Validation failures must reach the screen, not just the caller.
    final shown = c.read(connectionNotifierProvider).testResult;
    expect(shown, isNotNull);
    expect(shown!.message, 'Enter the gateway token first.');
    expect(c.read(connectionNotifierProvider).busy, isFalse);
  });

  final failureCases = <String, Map<String, Object?>>{
    'AuthError': {
      'status': 401,
      'kind': TestError,
      'expect': 'The gateway rejected the token. Check it and try again.',
    },
    'LockedOut': {
      'status': 429,
      'retryAfterSec': 60,
      'kind': TestError,
      'expect': 'Too many failed attempts. This IP is locked out for a while.',
    },
    'EdgeRefused': {
      'html': true,
      'kind': TestError,
      'expect': 'The edge (Cloudflare) refused the request. Check the URL.',
    },
    'Offline': {
      'status': 503,
      'kind': TestError,
      'expect': 'Could not reach the gateway. Check the URL and your network.',
    },
    'GatewayError': {
      'status': 404,
      'kind': TestError,
      'expect': 'The gateway answered with an error: not found',
    },
  };
  failureCases.forEach((name, spec) {
    test('connection test maps $name to clear copy', () async {
      final html = spec['html'] == true;
      final status = spec['status'] as int? ?? 400;
      final retry = spec.containsKey('retryAfterSec');
      final body = <String, Object?>{'error': 'not found'};
      if (retry) body['retryAfterSec'] = 60;
      final c = container(
        clientFactory: stubClient((_) async => html
            ? http.Response('<html>err</html>', 400,
                headers: {'content-type': 'text/html'})
            : _json(body, status: status)),
      );
      await settle(c);
      final outcome = await c
          .read(connectionNotifierProvider.notifier)
          .testConnection('https://gw.example.com', 'tok');
      expect(outcome.runtimeType, spec['kind'], reason: name);
      expect(outcome.message, spec['expect']);
      expect(c.read(connectionNotifierProvider).testResult?.message,
          spec['expect']);
      expect(c.read(connectionNotifierProvider).busy, isFalse);
    });
  });

  test('connection test verifies WS through a live session via the probe',
      () async {
    Uri? probedUri;
    Map<String, String>? probedHeaders;
    Uri? sessionsUri;
    final c = container(
      clientFactory: stubClient((req) async {
        if (req.url.path == '/api/sessions') sessionsUri = req.url;
        return _okChain(req);
      }),
      probe: (uri, headers) async {
        probedUri = uri;
        probedHeaders = headers;
        return true;
      },
    );
    await settle(c);
    final outcome = await c
        .read(connectionNotifierProvider.notifier)
        .testConnection('https://gw.example.com', 'tok');
    expect(outcome, isA<TestOk>());
    expect(outcome.message, 'Connection OK. HTTP and WebSocket both verified.');
    expect(probedUri.toString(), 'wss://gw.example.com/omp-ws/abc');
    expect(probedHeaders!['Authorization'], 'Bearer tok');
    // include_saved must be sent explicitly (gateway defaults to true).
    expect(sessionsUri!.queryParameters['include_saved'], 'false');
  });

  test('connection test without live sessions reports WS unverified',
      () async {
    final c = container(
      clientFactory: stubClient((req) async {
        if (req.url.path == '/api/sessions') return _json({'live': [], 'saved': []});
        return _okChain(req);
      }),
    );
    await settle(c);
    final outcome = await c
        .read(connectionNotifierProvider.notifier)
        .testConnection('https://gw.example.com', 'tok');
    expect(outcome, isA<TestWsUnverified>());
    expect(outcome.message, 'HTTP OK, WebSocket not verified (no live session).');
  });

  test('connection test reports a failed WS leg as TestWsFailed', () async {
    final c = container(
      clientFactory: stubClient((req) async => _okChain(req)),
      probe: (_, _) async => false,
    );
    await settle(c);
    final outcome = await c
        .read(connectionNotifierProvider.notifier)
        .testConnection('https://gw.example.com', 'tok');
    expect(outcome, isA<TestWsFailed>());
    expect(outcome.message,
        'HTTP OK, but the WebSocket failed. Proxies can pass HTTP and break WS.');
  });

  test('default ws probe fails against a closed port', () async {
    final ok = await defaultWsProbe(
        Uri.parse('ws://127.0.0.1:1/omp-ws/x'), {'Authorization': 'Bearer t'});
    expect(ok, isFalse);
  });

  group('default ws probe against a real local websocket', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind('127.0.0.1', 0);
    });

    tearDown(() async {
      await server.close(force: true);
    });

    /// Accept the upgrade, optionally send a first frame, then close.
    void serve({
      Map<String, Object?>? firstFrame,
      required int code,
      bool closeAfter = true,
    }) {
      server.listen((req) async {
        final ws = await WebSocketTransformer.upgrade(req);
        if (firstFrame != null) ws.add(jsonEncode(firstFrame));
        if (closeAfter) await ws.close(code, 'bye');
      });
    }

    Uri probeUri() => Uri.parse('ws://127.0.0.1:${server.port}/omp-ws/x');

    /// The gateway's first frame: `{"seq":0,"event":{"type":"auth_ok",...}}`.
    Map<String, Object?> authOk() =>
        {'seq': 0, 'event': {'type': 'auth_ok', 'session': <String, Object?>{}}};

    test('an auth_ok first frame counts as working', () async {
      serve(firstFrame: authOk(), code: 1000);
      final ok = await defaultWsProbe(
          probeUri(), {'Authorization': 'Bearer t'},
          timeout: const Duration(seconds: 5));
      expect(ok, isTrue);
    });

    test('a non-auth_ok first frame is a failure', () async {
      serve(
          firstFrame: {
            'seq': 0,
            'event': {'type': 'heartbeat', 'lastSeq': 0}
          },
          code: 1000);
      final ok = await defaultWsProbe(
          probeUri(), {'Authorization': 'Bearer t'},
          timeout: const Duration(seconds: 5));
      expect(ok, isFalse);
    });

    test('close code 4401 (bad token) is a failure', () async {
      serve(code: 4401);
      final ok = await defaultWsProbe(
          probeUri(), {'Authorization': 'Bearer wrong'},
          timeout: const Duration(seconds: 5));
      expect(ok, isFalse);
    });

    test('a clean close without auth_ok is a failure', () async {
      serve(code: 1000);
      final ok = await defaultWsProbe(
          probeUri(), {'Authorization': 'Bearer t'},
          timeout: const Duration(seconds: 5));
      expect(ok, isFalse);
    });

    test('upgrade then silence fails at the timeout', () async {
      serve(firstFrame: null, closeAfter: false, code: 1000);
      final sw = Stopwatch()..start();
      final ok = await defaultWsProbe(
          probeUri(), {'Authorization': 'Bearer t'},
          timeout: const Duration(milliseconds: 200));
      sw.stop();
      expect(ok, isFalse);
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    });
  });
}
