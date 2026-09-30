// Real dart:io sockets against a local server, to prove the gateway's
// post-accept close codes reach the stream (the fakes can't show this).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omai/stream/session_stream.dart';

Future<HttpServer> _serveClosing(int code, {List<String>? seenAuth}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    seenAuth?.add(req.headers.value('authorization') ?? '');
    final ws = await WebSocketTransformer.upgrade(req);
    await ws.close(code, 'test');
  });
  return server;
}

void main() {
  test('4404 after accept stops the stream as gone', () async {
    final auth = <String>[];
    final server = await _serveClosing(4404, seenAuth: auth);
    final gone = Completer<void>();
    final stream = SessionStream(
      gwId: 'g1',
      baseUrl: 'http://127.0.0.1:${server.port}',
      token: 'tok',
      handlers: StreamHandlers(onGone: gone.complete),
    );
    stream.start();
    await gone.future.timeout(const Duration(seconds: 5));
    expect(auth.single, 'Bearer tok');
    stream.stop();
    await server.close(force: true);
  });

  test('4401 after accept signs out', () async {
    final server = await _serveClosing(4401);
    final out = Completer<void>();
    final stream = SessionStream(
      gwId: 'g1',
      baseUrl: 'http://127.0.0.1:${server.port}',
      token: 'tok',
      handlers: StreamHandlers(onSignedOut: out.complete),
    );
    stream.start();
    await out.future.timeout(const Duration(seconds: 5));
    stream.stop();
    await server.close(force: true);
  });

  test('4408 after accept reconnects and the next upgrade carries after=<cursor>',
      () async {
    final paths = <String>[];
    HttpServer? server;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var drops = 0;
    server.listen((req) async {
      paths.add(req.uri.toString());
      final ws = await WebSocketTransformer.upgrade(req);
      if (drops++ == 0) {
        await ws.close(4408, 'slow consumer');
      } else {
        ws.add(jsonEncode({
          'seq': 0,
          'event': {'type': 'auth_ok', 'session': <String, Object?>{}},
        }));
        // Keep the socket open until the test ends.
        await ws.drain<void>().catchError((_) {});
      }
    });
    final stream = SessionStream(
      gwId: 'g1',
      baseUrl: 'http://127.0.0.1:${server.port}',
      token: 'tok',
      after: 7,
    );
    stream.start();
    // 4408 comes back at once, so the second upgrade happens quickly.
    for (var i = 0;
        paths.length < 2 && i < 50;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(paths, hasLength(2));
    expect(paths[0], contains('after=7'));
    expect(paths[1], contains('after=7'));
    expect(stream.state, StreamState.live);
    stream.stop();
    await server.close(force: true);
  });

  test('HTTP 403 on the upgrade (pre-accept 4429) enters the lockout path',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var hits = 0;
    server.listen((req) async {
      hits++;
      req.response.statusCode = 403;
      await req.response.close();
    });
    final stream = SessionStream(
      gwId: 'g1',
      baseUrl: 'http://127.0.0.1:${server.port}',
      token: 'tok',
      tuning: const StreamTuning(lockoutRetryMs: 60000),
    );
    stream.start();
    // Wait for the failed upgrade to surface.
    for (var i = 0;
        stream.message == null && i < 50;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(hits, 1);
    expect(stream.state, StreamState.retrying);
    expect(stream.message, 'Too many failed attempts. Retrying in a minute.');
    final retryAt = stream.retryAt!;
    // Lockout: no hammering for the full minute.
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(hits, 1);
    expect(stream.retryAt, retryAt);
    expect(stream.state, StreamState.retrying);
    stream.stop();
    await server.close(force: true);
  });

  test('a non-403 upgrade rejection (502) stays a generic retry', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var hits = 0;
    server.listen((req) async {
      hits++;
      req.response.statusCode = 502;
      await req.response.close();
    });
    final stream = SessionStream(
      gwId: 'g1',
      baseUrl: 'http://127.0.0.1:${server.port}',
      token: 'tok',
      tuning: const StreamTuning(baseDelayMs: 100, capDelayMs: 200),
      random: () => 0,
    );
    stream.start();
    // Generic retry: a second attempt comes fast and the message stays null.
    for (var i = 0; hits < 2 && i < 50; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(hits, greaterThanOrEqualTo(2));
    expect(stream.message, isNull);
    stream.stop();
    await server.close(force: true);
  });
}
