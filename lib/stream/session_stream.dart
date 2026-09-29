// WebSocket transport for one open session, ported from
// web/src/lib/api/stream.ts. Owns the resume cursor, dedupe by seq,
// reconnect with full-jitter backoff, the stable-open rule, the heartbeat
// watchdog, and the pause/resume/network handling that replaces browser
// visibility/online events. UI code never touches WebSocket.
//
// No Flutter imports; socket, clock and random are injected so tests are
// deterministic.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show WebSocket, WebSocketException;
import 'dart:math' show Random;

import '../wire/wire.dart';
import 'scheduler.dart';

enum StreamState { connecting, live, retrying, offline, gone }

enum ResyncReason { gap, hidden }

class StreamStatus {
  const StreamStatus({required this.state, required this.retryAt, this.message});

  final StreamState state;

  /// Epoch ms of the next attempt while `retrying`, else null.
  final int? retryAt;

  /// Human-readable note, e.g. the lockout message from a 4429 close. Cleared
  /// once live.
  final String? message;

  @override
  bool operator ==(Object other) =>
      other is StreamStatus &&
      other.state == state &&
      other.retryAt == retryAt &&
      other.message == message;

  @override
  int get hashCode => Object.hash(state, retryAt, message);

  @override
  String toString() => 'StreamStatus($state, retryAt: $retryAt, message: $message)';
}

/// One open socket. The real implementation wraps `dart:io` WebSocket;
/// tests use a fake.
abstract class StreamSocket {
  /// 0 connecting, 1 open, 3 closed, mirroring the browser readyState values.
  int get readyState;

  void send(String data);
  void close();

  /// A text frame from the server.
  void Function(String data)? onData;

  /// The server (or the transport) closed the socket.
  void Function(int code, String reason)? onClosed;
}

/// Opens the connection. [headers] carry the bearer token on the upgrade;
/// the token must never travel in the URL.
typedef SocketFactory = Future<StreamSocket> Function(
    Uri url, Map<String, String> headers);

class StreamHandlers {
  const StreamHandlers({
    this.onEvent,
    this.onControl,
    this.onState,
    this.onResync,
    this.onSignedOut,
    this.onGone,
  });

  /// An omp event with seq > 0, delivered once, in order.
  final void Function(OmpEvent event, int seq)? onEvent;

  /// `auth_ok` (session snapshot), `ws_error`, `rpc_response`. Heartbeats and
  /// pongs are swallowed.
  final void Function(Map<String, Object?> frame)? onControl;

  final void Function(StreamStatus status)? onState;

  /// Local state may be stale (backlog gap, or the app was backgrounded for a
  /// long time). Refetch state and messages, then call `stream.rebase(...)`.
  final void Function(ResyncReason reason)? onResync;

  /// Close code 4401. The stream stops.
  final void Function()? onSignedOut;

  /// Close code 4404: the session is not running. The stream stops.
  final void Function()? onGone;
}

class StreamTuning {
  const StreamTuning({
    this.baseDelayMs = 1000,
    this.capDelayMs = 30000,
    this.stableMs = 5000,
    this.watchdogMs = 60000,
    this.hiddenResyncMs = 5 * 60000,
    this.lockoutRetryMs = 60000,
    this.holdTimeoutMs = 15000,
  });

  final int baseDelayMs;
  final int capDelayMs;

  /// A socket must stay open this long after auth_ok before the attempt
  /// counter resets.
  final int stableMs;

  /// No frame for this long while live: assume the socket is dead.
  final int watchdogMs;

  /// Paused longer than this: resync instead of trusting the delta.
  final int hiddenResyncMs;
  final int lockoutRetryMs;

  /// Safety valve: release held events if the caller never rebases.
  final int holdTimeoutMs;
}

const defaultTuning = StreamTuning();

const _watchdogTickMs = 5000;

class SessionStream {
  SessionStream({
    required this.gwId,
    required String baseUrl,
    required String token,
    int? after,
    StreamTuning? tuning,
    this.handlers = const StreamHandlers(),
    double Function()? random,
    SocketFactory? socketFactory,
    Scheduler? scheduler,
  })  : _wsBase = _wsOrigin(baseUrl),
        _cursor = after ?? 0,
        // A named parameter cannot be private, so `this._token` is impossible.
        // ignore: prefer_initializing_formals
        _token = token,
        _tune = tuning ?? defaultTuning,
        _random = random ?? _defaultRandom,
        _makeSocket = socketFactory ?? ioSocketFactory,
        _sched = scheduler ?? const SystemScheduler();

