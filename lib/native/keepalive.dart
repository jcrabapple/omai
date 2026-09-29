// Task F: Android-native keep-alive. The foreground service itself is a
// small Kotlin piece (android/.../KeepaliveService.kt); this module owns the
// POLICY: when the service runs, what its notification says, and how
// approval notification actions map back to UiAnswer payloads.
//
// Split for testability:
//   - [KeepaliveSurface] is the notification/service boundary. Production
//     talks over a MethodChannel; tests use a fake.
//   - The pure helpers (notification text, approval action mapping) have no
//     Flutter imports.
//   - [KeepaliveCoordinator] is the state machine: background while the open
//     session is running -> service starts and the controller is NOT paused;
//     turn ends / Stop tapped / foreground -> service stops, then the normal
//     background pause applies.

import 'dart:async';

import '../composer/approval.dart' show UiAnswer;
import '../wire/wire.dart' show UiRequest, isBlockingUi;

/// Everything the platform side must do, so tests never touch a channel and
/// nothing here imports Flutter.
abstract class KeepaliveSurface {
  /// POST_NOTIFICATIONS runtime request, at the moment it is first needed.
  /// Returns true when notifications may be posted.
  Future<bool> ensureNotificationPermission();

  /// Start (or restart) the foreground service with the Running notification.
  /// False when Android refused the start (background start restrictions);
  /// the caller must then fall back to pausing.
  Future<bool> showRunning({
    required String gwId,
    required String sessionTitle,
    String? tool,
    required int startedAt,
  });

  /// Update the Running notification text (tool, elapsed).
  Future<void> updateRunning({
    required String sessionTitle,
    String? tool,
    required int startedAt,
  });

  /// Stop the foreground service and clear its notification.
  Future<void> stopRunning();

  /// Post one approval notification. Empty [actions] means: tapping the
  /// notification opens the app on the session.
  Future<void> showApproval({
    required String requestId,
    required String gwId,
    required String title,
    required String body,
    required List<NotificationAction> actions,
  });

  Future<void> cancelApproval(String requestId);
}

/// One notification action button. [id] is echoed back by the platform and
/// resolved to a [UiAnswer] by [answerForAction].
class NotificationAction {
  const NotificationAction(this.id, this.label);

  final String id;
  final String label;
}

/// What the coordinator needs to know about the open session. Decoupled from
/// SessionState so tests build it by hand.
class KeepaliveSnapshot {
  const KeepaliveSnapshot({
    required this.gwId,
    required this.sessionTitle,
    required this.running,
    this.tool,
    this.turnStartedAt,
    this.pendingUi = const <UiRequest>[],
  });

  final String gwId;
  final String sessionTitle;
  final bool running;

  /// Current tool of the running turn, if the header has one.
  final String? tool;

  /// Epoch ms of the agent_start that opened the current turn.
  final int? turnStartedAt;

  final List<UiRequest> pendingUi;
}

// --------------------------------------------------------------- pure text

/// Title of the ongoing notification: `Running: <session title>`.
String runningNotificationTitle(String sessionTitle) =>
    'Running: $sessionTitle';

/// Elapsed-turn fragment: 45s / 3m / 1h 05m.
String formatElapsed(int startedAt, DateTime now) {
  final seconds = (now.millisecondsSinceEpoch - startedAt) ~/ 1000;
  if (seconds < 0) return '0s';
  if (seconds < 60) return '${seconds}s';
  if (seconds < 3600) return '${seconds ~/ 60}m';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  return '${h}h ${m.toString().padLeft(2, '0')}m';
}

/// Body of the ongoing notification: current tool and elapsed time,
/// 'bash - 3m' (no em-dashes, per house copy rules).
String runningNotificationText(String? tool, int startedAt, DateTime now) {
  final elapsed = formatElapsed(startedAt, now);
  final t = tool?.trim() ?? '';
  if (t.isEmpty) return elapsed;
  return '$t - $elapsed';
}

// ------------------------------------------------- approval action mapping

const approveActionId = 'approve';
const denyActionId = 'deny';

/// Extracts the display label of one select option. Options arrive as plain
/// strings or small maps with a value/label field.
String? selectOptionLabel(Object? option) {
  if (option is String) return option;
  if (option is Map) {
    for (final key in const ['label', 'value', 'name', 'title']) {
      final v = option[key];
      if (v is String && v.isNotEmpty) return v;
    }
  }
  return null;
}

Object? _selectOptionValue(Object? option, String fallback) {
  if (option is Map) {
    final v = option['value'];
    if (v is String && v.isNotEmpty) return v;
  }
  if (option is String) return option;
  return fallback;
}

