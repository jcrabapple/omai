import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omai/api/client.dart';
import 'package:omai/api/errors.dart';

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

/// One row of the endpoint table: what the client must send vs what it sends.
class _Endpoint {
  const _Endpoint({
    required this.name,
    required this.method,
    required this.path,
    this.query,
    this.body,
    required this.call,
  });

  final String name;
  final String method;
  final String path;
  final Map<String, String>? query;
  final Object? body;
  final Future<void> Function(GatewayClient c) call;
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

    test('429 with retryAfterSec throws LockedOut', () async {
      final client = clientWith(
          (_) async => _json({'error': 'locked', 'retryAfterSec': 60}, status: 429));
      try {
        await client.me();
        fail('should have thrown');
      } on LockedOut catch (e) {
        expect(e.retryAfterSec, 60);
      }
    });

    test('429 with only a Retry-After header throws LockedOut', () async {
      final client = clientWith((_) async => _json({'error': 'locked'}, status: 429,
          headers: {'retry-after': '120'}));
      try {
        await client.me();
        fail('should have thrown');
      } on LockedOut catch (e) {
        expect(e.retryAfterSec, 120);
      }
    });

    test('bare 429 (session cap) is a GatewayError, not LockedOut', () async {
      final client = clientWith((_) async =>
          _json({'error': 'session limit reached (8); stop one first'}, status: 429));
      try {
        await client.sessions();
        fail('should have thrown');
      } on GatewayError catch (e) {
        expect(e.status, 429);
        expect(e.message, 'session limit reached (8); stop one first');
      }
    });

    test('FastAPI 422 detail list surfaces the first msg', () async {
      final client = clientWith((_) async => _json({
            'detail': [
              {'loc': ['body', 'cwd'], 'msg': 'Field required', 'type': 'missing'},
              {'loc': ['body', 'model'], 'msg': 'ignored', 'type': 'missing'},
            ]
          }, status: 422));
      try {
        await client.startSession();
        fail('should have thrown');
      } on GatewayError catch (e) {
        expect(e.status, 422);
        expect(e.message, 'Field required');
      }
    });

    test('FastAPI 422 with a plain string detail keeps working', () async {
      final client = clientWith((_) async => _json({'detail': 'message required'}, status: 422));
      try {
        await client.prompt('s1', '');
        fail('should have thrown');
      } on GatewayError catch (e) {
        expect(e.message, 'message required');
      }
    });

    test('Cloudflare 400 with an HTML body throws EdgeRefused', () async {
      final client = clientWith((_) async => http.Response(
          '<!DOCTYPE html><html><body>Error 1000</body></html>', 400,
          headers: {'content-type': 'text/html; charset=UTF-8'}));
      await expectLater(client.me(), throwsA(isA<EdgeRefused>()));
    });