  final String gwId;
  final StreamHandlers handlers;
  final String _token;
  int _cursor;

  final String _wsBase;
  final StreamTuning _tune;
  final double Function() _random;
  final SocketFactory _makeSocket;
  final Scheduler _sched;

  StreamStatus _status =
      const StreamStatus(state: StreamState.offline, retryAt: null, message: null);

  StreamSocket? _ws;
  bool _started = false;
  bool _paused = false;
  int? _pausedAt;
  int _attempts = 0;
  int _lastFrameAt = 0;
  int _lockedUntil = 0;
  int _gen = 0;
  Map<int, OmpEvent>? _held;

  CancelTimer? _retryTimer;
  CancelTimer? _stableTimer;
  CancelTimer? _holdTimer;
  CancelTimer? _watchdog;

  int get lastSeq => _cursor;

  /// Read-only view of the resume cursor for state controllers.
  int get cursor => _cursor;
  StreamState get state => _status.state;
  int? get retryAt => _status.retryAt;
  String? get message => _status.message;
  StreamStatus get status => _status;

  /// Open `/omp-ws/{id}?after={cursor}` and start the session loop.
  void start() {
    if (_started) return;
    _started = true;
    _paused = false;
    _pausedAt = null;
    _connect();
  }

  void stop() {
    _started = false;
    _paused = false;
    _pausedAt = null;
    _gen++;
    _clearRetry();
    _clearLive();
    _clearHold();
    _held = null;
    _dropSocket();
    if (_status.state != StreamState.gone) {
      _setStatus(StreamState.offline, null, null);
    }
  }

  /// App went to the background: drop the socket, remember when, and wait.
  void pause() {
    if (!_started) return;
    _paused = true;
    _pausedAt = _ms();
    _clearRetry();
    _clearLive();
    _clearHold();
    _held = null;
    _dropSocket();
    if (_status.state != StreamState.gone) {
      _setStatus(StreamState.offline, null, _status.message);
    }
  }

  /// App came back to the foreground. If it was away longer than
  /// [StreamTuning.hiddenResyncMs] local state may be stale: ask for a resync.
  void resume() {
    if (!_started || !_paused) return;
    final hiddenFor =
        _pausedAt == null ? 0 : _ms() - _pausedAt!;
    _paused = false;
    _pausedAt = null;
    if (hiddenFor > _tune.hiddenResyncMs) {
      _requestResync(ResyncReason.hidden);
      // The socket may be a zombie after a long freeze: replace it.
      reconnectNow();
      return;
    }
    _wake();
  }

  /// Connectivity came back: reconnect now if we were waiting.
  void networkAvailable() {
    if (_started) _wake();
  }

  /// Reconnect immediately with the current cursor, unless the gateway has
  /// locked us out.
  void reconnectNow() {
    if (!_started ||
        _paused ||
        _status.state == StreamState.gone ||
        _ms() < _lockedUntil) {
      return;
    }
    _clearRetry();
    _clearLive();
    _dropSocket();
    _connect();
  }

  /// Call after refetching state and messages in response to `onResync` (or
  /// any time the caller holds a snapshot taken at [seq]). Raises the cursor
  /// and releases held events.
  void rebase(int seq) {
    if (seq > _cursor) _cursor = seq;
    _release();
  }

  /// Send a client frame (a JSON-able RpcCommand, `"ping"`, ...). False when
  /// the socket is not open.
  bool send(Object? frame) {
    final ws = _ws;
    if (ws == null || ws.readyState != 1) return false;
    ws.send(frame is String ? frame : jsonEncode(frame));
    return true;
  }

  // ------------------------------------------------------------- connection

  void _connect() {
    if (!_started) return;
    _clearRetry();
    _setStatus(StreamState.connecting, null, _status.message);
    final url = Uri.parse(
        '$_wsBase/omp-ws/${Uri.encodeComponent(gwId)}?after=$_cursor');
    _gen++;
    final gen = _gen;
    _makeSocket(url, _headers()).then((sock) {
      if (gen != _gen || !_started) {
        sock.close();
        return;
      }
      _ws = sock;
      sock.onData = (data) {
        if (identical(_ws, sock)) _onFrame(data);
      };
      sock.onClosed = (code, reason) {
        if (!identical(_ws, sock)) return;
        _ws = null;
        _onClose(code, reason);
      };
    }).catchError((Object e) {
      // A stale generation (reconnectNow/pause/watchdog moved on) must not
      // schedule anything: its retry could later drop the live socket.
      if (gen != _gen || !_started || _paused) return;
      // The gateway closes 4429 BEFORE accepting the upgrade, which uvicorn
      // surfaces as an HTTP 403 on the handshake: route it to the lockout
      // path exactly like a post-accept 4429 close.
      if (_isUpgradeRejectedWith(e, 403)) {
        _enterLockout(null);
        return;
      }
      _scheduleRetry();
    });
  }

