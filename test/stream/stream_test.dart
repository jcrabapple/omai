// Port of web/src/lib/api/__tests__/stream.test.ts: the conformance suite for
// the WebSocket transport. Browser visibility/online handling is replaced by
// the explicit pause()/resume()/networkAvailable() lifecycle methods, and
// fake timers by FakeScheduler.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:omai/stream/session_stream.dart';
import 'package:omai/wire/wire.dart';

import 'fakes.dart';

class Rig {
  Rig()
      : events = [],
        controls = [],
        states = [],
        resyncs = [],
        sockets = [],
        signedOutCount = 0,
        goneCount = 0;

  late SessionStream stream;
  late FakeScheduler sched;
  final List<int> events;
  final List<String> controls;
  final List<StreamStatus> states;
  final List<ResyncReason> resyncs;
  final List<FakeSocket> sockets;
  int signedOutCount;
  int goneCount;

  FakeSocket get last => sockets.last;
}

Rig rig({
  String gwId = 'abc',
  int? after,
  double Function()? random,
  StreamTuning? tuning,
}) {
  final r = Rig();
  r.sched = FakeScheduler();
  r.stream = SessionStream(
    gwId: gwId,
    baseUrl: 'http://gw.test',
    token: 'sekret-token',
    after: after,
    tuning: tuning,
    random: random ?? () => 0.5,
    socketFactory: (url, headers) async {
      final s = FakeSocket(url, headers);
      r.sockets.add(s);
      return s;
    },
    scheduler: r.sched,
    handlers: StreamHandlers(
      onEvent: (e, seq) => r.events.add(seq),
      onControl: (c) => r.controls.add(strOf(c, 'type') ?? ''),
      onState: (s) => r.states.add(s),
      onResync: (reason) => r.resyncs.add(reason),
      onSignedOut: () => r.signedOutCount += 1,
      onGone: () => r.goneCount += 1,
    ),
  );
  return r;
}

Map<String, Object?> ev([String type = 'agent_start']) => {'type': type};

const settle = 1; // marker comment; pumps happen via sched.micro()/elapse()