    test('lowercase <!doctype html is still EdgeRefused', () async {
      final client = clientWith((_) async => http.Response(
          '<!doctype html><html><body>error 1000</body></html>', 400,
          headers: {'content-type': 'text/plain'}));
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

    test('TimeoutException is Offline', () async {
      final client = GatewayClient(
        baseUrl: 'https://gw.example.com',
        token: 't',
        client: MockClient((_) async {
          await Future<void>.delayed(const Duration(seconds: 2));
          return http.Response('{}', 200);
        }),
        timeout: const Duration(milliseconds: 50),
      );
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

    test('rpc posts the command to the session-scoped route', () async {
      Uri? uri;
      Object? body;
      final client = clientWith((req) async {
        uri = req.url;
        body = jsonDecode(req.body);
        return _json({'data': {'x': 1}});
      });
      final res = await client.rpc('s1', {'id': 'c1', 'type': 'get_state'});
      expect(uri!.path, '/api/sessions/s1/rpc');
      expect(body, {'id': 'c1', 'type': 'get_state'});
      expect(res['data'], {'x': 1});
    });

    test('compact posts to the session route, body omits empty instructions',
        () async {
      final bodies = <Object?>[];
      final uris = <Uri>[];
      final client = clientWith((req) async {
        uris.add(req.url);
        bodies.add(req.body.isEmpty ? null : jsonDecode(req.body));
        return _json({'data': {'ok': true}});
      });
      await client.compact('s1', instructions: 'keep the plan');
      await client.compact('s1');
      expect(uris.map((u) => u.path),
          ['/api/sessions/s1/compact', '/api/sessions/s1/compact']);
      expect(bodies, [
        {'instructions': 'keep the plan'},
        {},
      ]);
    });

    test('healthz returns ok', () async {
      final client = clientWith((_) async => _json({'ok': true}));
      expect(await client.healthz(), isTrue);
    });
  });

  group('endpoint table (every client method vs API.md)', () {
    const sid = 's9';
    final cases = <_Endpoint>[
      _Endpoint(
        name: 'healthz',
        method: 'GET',
        path: '/healthz',
        call: (GatewayClient c) => c.healthz(),
      ),
      _Endpoint(
        name: 'health',
        method: 'GET',
        path: '/api/health',
        call: (GatewayClient c) => c.health(),
      ),
      _Endpoint(
        name: 'me',
        method: 'GET',
        path: '/api/me',
        call: (GatewayClient c) => c.me(),
      ),
      _Endpoint(
        name: 'system',
        method: 'GET',
        path: '/api/system',
        call: (GatewayClient c) => c.system(),
      ),
      _Endpoint(
        name: 'catalogModels',
        method: 'GET',
        path: '/api/catalog/models',
        query: {'refresh': '1'},
        call: (GatewayClient c) => c.catalogModels(refresh: true),
      ),
      _Endpoint(
        name: 'catalogModels without refresh',
        method: 'GET',
        path: '/api/catalog/models',
        query: {},
        call: (GatewayClient c) => c.catalogModels(),
      ),
      _Endpoint(
        name: 'skills',
        method: 'GET',
        path: '/api/skills',
        call: (GatewayClient c) => c.skills(),
      ),
      _Endpoint(
        name: 'usage',
        method: 'GET',
        path: '/api/usage',
        call: (GatewayClient c) => c.usage(),
      ),
      _Endpoint(
        name: 'rpc',
        method: 'POST',
        path: '/api/sessions/$sid/rpc',
        body: {'type': 'get_state'},
        call: (GatewayClient c) => c.rpc(sid, {'type': 'get_state'}),
      ),
      _Endpoint(
        name: 'sessions include_saved default true',
        method: 'GET',
        path: '/api/sessions',
        query: {'limit': '60', 'include_saved': 'true'},
        call: (GatewayClient c) => c.sessions(),
      ),
      _Endpoint(
        name: 'sessions include_saved false is sent explicitly',
        method: 'GET',
        path: '/api/sessions',
        query: {'limit': '1', 'include_saved': 'false'},
        call: (GatewayClient c) => c.sessions(limit: 1, includeSaved: false),
      ),
      _Endpoint(
        name: 'startSession',
        method: 'POST',
        path: '/api/sessions',
        body: {'cwd': '/home/user/x'},
        call: (GatewayClient c) => c.startSession(cwd: '/home/user/x'),
      ),
      _Endpoint(
        name: 'startSession full create body (API.md)',
        method: 'POST',
        path: '/api/sessions',
        body: {
          'cwd': '/home/user/x',
          'model': 'anthropic/claude-sonnet',
          'thinking': 'high',
          'approvalMode': 'always-ask',
        },
        call: (GatewayClient c) => c.startSession(
          cwd: '/home/user/x',
          model: 'anthropic/claude-sonnet',
          thinking: 'high',
          approvalMode: 'always-ask',
        ),
      ),
      _Endpoint(
        name: 'startSession resume (API.md resumeFrom)',
        method: 'POST',
        path: '/api/sessions',
        body: {
          'resumeFrom': '/home/user/.omp/agent/sessions/f.jsonl',
          'cwd': '/home/user/x',
        },
        call: (GatewayClient c) => c.startSession(
          resumeFrom: '/home/user/.omp/agent/sessions/f.jsonl',
          cwd: '/home/user/x',
        ),
      ),
      _Endpoint(
        name: 'sessionInfo',
        method: 'GET',
        path: '/api/sessions/$sid',
        call: (GatewayClient c) => c.sessionInfo(sid),
      ),
      _Endpoint(
        name: 'deleteSession',
        method: 'DELETE',
        path: '/api/sessions/$sid',
        call: (GatewayClient c) => c.deleteSession(sid),
      ),
      _Endpoint(
        name: 'prompt',
        method: 'POST',
        path: '/api/sessions/$sid/prompt',
        body: {'message': 'hi', 'mode': 'prompt'},
        call: (GatewayClient c) => c.prompt(sid, 'hi'),
      ),
      _Endpoint(
        name: 'prompt with images',
        method: 'POST',
        path: '/api/sessions/$sid/prompt',
        body: {
          'message': 'see this',
          'mode': 'prompt',
          'images': [
            {'type': 'image', 'data': 'QUJD', 'mimeType': 'image/png'}
          ],
        },
        call: (GatewayClient c) => c.prompt(sid, 'see this',
            images: const [
              {'type': 'image', 'data': 'QUJD', 'mimeType': 'image/png'}
            ]),
      ),
      _Endpoint(
        name: 'abort',
        method: 'POST',
        path: '/api/sessions/$sid/abort',
        call: (GatewayClient c) => c.abort(sid),
      ),
      _Endpoint(
        name: 'compact',
        method: 'POST',
        path: '/api/sessions/$sid/compact',
        call: (GatewayClient c) => c.compact(sid),
      ),
      _Endpoint(
        name: 'state',
        method: 'GET',
        path: '/api/sessions/$sid/state',
        call: (GatewayClient c) => c.state(sid),
      ),
      _Endpoint(
        name: 'messages',
        method: 'GET',
        path: '/api/sessions/$sid/messages',
        call: (GatewayClient c) => c.messages(sid),
      ),
      _Endpoint(
        name: 'stats',
        method: 'GET',
        path: '/api/sessions/$sid/stats',
        call: (GatewayClient c) => c.stats(sid),
      ),
      _Endpoint(
        name: 'setModel',
        method: 'POST',
        path: '/api/sessions/$sid/model',
        body: {'provider': 'p', 'modelId': 'm'},
        call: (GatewayClient c) => c.setModel(sid, 'p', 'm'),
      ),
      _Endpoint(
        name: 'setThinking',
        method: 'POST',
        path: '/api/sessions/$sid/thinking',
        body: {'level': 'low'},
        call: (GatewayClient c) => c.setThinking(sid, 'low'),
      ),
      _Endpoint(
        name: 'setName',
        method: 'POST',
        path: '/api/sessions/$sid/name',
        body: {'name': 'n'},
        call: (GatewayClient c) => c.setName(sid, 'n'),
      ),
      _Endpoint(
        name: 'commands',
        method: 'GET',
        path: '/api/sessions/$sid/commands',
        call: (GatewayClient c) => c.commands(sid),
      ),
      _Endpoint(
        name: 'events',
        method: 'GET',
        path: '/api/sessions/$sid/events',
        query: {'after': '7'},
        call: (GatewayClient c) => c.events(sid, after: 7),
      ),
      _Endpoint(
        name: 'pendingUi',
        method: 'GET',
        path: '/api/sessions/$sid/ui',
        call: (GatewayClient c) => c.pendingUi(sid),
      ),
      _Endpoint(
        name: 'answerUi',
        method: 'POST',
        path: '/api/sessions/$sid/ui/r1',
        body: {'value': 'yes'},
        call: (GatewayClient c) => c.answerUi(sid, 'r1', {'value': 'yes'}),
      ),
    ];

    for (final tc in cases) {
      test('${tc.method} ${tc.path} (${tc.name})', () async {
        String? method;
        Uri? uri;
        Object? body;
        final client = clientWith((req) async {
          method = req.method;
          uri = req.url;
          body = req.body.isEmpty ? null : jsonDecode(req.body);
          return _json({});
        });
        await tc.call(client);
        expect(method, tc.method, reason: tc.name);
        expect(uri!.path, tc.path, reason: tc.name);
        if (tc.query == null) {
          expect(uri!.queryParameters, isEmpty, reason: tc.name);
        } else {
          expect(uri!.queryParameters, tc.query, reason: tc.name);
        }
        if (tc.body != null) expect(body, tc.body, reason: tc.name);
      });
    }
  });
}