  Map<String, String> _headers() => {'Authorization': 'Bearer $_token'};

  /// dart:io rejects a failed websocket upgrade with a [WebSocketException]
  /// whose toString carries the HTTP status:
  /// `WebSocketException: Connection to '...' was not upgraded to websocket,
  /// HTTP status code: 403`.
  static bool _isUpgradeRejectedWith(Object e, int status) =>
      e is WebSocketException &&
      e.toString().endsWith('HTTP status code: $status');

  static String _wsOrigin(String baseUrl) {
    final base = baseUrl.replaceAll(RegExp(r'/+$'), '');
    return base.replaceFirst(RegExp('^http'), 'ws');
  }

  void _dropSocket() {
    final ws = _ws;
    _ws = null;
    _gen++;
    if (ws == null) return;
    ws.onData = null;
    ws.onClosed = null;
    try {
      ws.close();
    } catch (_) {
      // already closing
    }
  }

  void _onClose(int code, String reason) {
    _clearLive();
    if (!_started) return;
    switch (code) {
      case 4401:
        _started = false;
        _setStatus(StreamState.offline, null, null);
        handlers.onSignedOut?.call();
        return;
      case 4404:
        _started = false;
        _setStatus(StreamState.gone, null, null);
        handlers.onGone?.call();
        return;
      case 4429:
        _enterLockout(reason);
        return;
      case 4408:
        // Dropped as a slow consumer: come straight back, but only the first
        // time in a row.
        _scheduleRetry(_attempts == 0 ? 0 : null);
        return;
      default:
        _scheduleRetry();
    }
  }

  void _scheduleRetry([int? fixedDelayMs]) {
    if (!_started) return;
    if (fixedDelayMs == null && _paused) {
      // Wait for resume instead of burning timers in the background.
      _setStatus(StreamState.offline, null, _status.message);
      return;
    }
    final cap = _min(_tune.capDelayMs, _tune.baseDelayMs * _pow2(_attempts));
    final delay = fixedDelayMs ?? (_random() * cap).floor();
    _attempts += 1;
    final retryAt = _ms() + delay;
    _setStatus(StreamState.retrying, retryAt, _status.message);
    _retryTimer = _sched.delay(Duration(milliseconds: delay), () {
      _retryTimer = null;
      _connect();
    });
  }

  /// The gateway rate-limited us (close 4429, or the pre-accept 4429 that
  /// surfaces as HTTP 403 on the upgrade): back off for a minute.
  void _enterLockout(String? reason) {
    _lockedUntil = _ms() + _tune.lockoutRetryMs;
    _status = StreamStatus(
      state: _status.state,
      retryAt: _status.retryAt,
      message: reason?.isNotEmpty == true
          ? reason
          : 'Too many failed attempts. Retrying in a minute.',
    );
    _scheduleRetry(_tune.lockoutRetryMs);
  }

  // ---------------------------------------------------------------- frames

  void _onFrame(String data) {
    _lastFrameAt = _ms();
    Map<String, Object?>? d;
    try {
      final decoded = jsonDecode(data);
      d = mapOf(decoded);
    } on FormatException {
      return;
    }
    if (d == null) return;
    final ev = mapOf(d['event'] ?? <String, Object?>{});
    if (ev == null || ev['type'] is! String) return;
    final event = OmpEvent(ev);
    final seqField = d['seq'];
    final seq = seqField is num ? seqField.toInt() : 0;

    if (seq > 0) {
      if (seq <= _cursor) return;
      if (_held != null) {
        _held![seq] = event;
        return;
      }
      _cursor = seq;
      handlers.onEvent?.call(event, seq);
      return;
    }

    switch (ev['type'] as String) {
      case 'auth_ok':
        _onAuthOk(ev);
        return;
      case 'heartbeat':
      case 'pong':
        return;
      default:
        handlers.onControl?.call(ev);
    }
  }