/// Action buttons for one blocking request. Confirm gets Approve / Deny;
/// select with at most three options gets one button per option; anything
/// else (input, editor, big selects) is answered in the app.
List<NotificationAction> approvalActionsFor(UiRequest req) {
  if (!isBlockingUi(req)) return const <NotificationAction>[];
  switch (req.method) {
    case 'confirm':
      return const [
        NotificationAction(approveActionId, 'Approve'),
        NotificationAction(denyActionId, 'Deny'),
      ];
    case 'select':
      final options = req.options ?? const <Object?>[];
      if (options.isEmpty || options.length > 3) {
        return const <NotificationAction>[];
      }
      final out = <NotificationAction>[];
      for (var i = 0; i < options.length; i++) {
        final label = selectOptionLabel(options[i]);
        if (label == null) return const <NotificationAction>[];
        out.add(NotificationAction('opt:$i', label));
      }
      return out;
    default:
      return const <NotificationAction>[];
  }
}

/// Resolves a notification action id against its request, returning the
/// matching `UiAnswer` (see composer/approval.dart) or null when the action
/// cannot be answered from a notification.
UiAnswer? answerForAction(UiRequest req, String actionId) {
  switch (req.method) {
    case 'confirm':
      return UiAnswer.confirmed(actionId == approveActionId);
    case 'select':
      final m = RegExp(r'^opt:(\d+)$').firstMatch(actionId);
      if (m == null) return null;
      final options = req.options ?? const <Object?>[];
      final idx = int.tryParse(m.group(1) ?? '');
      if (idx == null || idx < 0 || idx >= options.length) return null;
      final raw = options[idx];
      final label = selectOptionLabel(raw);
      if (label == null) return null;
      return UiAnswer.value(_selectOptionValue(raw, label).toString());
    default:
      return null;
  }
}

/// Headline for an approval notification: the first line of the request
/// title, else the method name.
String approvalNotificationTitle(UiRequest req) {
  final title = req.title?.trim() ?? '';
  if (title.isNotEmpty) {
    final firstLine = title.split('\n').first.trim();
    if (firstLine.isNotEmpty) return firstLine;
  }
  return req.message?.trim().isNotEmpty == true
      ? req.message!.trim()
      : 'Needs your approval';
}

/// Detail line: the rest of the title (usually the command), else the message.
String approvalNotificationBody(UiRequest req) {
  final title = req.title ?? '';
  final lines = title.replaceAll('\r\n', '\n').split('\n');
  if (lines.length > 1) {
    final rest = lines.sublist(1).join('\n').trim();
    if (rest.isNotEmpty) return rest;
  }
  final message = req.message?.trim() ?? '';
  return message;
}

// ------------------------------------------------------------- coordinator

/// Signature of the pause the coordinator can ask for (controller.pause()).
typedef PauseCallback = void Function();

/// Where notification actions are delivered when the app is backgrounded:
/// the Kotlin side invokes into the app shell, which looks the session up
/// here. Keyed by gateway session id.
class KeepaliveRegistry {
  KeepaliveRegistry._();
  static final Map<String, KeepaliveCoordinator> _byGwId = {};

  static void attach(String gwId, KeepaliveCoordinator c) => _byGwId[gwId] = c;
  static void detach(String gwId) => _byGwId.remove(gwId);
  static KeepaliveCoordinator? forGwId(String gwId) => _byGwId[gwId];
}

