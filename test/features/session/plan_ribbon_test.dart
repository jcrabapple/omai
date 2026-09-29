// PlanRibbon widget tests, ported from
// web/src/components/__tests__/PlanRibbon.test.ts.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ohmypi/features/session/plan_ribbon.dart';
import 'package:ohmypi/theme/presets.dart';
import 'package:ohmypi/theme/tokens.dart';
import 'package:ohmypi/transcript/plan.dart';

const blockedOnly = <Object?>[
  {
    'name': 'Tasks',
    'tasks': [
      {'content': 'Map the tool surface', 'status': 'completed'},
      {
        'content': 'Write the parser',
        'status': 'blocked',
        'blocker': 'No parser spec anywhere',
      },
    ],
  },
];

Future<void> pump(
  WidgetTester tester,
  List<TodoPhase> phases, {
  VoidCallback? onOpen,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: OmpTheme.data(OmpPreset.terminal),
      home: Scaffold(
        body: PlanRibbon(phases: phases, onOpen: onOpen),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('is hidden without a plan', (tester) async {
    await pump(tester, const []);
    expect(find.byType(PlanRibbon), findsOneWidget);
    expect(find.textContaining('Plan'), findsNothing);
    expect(find.textContaining('All tasks'), findsNothing);
  });

  testWidgets('shows plan progress and the first 60 characters of the '
      'active task', (tester) async {
    final phases = normalizePhases([
      {
        'tasks': [
          {'content': 'x' * 70, 'status': 'in_progress'},
        ],
      },
    ]);
    await pump(tester, phases);
    expect(find.textContaining('Plan 0/1'), findsOneWidget);
    expect(find.textContaining('${'x' * 60}…'), findsOneWidget);
    expect(find.textContaining('x' * 61), findsNothing);
  });

  testWidgets('tints the ribbon when the only active task is blocked',
      (tester) async {
    await pump(tester, normalizePhases(blockedOnly));
    expect(find.text('Write the parser'), findsOneWidget);
    final context = tester.element(find.byType(PlanRibbon));
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final icon = tester.widget<Icon>(
      find.descendant(
        of: find.byType(PlanRibbon),
        matching: find.byType(Icon),
      ),
    );
    expect(icon.color, tokens.warn);
  });

  testWidgets('uses the accent when the active task is in progress',
      (tester) async {
    await pump(tester, normalizePhases([
      {
        'tasks': [
          {'content': 'Busy', 'status': 'in_progress'},
        ],
      },
    ]));
    final context = tester.element(find.byType(PlanRibbon));
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final icon = tester.widget<Icon>(
      find.descendant(
        of: find.byType(PlanRibbon),
        matching: find.byType(Icon),
      ),
    );
    expect(icon.color, tokens.accent);
  });

  testWidgets('shows All tasks complete when every task is done',
      (tester) async {
    await pump(tester, normalizePhases([
      {
        'tasks': [
          {'content': 'Only step', 'status': 'completed'},
        ],
      },
    ]));
    expect(find.text('All tasks complete'), findsOneWidget);
    expect(find.textContaining('Plan 1/1'), findsNothing);
  });

  testWidgets('opens the panel on tap', (tester) async {
    var opened = false;
    await pump(tester, normalizePhases(blockedOnly), onOpen: () => opened = true);
    await tester.tap(find.byType(InkWell));
    expect(opened, isTrue);
  });
}
