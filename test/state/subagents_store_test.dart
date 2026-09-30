// Conformance port of
// web/src/lib/state/__tests__/subagents.test.ts: the fold logic must behave
// exactly like the web store. Runs against the pure SubagentRoster (no
// container needed); the Riverpod wrapper is covered indirectly via the
// widget tests and the session_controller wiring.
//
// Live probe 2026-09-29 (web): payload.id is absent on early frames, the id
// lives in payload.progress.id and the merge key is progress.id ?? `#index`.
import 'package:flutter_test/flutter_test.dart';
import 'package:omai/state/subagents_store.dart';
import 'package:omai/wire/wire.dart' show OmpEvent;

void main() {
  late SubagentRoster roster;

  setUp(() {
    roster = SubagentRoster();
  });

  void feedProgress(Map<String, Object?> payload) => roster.feed(
    OmpEvent({'type': 'subagent_progress', 'payload': payload}).raw,
  );

  void feedLifecycle(Map<String, Object?> payload) => roster.feed(
    OmpEvent({'type': 'subagent_lifecycle', 'payload': payload}).raw,
  );

  test('merges progress frames by progress.id, newest fields win', () {
    feedProgress({
      'index': 3,
      'agent': 'explore',
      'task': 'map the surface',
      'progress': {
        'id': 'sa1',
        'index': 3,
        'agent': 'explore',
        'status': 'running',
        'task': 'map the surface',
        'tokens': 120,
      },
    });
    feedProgress({
      'index': 3,
      'progress': {
        'id': 'sa1',
        'index': 3,
        'status': 'running',
        'tokens': 400,
        'cost': 0.02,
        'currentTool': 'read',
      },
    });
    expect(roster.total, 1);
    final row = roster.rows[0];
    expect(row.key, 'sa1');
    expect(row.agent, 'explore');
    expect(row.task, 'map the surface');
    expect(row.tokens, 400);
    expect(row.cost, 0.02);
    expect(row.currentTool, 'read');
    expect(roster.running, 1);
    expect(roster.failed, 0);
  });

  test('falls back to a #index key while progress.id is absent', () {
    feedProgress({
      'index': 5,
      'agent': 'fix',
      'progress': {'index': 5, 'status': 'running'},
    });
    feedProgress({
      'index': 5,
      'progress': {'index': 5, 'status': 'completed', 'tokens': 9},
    });
    expect(roster.total, 1);
    expect(roster.rows[0].key, '#5');
    expect(roster.rows[0].status, SubagentStatus.completed);
    expect(roster.rows[0].agent, 'fix');
  });

  test('migrates a #index row to progress.id when an id arrives later', () {
    feedProgress({
      'index': 5,
      'agent': 'fix',
      'progress': {'index': 5, 'status': 'running'},
    });
    expect(roster.total, 1);
    expect(roster.rows[0].key, '#5');
    feedProgress({
      'index': 5,
      'progress': {'id': 'sa5', 'index': 5, 'status': 'running', 'tokens': 50},
    });
    expect(roster.total, 1);
    expect(roster.rows[0].key, 'sa5');
    expect(roster.rows[0].id, 'sa5');
    expect(roster.rows[0].agent, 'fix');
    expect(roster.rows[0].tokens, 50);
  });

  test(
    'sorts by index and keeps unknown-index rows in arrival order after',
    () {
      feedProgress({
        'index': 2,
        'progress': {'id': 'b', 'index': 2, 'status': 'running'},
      });
      feedProgress({
        'progress': {'id': 'late', 'status': 'running'},
      });
      feedProgress({
        'index': 1,
        'progress': {'id': 'a', 'index': 1, 'status': 'running'},
      });
      expect(roster.rows.map((r) => r.key).toList(), ['a', 'b', 'late']);
    },
  );

  test('follows lifecycle transitions without regressing a terminal row', () {
    feedProgress({
      'index': 1,
      'progress': {
        'id': 's1',
        'index': 1,
        'status': 'running',
        'currentTool': 'bash',
      },
    });
    feedLifecycle({
      'id': 's1',
      'agent': 'explore',
      'status': 'completed',
      'index': 1,
    });
    var row = roster.rows[0];
    expect(row.status, SubagentStatus.completed);
    expect(row.currentTool, '');
    expect(row.agent, 'explore');
    feedLifecycle({'id': 's1', 'status': 'started', 'index': 1});
    expect(roster.rows[0].status, SubagentStatus.completed);
    // Late progress frame must not regress terminal row
    feedProgress({
      'index': 1,
      'progress': {
        'id': 's1',
        'index': 1,
        'status': 'running',
        'currentTool': 'bash',
      },
    });
    expect(roster.rows[0].status, SubagentStatus.completed);
    expect(roster.rows[0].currentTool, '');

    feedProgress({
      'index': 2,
      'progress': {'id': 's2', 'index': 2},
    });
    expect(roster.rows[1].status, SubagentStatus.pending);
    feedLifecycle({'id': 's2', 'status': 'started', 'index': 2});
    expect(roster.rows[1].status, SubagentStatus.running);
    row = roster.rows[1];
    expect(row.description, '');
    feedLifecycle({
      'id': 's2',
      'status': 'started',
      'description': 'probe the api',
      'index': 2,
    });
    expect(roster.rows[1].description, 'probe the api');
    feedLifecycle({'id': 's2', 'status': 'aborted', 'index': 2});
    expect(roster.rows[1].status, SubagentStatus.aborted);
    feedProgress({
      'index': 2,
      'progress': {'id': 's2', 'index': 2, 'status': 'running'},
    });
    expect(roster.rows[1].status, SubagentStatus.aborted);
  });

  test('counts failed rows and keeps the retry badge state', () {
    feedProgress({
      'index': 1,
      'progress': {
        'id': 'r1',
        'index': 1,
        'status': 'running',
        'currentTool': 'edit',
        'retryState': {'attempt': 2, 'maxAttempts': 3},
      },
    });
    expect(
      roster.rows[0].retry,
      const SubagentRetry(attempt: 2, maxAttempts: 3),
    );
    feedProgress({
      'index': 1,
      'progress': {'id': 'r1', 'index': 1, 'status': 'failed'},
    });
    expect(roster.failed, 1);
    expect(roster.running, 0);
    expect(roster.rows[0].currentTool, '');
    expect(
      roster.rows[0].retry,
      const SubagentRetry(attempt: 2, maxAttempts: 3),
    );
  });

  test('clears on session switch', () {
    feedProgress({
      'index': 1,
      'progress': {'id': 'x', 'index': 1, 'status': 'running'},
    });
    expect(roster.hasAny, isTrue);
    roster.clear();
    expect(roster.rows, isEmpty);
    expect(roster.hasAny, isFalse);
  });

  test('seeds the registry snapshot leniently, list or {subagents}', () {
    roster.seed({
      'subagents': [
        {'id': 'x1', 'index': 0, 'status': 'completed', 'tokens': 5},
      ],
    });
    expect(roster.rows[0].key, 'x1');
    roster.seed([
      {
        'id': 'x2',
        'index': 1,
        'status': 'running',
        'agent': 'fix',
        'progress': {'tokens': 7},
      },
    ]);
    expect(roster.total, 2);
    expect(roster.rows[1].tokens, 7);
    // Junk entries and junk envelopes are skipped, never thrown on.
    roster.seed([
      null,
      'nope',
      {'index': 2},
    ]);
    roster.seed(null);
    roster.seed({'nothing': true});
    expect(roster.total, 3);
  });

  test('ignores frames that are not subagent events', () {
    roster.feed(const OmpEvent({'type': 'agent_start'}).raw);
    roster.feed(const OmpEvent({'type': 'subagent_progress'}).raw);
    roster.feed(const OmpEvent({'type': 'subagent_lifecycle'}).raw);
    expect(roster.total, 0);
  });

  test('taskText prefers description, then task, then assignment', () {
    feedProgress({
      'index': 1,
      'task': 'the task',
      'assignment': 'the assignment',
      'progress': {'id': 't1', 'index': 1, 'status': 'running'},
    });
    expect(roster.rows[0].taskText, 'the task');
    feedLifecycle({
      'id': 't1',
      'status': 'started',
      'description': 'the description',
      'index': 1,
    });
    expect(roster.rows[0].taskText, 'the description');
  });
}
