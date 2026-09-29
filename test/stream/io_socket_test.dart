// Real dart:io sockets against a local server, to prove the gateway's
// post-accept close codes reach the stream (the fakes can't show this).
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ohmypi/stream/session_stream.dart';

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
}