void main() {
  group('connecting', () {
    test('opens /omp-ws/{id}?after={cursor} on the gateway origin', () async {
      final r = rig(gwId: 'a b', after: 12);
      r.stream.start();
      await r.sched.micro();
      expect(r.last.url.toString(), 'ws://gw.test/omp-ws/a%20b?after=12');
      expect(r.stream.state, StreamState.connecting);
      r.stream.stop();
    });

    test('is live after auth_ok and hands the snapshot to onControl',
        () async {
      final r = rig();
      r.stream.start();
      await r.sched.micro();
      r.last.authOk();
      expect(r.stream.state, StreamState.live);
      expect(r.controls, ['auth_ok']);
      expect(
          r.states.map((s) => s.state).toList(),
          equals(
              [StreamState.connecting, StreamState.live]));
      r.stream.stop();
    });

    test('ignores a second start()', () async {
      final r = rig();
      r.stream.start();
      r.stream.start();
      await r.sched.micro();
      expect(r.sockets, hasLength(1));
      r.stream.stop();
    });

    test('sends only while the socket is open', () async {
      final r = rig();
      r.stream.start();
      await r.sched.micro();
      expect(r.stream.send({'type': 'ping'}), isFalse);
      r.last.authOk();
      expect(r.stream.send({'type': 'get_state'}), isTrue);
      expect(r.stream.send('ping'), isTrue);
      expect(r.last.sent, ['{"type":"get_state"}', 'ping']);
      r.stream.stop();
    });

    test('bearer header rides the upgrade and the token never hits the URL',
        () async {
      final r = rig(gwId: 'a b', after: 1);
      r.stream.start();
      await r.sched.micro();
      expect(r.last.headers['Authorization'], 'Bearer sekret-token');
      expect(r.last.url.toString().contains('sekret-token'), isFalse);
      expect(r.last.url.queryParameters.containsKey('token'), isFalse);
      r.stream.stop();
    });
  });

  group('frames and the resume cursor', () {
    test('delivers events in order and drops anything at or below the cursor',
        () async {
      final r = rig(after: 5);
      r.stream.start();
      await r.sched.micro();
      r.last.authOk();
      r.last.frame(5, ev());
      r.last.frame(6, ev('turn_start'));
      r.last.frame(6, ev('turn_start'));
      r.last.frame(9, ev('turn_end'));
      r.last.frame(7, ev('late'));
      expect(r.events, [6, 9]);
      expect(r.stream.lastSeq, 9);
      r.stream.stop();
    });

    test('routes control frames and swallows heartbeat and pong', () async {
      final r = rig();
      r.stream.start();
      await r.sched.micro();
      r.last.authOk();
      r.last.frame(0, {'type': 'heartbeat'});
      r.last.frame(0, {'type': 'pong'});
      r.last.frame(0, {'type': 'ws_error', 'error': 'nope'});
      r.last.frame(0, {'type': 'rpc_response', 'success': true});
      expect(r.controls, ['auth_ok', 'ws_error', 'rpc_response']);
      expect(r.events, isEmpty);
      r.stream.stop();
    });

    test('ignores malformed frames', () async {
      final r = rig();
      r.stream.start();
      await r.sched.micro();
      r.last.authOk();
      r.last.raw('not json');
      r.last.raw('{"seq":3}');
      r.last.raw('{"seq":3,"event":{}}');
      r.last.raw('["seq",3]');
      r.last.raw('{"seq":"3","event":{"type":"agent_start"}}');
      expect(r.events, isEmpty);
      r.stream.stop();
    });

    test('resumes after the last delivered seq and never repeats a seq',
        () async {
      final r = rig();
      r.stream.start();
      await r.sched.micro();
      r.last.authOk();
      r.last.frame(1, ev());
      r.last.frame(2, ev());
      r.last.serverClose(1006);
      await r.sched.elapse(500);
      expect(r.sockets, hasLength(2));
      expect(r.last.url.toString(), contains('?after=2'));
      r.last.authOk();
      r.last.frame(2, ev());
      r.last.frame(3, ev());
      // Dedupe across the reconnect: seq 2 must have been applied exactly once.
      expect(r.events, [1, 2, 3]);
      expect(r.stream.lastSeq, 3);
      r.stream.stop();
    });
  });

  group('reconnect backoff', () {
    test('uses full-jitter exponential backoff with a 30 s cap', () async {
      final r = rig(random: () => 0.999);
      r.stream.start();
      await r.sched.micro();
      final delays = <int>[];
      for (var i = 0; i < 8; i++) {
        r.last.serverClose(1006);
        final at = r.stream.retryAt!;
        delays.add(at - r.sched.clock.millisecondsSinceEpoch);
        expect(r.stream.state, StreamState.retrying);
        await r.sched.elapse(at - r.sched.clock.millisecondsSinceEpoch);
        expect(r.stream.state, StreamState.connecting);
      }
      expect(delays, [999, 1998, 3996, 7992, 15984, 29970, 29970, 29970]);
      r.stream.stop();
    });

    test('spreads the delay across [0, cap)', () async {
      final r = rig(random: () => 0);
      r.stream.start();
      await r.sched.micro();
      r.last.serverClose(1006);
      expect(r.stream.retryAt, r.sched.clock.millisecondsSinceEpoch);
      r.stream.stop();
    });

    test('counts a close within 5 s of auth_ok as a failure and keeps backing off',
        () async {
      final r = rig();
      r.stream.start();
      await r.sched.micro();
      r.last.serverClose(1006);
      expect(r.stream.retryAt! - r.sched.clock.millisecondsSinceEpoch, 500);
      await r.sched.elapse(500);
      r.last.authOk();
      await r.sched.elapse(4900);
      r.last.serverClose(1006);
      expect(r.stream.retryAt! - r.sched.clock.millisecondsSinceEpoch, 1000);
      await r.sched.elapse(1000);
      r.last.authOk();
      await r.sched.elapse(4900);
      r.last.serverClose(1006);
      expect(r.stream.retryAt! - r.sched.clock.millisecondsSinceEpoch, 2000);
      r.stream.stop();
    });

    test('resets the counter once a socket has stayed open for 5 s', () async {
      final r = rig();
      r.stream.start();
      await r.sched.micro();
      r.last.serverClose(1006);
      await r.sched.elapse(500);
      r.last.serverClose(1006);
      await r.sched.elapse(1000);
      r.last.authOk();
      await r.sched.elapse(5000);
      r.last.serverClose(1006);
      expect(r.stream.retryAt! - r.sched.clock.millisecondsSinceEpoch, 500);
      r.stream.stop();
    });

    test('waits for resume instead of retrying in the background', () async {
      final r = rig();
      r.stream.start();
      await r.sched.micro();
      r.last.authOk();
      r.stream.pause();
      expect(r.stream.state, StreamState.offline);
      expect(r.last.closed, isTrue);
      await r.sched.elapse(120000);
      expect(r.sockets, hasLength(1));
      r.stream.resume();
      await r.sched.micro();
      expect(r.sockets, hasLength(2));
      expect(r.stream.state, StreamState.connecting);
      expect(r.resyncs, isEmpty);
      r.stream.stop();
    });

    test('reconnects when connectivity returns after a wait', () async {
      final r = rig();
      r.stream.start();
      await r.sched.micro();
      r.last.authOk();
      r.stream.pause();
      await r.sched.elapse(30000);
      expect(r.sockets, hasLength(1));
      r.stream.networkAvailable();
      await r.sched.micro();
      // Still paused: only resume brings the socket back.
      expect(r.sockets, hasLength(1));
      r.stream.resume();
      await r.sched.micro();
      expect(r.sockets, hasLength(2));
      r.stream.stop();
    });

    test('reconnects immediately on networkAvailable while a retry is pending',
        () async {
      final r = rig(random: () => 0.999);
      r.stream.start();
      await r.sched.micro();
      r.last.serverClose(1006);
      expect(r.stream.state, StreamState.retrying);
      r.stream.networkAvailable();
      await r.sched.micro();
      expect(r.sockets, hasLength(2));
      expect(r.stream.state, StreamState.connecting);
      r.stream.stop();
    });

    test('does nothing on networkAvailable while live', () async {
      final r = rig();
      r.stream.start();
      await r.sched.micro();
      r.last.authOk();
      r.stream.networkAvailable();
      await r.sched.micro();
      expect(r.sockets, hasLength(1));
      expect(r.resyncs, isEmpty);
      r.stream.stop();
    });
  });

  group('close codes', () {
    test('4401 signs out and never retries', () async {
      final r = rig();
      r.stream.start();
      await r.sched.micro();
      r.last.authOk();
      r.last.serverClose(4401);
      expect(r.signedOutCount, 1);
      expect(r.stream.state, StreamState.offline);
      await r.sched.elapse(600000);
      expect(r.sockets, hasLength(1));
      r.stream.pause();
      r.stream.resume();
      await r.sched.micro();
      expect(r.sockets, hasLength(1));
    });

    test('4404 reports the session as gone and never retries', () async {
      final r = rig();
      r.stream.start();
      await r.sched.micro();
      r.last.serverClose(4404);
      expect(r.goneCount, 1);
      expect(r.stream.state, StreamState.gone);
      await r.sched.elapse(600000);
      expect(r.sockets, hasLength(1));
      r.stream.networkAvailable();
      r.stream.reconnectNow();
      await r.sched.micro();
      expect(r.sockets, hasLength(1));
      expect(r.stream.state, StreamState.gone);
    });

    test('4408 reconnects at once with the cursor, then backs off if it keeps happening',
        () async {
      final r = rig();
      r.stream.start();
      await r.sched.micro();
      r.last.authOk();
      r.last.frame(4, ev());
      r.last.serverClose(4408);
      expect(r.stream.state, StreamState.retrying);
      await r.sched.elapse(0);
      expect(r.sockets, hasLength(2));
      expect(r.last.url.toString(), contains('after=4'));
      r.last.serverClose(4408);
      expect(r.stream.retryAt! - r.sched.clock.millisecondsSinceEpoch, 1000);
      r.stream.stop();
    });

    test('4429 surfaces the message and retries after a minute, ignoring manual reconnects',
        () async {
      final r = rig();
      r.stream.start();
      await r.sched.micro();
      r.last.serverClose(4429, 'Too many attempts. Try again in 60 s.');
      expect(r.stream.state, StreamState.retrying);
      expect(r.stream.message, 'Too many attempts. Try again in 60 s.');
      expect(r.stream.retryAt! - r.sched.clock.millisecondsSinceEpoch, 60000);
      r.stream.networkAvailable();
      r.stream.reconnectNow();
      await r.sched.elapse(59000);
      expect(r.sockets, hasLength(1));
      await r.sched.elapse(1000);
      expect(r.sockets, hasLength(2));
      r.last.authOk();
      expect(r.stream.message, isNull);
      r.stream.stop();
    });

    test('4429 without a reason still explains itself', () async {
      final r = rig();
      r.stream.start();
      await r.sched.micro();
      r.last.serverClose(4429);
      expect(r.stream.message, matches(RegExp('minute')));
      r.stream.stop();
    });
  });

  group('resync', () {
    test('asks for a resync on auth_ok with gap and holds events until rebase',
        () async {
      final r = rig(after: 3);
      r.stream.start();
      await r.sched.micro();
      r.last.authOk(gap: true);
      expect(r.resyncs, [ResyncReason.gap]);
      r.last.frame(10, ev('turn_start'));
      r.last.frame(11, ev('turn_end'));
      r.last.frame(9, ev('old'));
      expect(r.events, isEmpty);
      r.stream.rebase(10);
      expect(r.events, [11]);
      expect(r.stream.lastSeq, 11);
      r.last.frame(12, ev());
      expect(r.events, [11, 12]);
      r.stream.stop();
    });

    test('releases held events in seq order', () async {
      final r = rig();
      r.stream.start();
      await r.sched.micro();
      r.last.authOk(gap: true);
      r.last.frame(6, ev());
      r.last.frame(5, ev());
      r.last.frame(7, ev());
      r.stream.rebase(4);
      expect(r.events, [5, 6, 7]);
      r.stream.stop();
    });

    test('does not ask twice while a resync is in flight', () async {
      final r = rig();
      r.stream.start();
      await r.sched.micro();
      r.last.authOk(gap: true);
      r.last.serverClose(1006);
      await r.sched.elapse(500);
      r.last.authOk(gap: true);
      expect(r.resyncs, [ResyncReason.gap]);
      r.stream.rebase(0);
      r.last.serverClose(1006);
      await r.sched.elapse(30000);
      r.last.authOk(gap: true);
      expect(r.resyncs, [ResyncReason.gap, ResyncReason.gap]);
      r.stream.stop();
    });

    test('releases held events by itself if the caller never rebases',
        () async {
      final r = rig();
      r.stream.start();
      await r.sched.micro();
      r.last.authOk(gap: true);
      r.last.frame(1, ev());
      await r.sched.elapse(14000);
      r.last.frame(0, {'type': 'heartbeat'});
      expect(r.events, isEmpty);
      await r.sched.elapse(1500);
      expect(r.events, [1]);
      r.stream.stop();
    });

    test('a normal auth_ok does not resync and rebase without a hold is harmless',
        () async {
      final r = rig();
      r.stream.start();
      await r.sched.micro();
      r.last.authOk(gap: false);
      r.stream.rebase(50);
      r.last.frame(50, ev());
      r.last.frame(51, ev());
      expect(r.resyncs, isEmpty);
      expect(r.events, [51]);
      r.stream.stop();
    });

    test('resyncs and replaces the socket after the app was backgrounded for more than 5 minutes',
        () async {
      final r = rig();
      r.stream.start();
      await r.sched.micro();
      r.last.authOk();
      r.last.frame(1, ev());
      r.stream.pause();
      await r.sched.elapse(5 * 60000 + 1000);
      r.stream.resume();
      await r.sched.micro();
      expect(r.resyncs, [ResyncReason.hidden]);
      expect(r.sockets.length, greaterThanOrEqualTo(2));
      expect(r.last.url.toString(), contains('after=1'));
      r.last.authOk();
      r.last.frame(2, ev());
      expect(r.events, [1]);
      r.stream.rebase(2);
      r.last.frame(3, ev());
      expect(r.events, [1, 3]);
      r.stream.stop();
    });

    test('does not resync after a short hide', () async {
      final r = rig();
      r.stream.start();
      await r.sched.micro();
      r.last.authOk();
      r.last.frame(1, ev());
      r.stream.pause();
      await r.sched.elapse(4 * 60000);
      r.stream.resume();
      await r.sched.micro();
      expect(r.resyncs, isEmpty);
      expect(r.sockets, hasLength(2));
      expect(r.last.url.toString(), contains('after=1'));
      r.last.authOk();
      expect(r.stream.state, StreamState.live);
      r.last.frame(2, ev());
      expect(r.events, [1, 2]);
      r.stream.stop();
    });
  });

  group('watchdog', () {
    test('drops and retries a socket that went silent for 60 s', () async {
      final r = rig();
      r.stream.start();
      await r.sched.micro();
      r.last.authOk();
      final first = r.last;
      await r.sched.elapse(59000);
      expect(r.stream.state, StreamState.live);
      await r.sched.elapse(1000);
      expect(first.closed, isTrue);
      expect(r.stream.state, StreamState.retrying);
      await r.sched.elapse(500);
      expect(r.sockets, hasLength(2));
      r.stream.stop();
    });

    test('is kept quiet by heartbeats', () async {
      final r = rig();
      r.stream.start();
      await r.sched.micro();
      r.last.authOk();
      for (var i = 0; i < 10; i++) {
        await r.sched.elapse(30000);
        r.last.frame(0, {'type': 'heartbeat'});
      }
      expect(r.stream.state, StreamState.live);
      expect(r.sockets, hasLength(1));
      r.stream.stop();
    });
  });

  group('stop', () {
    test('closes the socket, cancels retries and ignores late frames',
        () async {
      final r = rig();
      r.stream.start();
      await r.sched.micro();
      r.last.authOk();
      final ws = r.last;
      r.stream.stop();
      expect(ws.closed, isTrue);
      expect(r.stream.state, StreamState.offline);
      ws.serverClose(1006);
      await r.sched.elapse(600000);
      r.stream.networkAvailable();
      await r.sched.micro();
      expect(r.sockets, hasLength(1));
    });

    test('cancels a pending retry', () async {
      final r = rig();
      r.stream.start();
      await r.sched.micro();
      r.last.serverClose(1006);
      r.stream.stop();
      await r.sched.elapse(600000);
      expect(r.sockets, hasLength(1));
    });

    test('can start again after stop and keeps the cursor', () async {
      final r = rig();
      r.stream.start();
      await r.sched.micro();
      r.last.authOk();
      r.last.frame(8, ev());
      r.stream.stop();
      r.stream.start();
      await r.sched.micro();
      expect(r.sockets, hasLength(2));
      expect(r.last.url.toString(), contains('after=8'));
      r.stream.stop();
    });
  });

  group('lifecycle edge cases', () {
    test('pause while retrying cancels the retry timer and resume restarts it',
        () async {
      final r = rig(random: () => 0.999);
      r.stream.start();
      await r.sched.micro();
      r.last.serverClose(1006);
      expect(r.stream.state, StreamState.retrying);
      r.stream.pause();
      expect(r.stream.state, StreamState.offline);
      await r.sched.elapse(600000);
      expect(r.sockets, hasLength(1));
      r.stream.resume();
      await r.sched.micro();
      expect(r.sockets, hasLength(2));
      r.stream.stop();
    });

    test('events arriving while held are released exactly once', () async {
      final r = rig();
      r.stream.start();
      await r.sched.micro();
      r.last.authOk(gap: true);
      r.last.frame(2, ev('a'));
      r.stream.rebase(2); // already at cursor; releases nothing new
      expect(r.events, isEmpty);
      r.last.frame(3, ev('b'));
      r.last.frame(3, ev('b'));
      r.stream.rebase(1);
      expect(r.events, [3]);
      r.stream.stop();
    });
  });

  group('stale connect failures (Gemini findings)', () {
    test('a connect failure from a stale generation schedules nothing', () async {
      final sched = FakeScheduler();
      final sockets = <FakeSocket>[];
      final pending = <Completer<FakeSocket>>[];
      final stream = SessionStream(
        gwId: 'abc',
        baseUrl: 'http://gw.test',
        token: 'tok',
        random: () => 0.5,
        socketFactory: (url, headers) {
          final c = Completer<FakeSocket>();
          pending.add(c);
          return c.future;
        },
        scheduler: sched,
      );
      stream.start();
      await sched.micro();
      expect(pending, hasLength(1));
      stream.reconnectNow(); // bumps _gen and starts attempt #2
      await sched.micro();
      expect(pending, hasLength(2));
      final sock = FakeSocket(Uri.parse('ws://gw.test'), {});
      sockets.add(sock);
      pending[1].complete(sock);
      await sched.micro();
      expect(sockets, hasLength(1));
      sock.authOk();
      // Fail the stale attempt #1: must not schedule a retry.
      pending[0].completeError(StateError('stale handshake failed'));
      await sched.micro();
      // Inside the watchdog window (60 s) but far past any retry delay: if a
      // retry had been scheduled by the stale failure, a socket would open.
      await sched.elapse(59000);
      expect(sockets, hasLength(1));
      expect(stream.state, StreamState.live);
      stream.stop();
    });

    test('pause clears the hold so a later resync can be requested again',
        () async {
      final r = rig();
      r.stream.start();
      await r.sched.micro();
      r.last.authOk(gap: true);
      expect(r.resyncs, [ResyncReason.gap]);
      r.last.frame(10, ev());
      r.stream.pause();
      await r.sched.elapse(30000); // longer than holdTimeoutMs
      r.stream.resume();
      await r.sched.micro();
      // The stale hold was dropped at pause, so a new gap requests a resync
      // instead of being silently swallowed.
      r.last.authOk(gap: true);
      expect(r.resyncs, [ResyncReason.gap, ResyncReason.gap]);
      expect(r.events, isEmpty); // held again, nothing leaked while paused
      r.stream.stop();
    });

    test('the hold timer cannot fire while paused', () async {
      final r = rig(tuning: const StreamTuning(holdTimeoutMs: 1000));
      r.stream.start();
      await r.sched.micro();
      r.last.authOk(gap: true);
      expect(r.resyncs, [ResyncReason.gap]);
      r.last.frame(10, ev());
      r.stream.pause();
      await r.sched.elapse(5000);
      expect(r.events, isEmpty); // released hold never dispatches
      r.stream.resume();
      await r.sched.micro();
      expect(r.events, isEmpty);
      r.stream.stop();
    });

    Rig rigStoppingFromEvent(void Function(Rig r, int seq) action) {
      final r = Rig();
      r.sched = FakeScheduler();
      r.stream = SessionStream(
        gwId: 'abc',
        baseUrl: 'http://gw.test',
        token: 'tok',
        random: () => 0.5,
        socketFactory: (url, headers) async {
          final s = FakeSocket(url, headers);
          r.sockets.add(s);
          return s;
        },
        scheduler: r.sched,
        handlers: StreamHandlers(
          onEvent: (e, seq) {
            r.events.add(seq);
            action(r, seq);
          },
          onState: (s) => r.states.add(s),
          onResync: (reason) => r.resyncs.add(reason),
        ),
      );
      return r;
    }

    test('release stops dispatching when the handler stops the stream',
        () async {
      final r = rigStoppingFromEvent((r, seq) {
        if (seq == 2) r.stream.stop();
      });
      r.stream.start();
      await r.sched.micro();
      r.last.authOk(gap: true);
      r.last.frame(1, ev('a'));
      r.last.frame(2, ev('b'));
      r.last.frame(3, ev('c'));
      r.stream.rebase(0);
      expect(r.events, [1, 2]);
      expect(r.stream.state, StreamState.offline);
    });

    test('release stops dispatching when the handler pauses the stream',
        () async {
      final r = rigStoppingFromEvent((r, seq) {
        if (seq == 2) r.stream.pause();
      });
      r.stream.start();
      await r.sched.micro();
      r.last.authOk(gap: true);
      r.last.frame(1, ev('a'));
      r.last.frame(2, ev('b'));
      r.last.frame(3, ev('c'));
      r.stream.rebase(0);
      expect(r.events, [1, 2]);
      expect(r.stream.state, StreamState.offline);
    });

    test('a control-frame stop cancels the pending gap resync', () async {
      final r = Rig();
      r.sched = FakeScheduler();
      r.stream = SessionStream(
        gwId: 'abc',
        baseUrl: 'http://gw.test',
        token: 'tok',
        random: () => 0.5,
        socketFactory: (url, headers) async {
          final s = FakeSocket(url, headers);
          r.sockets.add(s);
          return s;
        },
        scheduler: r.sched,
        handlers: StreamHandlers(
          onEvent: (e, seq) => r.events.add(seq),
          onResync: (reason) => r.resyncs.add(reason),
        ),
      );
      r.stream.start();
      await r.sched.micro();
      r.last.authOk(gap: true);
      expect(r.resyncs, [ResyncReason.gap]);
      // stop() during the hold must cancel it without dispatching.
      r.last.frame(1, ev());
      r.stream.stop();
      await r.sched.elapse(30000);
      expect(r.events, isEmpty);
    });

    test('cursor is readable; the resume URL tracks it', () async {
      final r = rig(after: 3);
      r.stream.start();
      await r.sched.micro();
      expect(r.stream.cursor, 3);
      r.last.authOk();
      r.last.frame(4, ev());
      expect(r.stream.cursor, 4);
      expect(r.stream.lastSeq, 4);
      r.last.serverClose(1006);
      await r.sched.elapse(500);
      expect(r.last.url.toString(), contains('after=4'));
      r.stream.stop();
    });
  });
}
