import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ohmypi/api/client.dart';
import 'package:ohmypi/api/errors.dart';

http.Response _json(Object? body, {int status = 200, Map<String, String> headers = const {}}) {
  return http.Response(jsonEncode(body), status,
      headers: {'content-type': 'application/json', ...headers});
}

GatewayClient clientWith(MockClientHandler handler, {String token = 'tok'}) {
  return GatewayClient(
    baseUrl: 'https://gw.example.com',
    token: token,
    client: MockClient(handler),
    timeout: const Duration(seconds: 2),
  );
}

void main() {
  group('request plumbing', () {
    test('sends the bearer header on every request', () async {
      String? auth;
      final client = clientWith((req) async {
        auth = req.headers['Authorization'];
        return _json({'ok': true});
      });
      await client.healthz();
      expect(auth, 'Bearer tok');
    });

    test('strips trailing slashes from the base URL', () async {
      Uri? uri;
      final client = GatewayClient(
        baseUrl: 'https://gw.example.com/',
        token: 't',
        client: MockClient((req) async {
          uri = req.url;
          return _json({'ok': true});
        }),
      );
      await client.healthz();
      expect(uri.toString(), 'https://gw.example.com/healthz');
    });

    test('wsUrl converts the scheme and appends query params', () {
      final client = clientWith((_) async => _json({}));
      expect(
        client.wsUrl('/omp-ws/abc', {'after': '42'}).toString(),
        'wss://gw.example.com/omp-ws/abc?after=42',
      );
    });

    test('POST sends JSON bodies', () async {
      Object? body;
      final client = clientWith((req) async {
        body = jsonDecode(req.body);
        return _json({});
      });
      await client.setName('s1', 'new name');
      expect(body, {'name': 'new name'});
    });
  });

  group('error classes', () {
    test('confirmed 401 throws AuthError', () async {
      final client = clientWith((_) async => _json({'error': 'bad token'}, status: 401));
      await expectLater(client.me(), throwsA(isA<AuthError>()));
    });

    test('429 throws LockedOut with retryAfterSec when present', () async {
      final client = clientWith(
          (_) async => _json({'error': 'locked', 'retryAfterSec': 60}, status: 429));
      try {
        await client.me();
        fail('should have thrown');
      } on LockedOut catch (e) {
        expect(e.retryAfterSec, 60);
      }
    });

    test('Cloudflare 400 with an HTML body throws EdgeRefused', () async {
      final client = clientWith((_) async => http.Response(
          '<!DOCTYPE html><html><body>Error 1000</body></html>', 400,
          headers: {'content-type': 'text/html; charset=UTF-8'}));
      await expectLater(client.me(), throwsA(isA<EdgeRefused>()));
    });

    test('plain JSON 400 stays a GatewayError, not EdgeRefused', () async {
      final client =
          clientWith((_) async => _json({'error': 'nope'}, status: 400));
      try {
        await client.me();
        fail('should have thrown');
      } on GatewayError catch (e) {
        expect(e.status, 400);
        expect(e.message, 'nope');
      }
    });

    test('JSON {error} on a 404 is a GatewayError', () async {
      final client =
          clientWith((_) async => _json({'error': 'not found'}, status: 404));
      try {
        await client.sessionInfo('missing');
        fail('should have thrown');
      } on GatewayError catch (e) {
        expect(e.status, 404);
        expect(e.message, 'not found');
      }
    });

    test('5xx is Offline, never an auth problem', () async {
      final client =
          clientWith((_) async => _json({'error': 'boom'}, status: 503));
      await expectLater(client.me(), throwsA(isA<Offline>()));
    });

    test('socket failure is Offline', () async {
      final client = clientWith((_) async => throw Exception('socket'));
      await expectLater(client.me(), throwsA(isA<Offline>()));
    });
  });

  group('endpoint shapes', () {
    test('sessions list hits the right path with params', () async {
      Uri? uri;
      final client = clientWith((req) async {
        uri = req.url;
        return _json({'live': [], 'saved': []});
      });
      await client.sessions(limit: 5);
      expect(uri!.path, '/api/sessions');
      expect(uri!.queryParameters['limit'], '5');
    });

    test('sessionInfo encodes the id', () async {
      Uri? uri;
      final client = clientWith((req) async {
        uri = req.url;
        return _json({'gwId': 'abc', 'cwd': '/home/user/x'});
      });
      final info = await client.sessionInfo('a b/c');
      expect(uri!.path, '/api/sessions/a%20b%2Fc');
      expect(info.gwId, 'abc');
    });

    test('pendingUi returns raw maps and answerUi posts the answer', () async {
      final bodies = <Object?>[];
      Uri? uiPath;
      final client = clientWith((req) async {
        if (req.url.path.endsWith('/ui')) {
          return _json({'pending': [
            {'id': 'r1', 'method': 'select', 'options': ['Approve', 'Deny']},
            'junk',
          ]});
        }
        bodies.add(jsonDecode(req.body));
        uiPath = req.url;
        return _json({});
      });
      final pending = await client.pendingUi('s1');
      expect(pending, hasLength(1));
      expect(pending.first['id'], 'r1');
      await client.answerUi('s1', 'r1', {'value': 'Approve'});
      expect(bodies.single, {'value': 'Approve'});
      expect(uiPath!.path, '/api/sessions/s1/ui/r1');
    });

    test('startSession omits unset optional fields', () async {
      Object? body;
      final client = clientWith((req) async {
        body = jsonDecode(req.body);
        return _json({'gwId': 'n1', 'cwd': '/home/user/projects/demo',
            'alreadyLive': true});
      });
      final info = await client.startSession(resumeFrom: '/home/user/.omp/agent/sessions/f.jsonl');
      expect(body, {'resumeFrom': '/home/user/.omp/agent/sessions/f.jsonl'});
      expect(info.alreadyLive, isTrue);
    });

    test('rpc passthrough posts the command', () async {
      Object? body;
      final client = clientWith((req) async {
        body = jsonDecode(req.body);
        return _json({'data': {'x': 1}});
      });
      final res = await client.rpc({'id': 'c1', 'type': 'get_state'});
      expect(body, {'id': 'c1', 'type': 'get_state'});
      expect(res['data'], {'x': 1});
    });

    test('healthz returns ok', () async {
      final client = clientWith((_) async => _json({'ok': true}));
      expect(await client.healthz(), isTrue);
    });
  });
}
