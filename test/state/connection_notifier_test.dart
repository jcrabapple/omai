import 'dart:convert';

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

http.Response _json(Object? body, {int status = 200}) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});

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
  }) {
    final c = ProviderContainer(overrides: [
      connectionPrefsProvider.overrideWithValue(prefs),
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

  test('sign in persists url (trailing slash stripped) and token by id',
      () async {
    final c = container();
    await settle(c);
    final notifier = c.read(connectionNotifierProvider.notifier);

    final signed = await notifier.signIn(
        url: 'https://gw.example.com/', label: 'home gw', token: 'sekrit');
    expect(signed.record.id, 'gw.example.com');
    expect(signed.record.url, 'https://gw.example.com');
    verify(() => tokens.write('gw.example.com', 'sekrit')).called(1);
    verify(() => prefs.save(any(that: hasLength(1)))).called(1);
    expect(c.read(connectionNotifierProvider).signedIn, isTrue);
  });

  test('sign out removes the record and the token', () async {
    final c = container();
    await settle(c);
    final notifier = c.read(connectionNotifierProvider.notifier);

    await notifier.signIn(url: 'https://gw.example.com', label: 'gw', token: 'tok');
    await notifier.signOut();

    verify(() => tokens.delete('gw.example.com')).called(1);
    verify(() => prefs.save(const <ConnectionRecord>[])).called(1);
    expect(c.read(connectionNotifierProvider).signedIn, isFalse);
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

    expect(
        await notifier.testConnection('', 'tok'), 'Enter the gateway URL first.');
    expect(await notifier.testConnection('https://gw.example.com', '  '),
        'Enter the gateway token first.');
    expect(httpCalled, isFalse);
  });

  final failureCases = <String, Map<String, Object?>>{
    'AuthError': {
      'status': 401,
      'expect': 'The gateway rejected the token. Check it and try again.',
    },
    'LockedOut': {
      'status': 429,
      'expect': 'Too many failed attempts. This IP is locked out for a while.',
    },
    'EdgeRefused': {
      'html': true,
      'expect': 'The edge (Cloudflare) refused the request. Check the URL.',
    },
    'Offline': {
      'status': 503,
      'expect': 'Could not reach the gateway. Check the URL and your network.',
    },
    'GatewayError': {
      'status': 404,
      'expect': 'The gateway answered with an error: not found',
    },
  };
  failureCases.forEach((name, spec) {
    test('connection test maps $name to clear copy', () async {
      final html = spec['html'] == true;
      final status = spec['status'] as int? ?? 400;
      final c = container(
        clientFactory: stubClient((_) async => html
            ? http.Response('<html>err</html>', 400,
                headers: {'content-type': 'text/html'})
            : _json({'error': 'not found'}, status: status)),
      );
      await settle(c);
      final outcome = await c
          .read(connectionNotifierProvider.notifier)
          .testConnection('https://gw.example.com', 'tok');
      expect(outcome, spec['expect']);
      expect(c.read(connectionNotifierProvider).testOutcome, spec['expect']);
      expect(c.read(connectionNotifierProvider).busy, isFalse);
    });
  });

  test('connection test verifies WS through a live session via the probe',
      () async {
    Uri? probedUri;
    Map<String, String>? probedHeaders;
    final c = container(
      clientFactory: stubClient((req) async {
        if (req.url.path == '/healthz') return _json({'ok': true});
        if (req.url.path == '/api/me') return _json({'method': 'bearer'});
        if (req.url.path == '/api/sessions') {
          return _json({
            'live': [
              {'gwId': 'abc', 'cwd': '/home/user/x'}
            ],
            'saved': []
          });
        }
        return _json({});
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
    expect(outcome, 'Connection OK. HTTP and WebSocket both verified.');
    expect(probedUri.toString(), 'wss://gw.example.com/omp-ws/abc');
    expect(probedHeaders!['Authorization'], 'Bearer tok');
  });

  test('connection test without live sessions reports WS unverified',
      () async {
    final c = container(
      clientFactory: stubClient((req) async {
        if (req.url.path == '/healthz') return _json({'ok': true});
        if (req.url.path == '/api/me') return _json({'method': 'bearer'});
        if (req.url.path == '/api/sessions') {
          return _json({'live': [], 'saved': []});
        }
        return _json({});
      }),
    );
    await settle(c);
    final outcome = await c
        .read(connectionNotifierProvider.notifier)
        .testConnection('https://gw.example.com', 'tok');
    expect(outcome, 'HTTP OK, WebSocket not verified (no live session).');
  });

  test('connection test reports a failed WS leg distinctly', () async {
    final c = container(
      clientFactory: stubClient((req) async {
        if (req.url.path == '/healthz') return _json({'ok': true});
        if (req.url.path == '/api/me') return _json({'method': 'bearer'});
        if (req.url.path == '/api/sessions') {
          return _json({
            'live': [
              {'gwId': 'abc', 'cwd': '/home/user/x'}
            ],
            'saved': []
          });
        }
        return _json({});
      }),
      probe: (_, _) async => false,
    );
    await settle(c);
    final outcome = await c
        .read(connectionNotifierProvider.notifier)
        .testConnection('https://gw.example.com', 'tok');
    expect(outcome,
        'HTTP OK, but the WebSocket failed. Proxies can pass HTTP and break WS.');
  });

  test('default ws probe fails against a closed port', () async {
    final ok = await defaultWsProbe(
        Uri.parse('ws://127.0.0.1:1/omp-ws/x'), {'Authorization': 'Bearer t'});
    expect(ok, isFalse);
  });
}
