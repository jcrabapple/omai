// Task F keep-alive policy: the coordinator state machine with a fake
// notification surface, plus the pure notification/approval builders.

import 'package:ohmypi/composer/approval.dart';
import 'package:ohmypi/native/keepalive.dart';
import 'package:ohmypi/wire/wire.dart';
import 'package:flutter_test/flutter_test.dart';

class RecordedCall {
  RecordedCall(this.op, this.args);
  final String op;
  final Map<String, Object?> args;
}

class FakeSurface implements KeepaliveSurface {
  FakeSurface({this.permissionGranted = true, this.startAllowed = true});

  bool permissionGranted;

  /// False simulates Android refusing the foreground-service start.
  bool startAllowed;
  final List<RecordedCall> calls = [];

  List<RecordedCall> get running =>
      _filter(const ['showRunning', 'updateRunning', 'stopRunning']);
  List<RecordedCall> get approvals =>
      _filter(const ['showApproval', 'cancelApproval']);

  List<RecordedCall> _filter(List<String> ops) => [
    for (final c in calls)
      if (ops.contains(c.op)) c,
  ];

  int count(String op) => [
    for (final c in calls)
      if (c.op == op) c,
  ].length;

  @override
  Future<bool> ensureNotificationPermission() async {
    calls.add(RecordedCall('permission', const {}));
    return permissionGranted;
  }

  @override
  Future<bool> showRunning({
    required String gwId,
    required String sessionTitle,
    String? tool,
    required int startedAt,
  }) async {
    calls.add(
      RecordedCall('showRunning', {
        'gwId': gwId,
        'title': runningNotificationTitle(sessionTitle),
        'text': runningNotificationText(tool, startedAt, now()),
      }),
    );
    return startAllowed;
  }

  @override
  Future<void> updateRunning({
    required String sessionTitle,
    String? tool,
    required int startedAt,
  }) async {
    calls.add(
      RecordedCall('updateRunning', {
        'title': runningNotificationTitle(sessionTitle),
        'text': runningNotificationText(tool, startedAt, now()),
      }),
    );
  }

  @override
  Future<void> stopRunning() async {
    calls.add(RecordedCall('stopRunning', const {}));
  }

  @override
  Future<void> showApproval({
    required String requestId,
    required String gwId,
    required String title,
    required String body,
    required List<NotificationAction> actions,
  }) async {
    calls.add(
      RecordedCall('showApproval', {
        'requestId': requestId,
        'title': title,
        'body': body,
        'actions': [for (final a in actions) '${a.id}:${a.label}'],
      }),
    );
  }

  @override
  Future<void> cancelApproval(String requestId) async {
    calls.add(RecordedCall('cancelApproval', {'requestId': requestId}));
  }

  DateTime now() => DateTime.fromMillisecondsSinceEpoch(nowMs);
  int nowMs = 1_000_000_000;
}

KeepaliveSnapshot snapshot({
  bool running = false,
  String? tool,
  List<UiRequest> pendingUi = const [],
}) {
  return KeepaliveSnapshot(
    gwId: 's1',
    sessionTitle: 'fix the bug',
    running: running,
    tool: tool,
    turnStartedAt: 1_000_000_000,
    pendingUi: pendingUi,
  );
}

class Harness {
  Harness({bool permission = true, bool startAllowed = true}) {
    surface = FakeSurface(
      permissionGranted: permission,
      startAllowed: startAllowed,
    );
    final pauses = <int>[];
    coordinator = KeepaliveCoordinator(
      surface: surface,
      onPause: () => pauses.add(1),
      onStopTurn: () async => stops++,
      onAnswer: (requestId, answer) async {
        answers[requestId] = answer;
      },
      now: surface.now,
    );
    this.pauses = pauses;
  }

  late FakeSurface surface;
  late KeepaliveCoordinator coordinator;
  late List<int> pauses;
  int stops = 0;
  final Map<String, UiAnswer> answers = {};

  UiAnswer? answer(String requestId) => answers[requestId];
}

UiRequest confirmReq(String id) => UiRequest({
  'id': id,
  'method': 'confirm',
  'title': 'Run command\ngit push',
});

UiRequest selectReq(String id, List<Object?> options) => UiRequest({
  'id': id,
  'method': 'select',
  'title': 'Pick one',
  'options': options,
});