  void _onAuthOk(Map<String, Object?> frame) {
    _setStatus(StreamState.live, null, null);
    _clearLive();
    // A retry from an earlier attempt may still be pending: going live
    // cancels it, or its fire would drop this healthy socket.
    _clearRetry();
    _lastFrameAt = _ms();
    _stableTimer = _sched.delay(Duration(milliseconds: _tune.stableMs), () {
      _stableTimer = null;
      _attempts = 0;
    });
    _watchdog =
        _sched.period(Duration(milliseconds: _watchdogTickMs), _checkWatchdog);
    handlers.onControl?.call(frame);
    if (frame['gap'] == true && _started && !_paused) {
      _requestResync(ResyncReason.gap);
    }
  }

  void _checkWatchdog() {
    if (_status.state != StreamState.live ||
        _ms() - _lastFrameAt < _tune.watchdogMs) {
      return;
    }
    _clearLive();
    _dropSocket();
    _scheduleRetry();
  }

  // ---------------------------------------------------------------- resync

  void _requestResync(ResyncReason reason) {
    if (!_started || _paused || _held != null) return;
    _held = <int, OmpEvent>{};
    _holdTimer = _sched.delay(
        Duration(milliseconds: _tune.holdTimeoutMs), _release);
    handlers.onResync?.call(reason);
  }

  void _release() {
    _clearHold();
    final buf = _held;
    _held = null;
    if (buf == null) return;
    final seqs = buf.keys.toList()..sort();
    for (final seq in seqs) {
      // stop()/pause() during dispatch drops the rest of the buffer.
      if (!_started || _paused) break;
      if (seq <= _cursor) continue;
      _cursor = seq;
      handlers.onEvent?.call(buf[seq]!, seq);
    }
  }

  // ---------------------------------------------------------------- helpers

  void _wake() {
    final s = _status.state;
    if (s == StreamState.retrying || s == StreamState.offline) {
      reconnectNow();
    }
  }

  int _ms() => _sched.now().millisecondsSinceEpoch;

  void _setStatus(StreamState state, int? retryAt, String? message) {
    final next =
        StreamStatus(state: state, retryAt: retryAt, message: message);
    if (_status == next) return;
    _status = next;
    handlers.onState?.call(_status);
  }

  void _clearRetry() {
    _retryTimer?.call();
    _retryTimer = null;
  }

  void _clearLive() {
    _stableTimer?.call();
    _watchdog?.call();
    _stableTimer = null;
    _watchdog = null;
  }

  void _clearHold() {
    _holdTimer?.call();
    _holdTimer = null;
  }
}

int _pow2(int n) {
  var v = 1;
  for (var i = 0; i < n && v < 1 << 30; i++) {
    v *= 2;
  }
  return v;
}

int _min(int a, int b) => a < b ? a : b;

double _defaultRandom() => Random().nextDouble();

/// The real dart:io socket factory: opens `/omp-ws/{id}` with the bearer
/// header. The single implementation; consumers inject it (or a fake).
Future<StreamSocket> ioSocketFactory(
    Uri url, Map<String, String> headers) async {
  final ws = await WebSocket.connect(url.toString(), headers: headers);
  return _IoStreamSocket(ws);
}

class _IoStreamSocket implements StreamSocket {
  _IoStreamSocket(this._ws) {
    _ws.listen(
      (data) {
        if (!attached) return;
        if (data is String) onData?.call(data);
      },
      onDone: () {
        if (!attached) return;
        attached = false;
        // The gateway accepts the upgrade before closing with 4401/4404/4408,
        // so those codes arrive here as closeCode. 4429 is sent before accept
        // and surfaces as a connect error (generic retry). No close frame at
        // all (network drop) reads as 1006, like a browser.
        onClosed?.call(_ws.closeCode ?? 1006, _ws.closeReason ?? '');
      },
      onError: (Object _) {
        // onDone follows.
      },
      cancelOnError: true,
    );
  }

  final WebSocket _ws;
  bool attached = true;

  @override
  int get readyState => _ws.readyState == WebSocket.open ? 1 : 3;

  @override
  void Function(String data)? onData;

  @override
  void Function(int code, String reason)? onClosed;

  @override
  void send(String data) {
    _ws.add(data);
  }

  @override
  void close() {
    attached = false;
    _ws.close();
  }
}
