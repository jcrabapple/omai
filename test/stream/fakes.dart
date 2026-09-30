// Deterministic fakes for the stream tests: a manual-clock scheduler and a
// scriptable socket, mirroring the web suite's FakeWebSocket + fake timers.
import 'dart:async';
import 'dart:convert';

import 'package:omai/stream/scheduler.dart';
import 'package:omai/stream/session_stream.dart';

class FakeScheduler implements Scheduler {
  FakeScheduler({DateTime? start})
      : clock = start ?? DateTime.fromMillisecondsSinceEpoch(1000000);

  /// The fake clock; tests read it through [clock] and advance it with [elapse].
  DateTime clock;

  @override
  DateTime now() => clock;

  final List<_FakeTimer> _timers = [];

  CancelTimer _add(DateTime at, Duration? every, void Function() fn) {
    final t = _FakeTimer(at, every, fn);
    _timers.add(t);
    return () => t.cancelled = true;
  }

  @override
  CancelTimer delay(Duration delay, void Function() fn) =>
      _add(clock.add(delay), null, fn);

  @override
  CancelTimer period(Duration period, void Function() fn) =>
      _add(clock.add(period), period, fn);

  /// Let pending microtasks (async connect handshakes) settle.
  Future<void> micro() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  /// Advance the fake clock by [ms], firing every timer that comes due in
  /// order. Microtasks are drained between fires so async connects complete.
  Future<void> elapse(int ms) async {
    final end = clock.add(Duration(milliseconds: ms));
    while (true) {
      await micro();
      _timers.removeWhere((t) => t.cancelled);
      if (_timers.isEmpty) break;
      _timers.sort((a, b) => a.at.compareTo(b.at));
      final t = _timers.first;
      if (t.at.isAfter(end)) break;
      _timers.removeAt(0);
      clock = t.at;
      final every = t.every;
      if (every != null) {
        t.at = t.at.add(every);
        _timers.add(t);
      }
      t.fn();
    }
    clock = end;
  }
}

class _FakeTimer {
  _FakeTimer(this.at, this.every, this.fn);

  DateTime at;
  final Duration? every;
  final void Function() fn;
  bool cancelled = false;
}

class FakeSocket implements StreamSocket {
  FakeSocket(this.url, this.headers);

  final Uri url;
  final Map<String, String> headers;
  final List<String> sent = [];
  bool closed = false;

  @override
  int readyState = 0;

  @override
  void Function(String data)? onData;

  @override
  void Function(int code, String reason)? onClosed;

  @override
  void send(String data) {
    sent.add(data);
  }

  @override
  void close() {
    closed = true;
    readyState = 3;
  }

  // ---- test helpers

  void frame(int seq, Map<String, Object?> event) {
    onData?.call(jsonEncode({'seq': seq, 'event': event}));
  }

  void raw(String data) {
    onData?.call(data);
  }

  void authOk({bool gap = false}) {
    readyState = 1;
    frame(0, {
      'type': 'auth_ok',
      'session': <String, Object?>{'gwId': 'abc', 'lastEventSeq': 0},
      'gap': gap,
    });
  }

  void serverClose(int code, [String reason = '']) {
    readyState = 3;
    onClosed?.call(code, reason);
  }
}