void main() {
  group('keepalive policy', () {
    test(
      'background while running: service starts, controller is NOT paused',
      () async {
        final h = Harness();
        h.coordinator.update(snapshot(running: true, tool: 'bash'));
        await h.coordinator.appBackgrounded();
        expect(h.surface.count('showRunning'), 1);
        expect(h.pauses, isEmpty);
        expect(h.coordinator.serviceActive, isTrue);
        expect(h.surface.running.first.args['title'], 'Running: fix the bug');
      },
    );

    test('background while idle: controller pauses, no service', () async {
      final h = Harness();
      h.coordinator.update(snapshot(running: false));
      await h.coordinator.appBackgrounded();
      expect(h.pauses, hasLength(1));
      expect(h.surface.running, isEmpty);
      expect(h.coordinator.serviceActive, isFalse);
    });

    test('turn ends while backgrounded: service stops, then pause', () async {
      final h = Harness();
      h.coordinator.update(snapshot(running: true, tool: 'bash'));
      await h.coordinator.appBackgrounded();
      h.coordinator.update(snapshot(running: false));
      await Future<void>.delayed(Duration.zero);
      expect(h.surface.count('stopRunning'), 1);
      expect(h.pauses, hasLength(1));
      expect(h.coordinator.serviceActive, isFalse);
    });

    test('returning to foreground stops the service without pausing', () async {
      final h = Harness();
      h.coordinator.update(snapshot(running: true));
      await h.coordinator.appBackgrounded();
      await h.coordinator.appForegrounded();
      expect(h.surface.count('stopRunning'), 1);
      expect(h.pauses, isEmpty);
      expect(h.coordinator.serviceActive, isFalse);
    });

    test(
      'Stop on the notification aborts, stops the service and pauses',
      () async {
        final h = Harness();
        h.coordinator.update(snapshot(running: true));
        await h.coordinator.appBackgrounded();
        await h.coordinator.stopPressed();
        expect(h.stops, 1);
        expect(h.surface.count('stopRunning'), 1);
        expect(h.pauses, hasLength(1));
      },
    );

    test('tool change while running updates the running text', () async {
      final h = Harness();
      h.coordinator.update(snapshot(running: true, tool: 'bash'));
      await h.coordinator.appBackgrounded();
      h.coordinator.update(snapshot(running: true, tool: 'edit'));
      await Future<void>.delayed(Duration.zero);
      final updates = h.surface
          ._filter(const ['updateRunning'])
          .where((c) => c.args['text'] == 'edit - 0s')
          .toList();
      expect(updates, hasLength(1));
    });

    test('permission is asked once, in the foreground, when a turn first runs',
        () async {
      final h = Harness();
      h.coordinator.update(snapshot(running: false));
      expect(h.surface.count('permission'), 0);
      h.coordinator.update(snapshot(running: true));
      h.coordinator.update(snapshot(running: true, tool: 'bash'));
      expect(h.surface.count('permission'), 1);
    });

    test(
      'Android refusing the service start falls back to the pause',
      () async {
        final h = Harness(startAllowed: false);
        h.coordinator.update(snapshot(running: true, tool: 'bash'));
        await h.coordinator.appBackgrounded();
        expect(h.surface.count('showRunning'), 1);
        expect(h.coordinator.serviceActive, isFalse);
        expect(h.pauses, hasLength(1));
      },
    );

    test(
      'foreground during an in-flight start stops the service, no pause',
      () async {
        final h = Harness();
        h.coordinator.update(snapshot(running: true));
        final pending = h.coordinator.appBackgrounded();
        await h.coordinator.appForegrounded();
        await pending;
        expect(h.coordinator.serviceActive, isFalse);
        expect(h.surface.count('stopRunning'), 1);
        expect(h.pauses, isEmpty);
      },
    );

    test(
      'system timeout (dataSync budget) pauses and clears approvals',
      () async {
        final h = Harness();
        h.coordinator.update(
          snapshot(running: true, pendingUi: [confirmReq('r1')]),
        );
        await h.coordinator.appBackgrounded();
        expect(h.surface.count('showApproval'), 1);
        await h.coordinator.systemStopped();
        expect(h.coordinator.serviceActive, isFalse);
        expect(h.surface.count('cancelApproval'), 1);
        expect(h.pauses, hasLength(1));
      },
    );

    test(
      'permission denied falls back to the plain background pause',
      () async {
        final h = Harness(permission: false);
        h.coordinator.update(snapshot(running: true));
        await h.coordinator.appBackgrounded();
        expect(h.coordinator.serviceActive, isFalse);
        expect(h.surface.running, isEmpty);
        expect(h.pauses, hasLength(1));
      },
    );

    test('foreground updates clear the service', () async {
      final h = Harness();
      h.coordinator.update(snapshot(running: true));
      await h.coordinator.appBackgrounded();
      h.coordinator.update(snapshot(running: false));
      await Future<void>.delayed(Duration.zero);
      await h.coordinator.appForegrounded();
      // stopping twice is a no-op the second time
      expect(h.surface.count('stopRunning'), 1);
    });
  });

  group('approval notifications', () {
    test('new blocking request posts once (dedupe per request id)', () async {
      final h = Harness();
      h.coordinator.update(snapshot(running: true));
      await h.coordinator.appBackgrounded();
      final req = confirmReq('u1');
      h.coordinator.update(snapshot(running: true, pendingUi: [req]));
      await Future<void>.delayed(Duration.zero);
      h.coordinator.update(snapshot(running: true, pendingUi: [req]));
      await Future<void>.delayed(Duration.zero);
      expect(h.surface.count('showApproval'), 1);
      final call = h.surface.approvals.first;
      expect(call.args['requestId'], 'u1');
      expect(call.args['title'], 'Run command');
      expect(call.args['body'], 'git push');
      expect(call.args['actions'], contains('approve:Approve'));
      expect(call.args['actions'], contains('deny:Deny'));
    });

    test('resolved request clears its notification', () async {
      final h = Harness();
      h.coordinator.update(snapshot(running: true));
      await h.coordinator.appBackgrounded();
      h.coordinator.update(
        snapshot(running: true, pendingUi: [confirmReq('u1')]),
      );
      await Future<void>.delayed(Duration.zero);
      h.coordinator.update(snapshot(running: true));
      await Future<void>.delayed(Duration.zero);
      expect(h.surface.count('cancelApproval'), 1);
    });

    test(
      'select with at most three options gets one action per option',
      () async {
        final h = Harness();
        h.coordinator.update(snapshot(running: true));
        await h.coordinator.appBackgrounded();
        h.coordinator.update(
          snapshot(
            running: true,
            pendingUi: [
              selectReq('u2', ['yes', 'no', 'maybe']),
            ],
          ),
        );
        await Future<void>.delayed(Duration.zero);
        final call = h.surface.approvals
            .where((c) => c.op == 'showApproval')
            .single;
        expect(call.args['actions'], ['opt:0:yes', 'opt:1:no', 'opt:2:maybe']);
      },
    );

    test('input and editor requests post without actions', () async {
      final actions = approvalActionsFor(
        UiRequest({'id': 'u3', 'method': 'input', 'title': 'Type something'}),
      );
      expect(actions, isEmpty);
      expect(
        approvalActionsFor(
          UiRequest({'id': 'u4', 'method': 'editor', 'title': 'Edit'}),
        ),
        isEmpty,
      );
    });

    test('Approve / Deny map to confirmed true / false', () async {
      final h = Harness();
      h.coordinator.update(snapshot(running: true));
      await h.coordinator.appBackgrounded();
      h.coordinator.update(
        snapshot(running: true, pendingUi: [confirmReq('u1')]),
      );
      await Future<void>.delayed(Duration.zero);
      await h.coordinator.approvalPressed('u1', 'approve');
      await h.coordinator.approvalPressed('u2', 'deny');
      expect(h.answer('u1')?.toMap(), {'confirmed': true});
      final req = confirmReq('u2');
      h.coordinator.update(snapshot(running: true, pendingUi: [req]));
      await Future<void>.delayed(Duration.zero);
      await h.coordinator.approvalPressed('u2', 'deny');
      expect(h.answer('u2')?.toMap(), {'confirmed': false});
    });

    test('select option action maps to the option value', () async {
      final h = Harness();
      h.coordinator.update(snapshot(running: true));
      await h.coordinator.appBackgrounded();
      final req = selectReq('u5', ['alpha', 'beta']);
      h.coordinator.update(snapshot(running: true, pendingUi: [req]));
      await Future<void>.delayed(Duration.zero);
      await h.coordinator.approvalPressed('u5', 'opt:1');
      expect(h.answer('u5')?.toMap(), {'value': 'beta'});
      // The notification is cleared as soon as the action lands.
      expect(h.surface.count('cancelApproval'), 1);
    });

    test(
      'no notifications are posted while the app is in the foreground',
      () async {
        final h = Harness();
        h.coordinator.update(
          snapshot(running: true, pendingUi: [confirmReq('u1')]),
        );
        await Future<void>.delayed(Duration.zero);
        expect(h.surface.approvals, isEmpty);
      },
    );
  });

  group('notification content builders', () {
    test('title prefixes Running:', () {
      expect(runningNotificationTitle('deploy'), 'Running: deploy');
    });

    test('elapsed formats seconds, minutes and hours', () {
      final start = DateTime(2026, 1, 1, 12).millisecondsSinceEpoch;
      DateTime at(int s) =>
          DateTime.fromMillisecondsSinceEpoch(start + s * 1000);
      expect(formatElapsed(start, at(45)), '45s');
      expect(formatElapsed(start, at(60)), '1m');
      expect(formatElapsed(start, at(185)), '3m');
      expect(formatElapsed(start, at(3925)), '1h 05m');
    });

    test('text shows tool and elapsed', () {
      final start = DateTime(2026, 1, 1, 12).millisecondsSinceEpoch;
      final now = DateTime.fromMillisecondsSinceEpoch(start + 180_000);
      expect(runningNotificationText('bash', start, now), 'bash - 3m');
      expect(runningNotificationText(null, start, now), '3m');
      expect(runningNotificationText('', start, now), '3m');
    });

    test('approval title takes the headline, body the command', () {
      final req = confirmReq('x');
      expect(approvalNotificationTitle(req), 'Run command');
      expect(approvalNotificationBody(req), 'git push');
      final untitled = UiRequest({'id': 'y', 'method': 'confirm'});
      expect(approvalNotificationTitle(untitled), 'Needs your approval');
    });
  });
}
