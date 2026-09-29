// Ported from web/src/lib/state/__tests__/plan.test.ts (the pure helpers;
// the reactive store part is covered by the controller + widget tests).
import 'package:flutter_test/flutter_test.dart';
import 'package:ohmypi/transcript/plan.dart';

// Live capture from the gateway, 2026-09-29: ids absent, `blocked` carries a
// blocker string.
const capture = <Object?>[
  {
    'name': 'Tasks',
    'tasks': [
      {'content': 'Map the tool surface', 'status': 'completed'},
      {
        'content': 'Write the parser',
        'status': 'blocked',
        'blocker': 'No parser spec anywhere: nothing to port.',
      },
      {'content': 'Add tests', 'status': 'blocked', 'blocker': 'Depends on the parser existing'},
    ],
  },
];

void main() {
  group('normalizePhases', () {
    test('coerces the live capture shape', () {
      final phases = normalizePhases(capture);
      expect(phases, hasLength(1));
      expect(phases[0].name, 'Tasks');
      expect(phases[0].id, isNull);
      expect(
        phases[0].tasks.map((t) => t.status).toList(),
        ['completed', 'blocked', 'blocked'],
      );
      expect(phases[0].tasks[1].blocker, contains('No parser spec'));
      expect(phases[0].tasks[0].id, isNull);
    });

    test('maps unknown status to pending and drops junk entries', () {
      final phases = normalizePhases([
        null,
        {'name': 'Empty', 'tasks': <Object?>[]},
        {
          'name': 'Odd',
          'tasks': [
            {'content': 'A', 'status': 'sideways'},
            {'blocker': 'no content'},
            'junk',
          ],
        },
      ]);
      expect(phases, hasLength(1));
      expect(
        phases[0].tasks,
        [const TodoTask(content: 'A', status: 'pending')],
      );
    });

    test('tolerates null, undefined and non-list input', () {
      expect(normalizePhases(null), isEmpty);
      expect(normalizePhases('nope'), isEmpty);
      expect(normalizePhases(42), isEmpty);
    });
  });

  group('derivations', () {
    test('counts done and total', () {
      final phases = normalizePhases(capture);
      expect(countDone(phases), 1);
      expect(countTotal(phases), 3);
    });

    test('picks first in_progress, then pending, then blocked', () {
      final blockedOnly = normalizePhases(capture);
      expect(pickActiveTask(blockedOnly)?.status, 'blocked');
      expect(pickActiveTask(blockedOnly)?.content, 'Write the parser');

      final withPending = normalizePhases([
        {
          'tasks': [
            {'content': 'P', 'status': 'pending'},
            ...((capture[0] as Map)['tasks'] as List<Object?>),
          ],
        },
      ]);
      expect(pickActiveTask(withPending)?.content, 'P');

      final withActive = normalizePhases([
        {
          'tasks': [
            ...((capture[0] as Map)['tasks'] as List<Object?>),
            {'content': 'Now', 'status': 'in_progress'},
          ],
        },
      ]);
      expect(pickActiveTask(withActive)?.content, 'Now');

      final allDone = normalizePhases([
        {
          'tasks': [
            {'content': 'D', 'status': 'completed'},
          ],
        },
      ]);
      expect(pickActiveTask(allDone), isNull);
    });

    test('hasActiveTodo is true only for in_progress tasks', () {
      expect(hasActiveTodo(normalizePhases(capture)), isFalse);
      expect(
        hasActiveTodo(normalizePhases([
          {
            'tasks': [
              {'content': 'X', 'status': 'in_progress'},
            ],
          },
        ])),
        isTrue,
      );
      expect(hasActiveTodo(normalizePhases([])), isFalse);
      expect(hasActiveTodo(normalizePhases(null)), isFalse);
    });
  });
}