class KeepaliveCoordinator {
  KeepaliveCoordinator({
    required this.surface,
    required this.onPause,
    required this.onStopTurn,
    required this.onAnswer,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  final KeepaliveSurface surface;
  final PauseCallback onPause;
  final Future<void> Function() onStopTurn;
  final Future<void> Function(String requestId, UiAnswer answer) onAnswer;
  final DateTime Function() now;

  bool _backgrounded = false;
  bool _serviceActive = false;
  String? _lastTool;
  int _lastUpdateMs = 0;
  Timer? _tick;
  KeepaliveSnapshot? _latest;

  /// Request ids already posted; dedupe per request id and cleared when the
  /// request resolves.
  final Set<String> _approvalNotified = <String>{};

  bool get serviceActive => _serviceActive;
  bool get backgrounded => _backgrounded;

  /// Feed the latest open-session state (called on every controller change).
  void update(KeepaliveSnapshot snapshot) {
    _latest = snapshot;
    if (!_serviceActive) return;
    if (!snapshot.running) {
      unawaited(_turnEnded());
      return;
    }
    _syncApprovals(snapshot);
    if (snapshot.tool != _lastTool) {
      unawaited(_pushUpdate(snapshot));
    }
  }

  /// The app went to the background (AppLifecycleListener.onPause).
  Future<void> appBackgrounded() async {
    _backgrounded = true;
    final s = _latest;
    if (s == null || !s.running) {
      // Nothing to keep alive: today's behavior, pause the controller.
      onPause();
      return;
    }
    if (!await surface.ensureNotificationPermission()) {
      onPause();
      return;
    }
    final started = await surface.showRunning(
      gwId: s.gwId,
      sessionTitle: s.sessionTitle,
      tool: s.tool,
      startedAt: s.turnStartedAt ?? now().millisecondsSinceEpoch,
    );
    if (!started) {
      // Android refused the foreground service: nothing keeps the process
      // alive, so behave exactly like an idle background.
      onPause();
      return;
    }
    if (!_backgrounded) {
      // Came back to the foreground while the start was in flight.
      await surface.stopRunning();
      return;
    }
    _serviceActive = true;
    _lastTool = s.tool;
    _lastUpdateMs = now().millisecondsSinceEpoch;
    _syncApprovals(s);
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_onTick());
    });
  }

  /// The app came back (onResume): the UI takes over.
  Future<void> appForegrounded() async {
    _backgrounded = false;
    await _stopService();
  }

  /// Android stopped the service itself (dataSync time budget exhausted).
  /// The process is no longer protected: pause like an idle background.
  Future<void> systemStopped() async {
    final wasActive = _serviceActive;
    _tick?.cancel();
    _tick = null;
    _serviceActive = false;
    final notified = _approvalNotified.toList();
    _approvalNotified.clear();
    for (final id in notified) {
      await surface.cancelApproval(id);
    }
    if (wasActive && _backgrounded) onPause();
  }

  /// The user tapped Stop on the notification.
  Future<void> stopPressed() async {
    await onStopTurn();
    final wasBackgrounded = _backgrounded;
    await _stopService();
    if (wasBackgrounded) onPause();
  }

  /// The user tapped Approve / Deny / an option on an approval notification.
  Future<void> approvalPressed(String requestId, String actionId) async {
    final s = _latest;
    UiRequest? req;
    if (s != null) {
      for (final u in s.pendingUi) {
        if (u.id == requestId) req = u;
      }
    }
    final answer = req == null ? null : answerForAction(req, actionId);
    if (answer == null) return;
    await surface.cancelApproval(requestId);
    _approvalNotified.remove(requestId);
    try {
      await onAnswer(requestId, answer);
    } catch (_) {
      // answered from a notification: failures surface in the app
    }
  }

  Future<void> dispose() async {
    await _stopService();
  }

  // ------------------------------------------------------------- internals

  Future<void> _onTick() async {
    final s = _latest;
    if (!_serviceActive || s == null || !s.running) return;
    // Throttle to ~5s even if ticks pile up.
    final nowMs = now().millisecondsSinceEpoch;
    if (nowMs - _lastUpdateMs < 4500) return;
    await _pushUpdate(s);
  }

  Future<void> _pushUpdate(KeepaliveSnapshot s) async {
    _lastTool = s.tool;
    _lastUpdateMs = now().millisecondsSinceEpoch;
    await surface.updateRunning(
      sessionTitle: s.sessionTitle,
      tool: s.tool,
      startedAt: s.turnStartedAt ?? now().millisecondsSinceEpoch,
    );
  }

  Future<void> _turnEnded() async {
    final wasBackgrounded = _backgrounded;
    await _stopService();
    if (wasBackgrounded) onPause();
  }

  Future<void> _stopService() async {
    _tick?.cancel();
    _tick = null;
    if (!_serviceActive) return;
    _serviceActive = false;
    final notified = _approvalNotified.toList();
    _approvalNotified.clear();
    for (final id in notified) {
      await surface.cancelApproval(id);
    }
    await surface.stopRunning();
  }

  void _syncApprovals(KeepaliveSnapshot s) {
    if (!_backgrounded) return; // the approval UI is on screen instead
    final blocking = [
      for (final u in s.pendingUi)
        if (isBlockingUi(u)) u,
    ];
    final current = {for (final u in blocking) u.id};
    for (final u in blocking) {
      if (_approvalNotified.contains(u.id)) continue;
      _approvalNotified.add(u.id);
      unawaited(
        surface.showApproval(
          requestId: u.id,
          gwId: s.gwId,
          title: approvalNotificationTitle(u),
          body: approvalNotificationBody(u),
          actions: approvalActionsFor(u),
        ),
      );
    }
    for (final id
        in _approvalNotified.where((id) => !current.contains(id)).toList()) {
      _approvalNotified.remove(id);
      unawaited(surface.cancelApproval(id));
    }
  }
}
