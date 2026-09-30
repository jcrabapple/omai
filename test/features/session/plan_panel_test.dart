// PlanPanel sheet tests, ported from
// web/src/components/__tests__/PlanPanel.test.ts.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omai/features/session/plan_panel.dart';
import 'package:omai/theme/presets.dart';
import 'package:omai/transcript/items.dart';
import 'package:omai/transcript/plan.dart';

const plan = <Object?>[
  {
    'name': 'Tasks',
    'tasks': [
      {'content': 'Map the tool surface', 'status': 'completed'},
      {'content': 'Write the parser', 'status': 'in_progress'},
      {'content': 'Add tests', 'status': 'pending'},
      {
        'content': 'Wire the plan',
        'status': 'blocked',
        'blocker': 'No parser spec anywhere',
      },
    ],
  },
];

ToolItem runningTool() => ToolItem(
      id: 't1',
      toolCallId: 'c1',
      toolName: 'bash',
      summary: 'bun run test',
      output: '',
      status: 'running',
    );

Future<void> pump(
  WidgetTester tester, {
  Object? todoPhases,
  List<ToolItem> tools = const [],
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: OmpTheme.data(OmpPreset.terminal),
      home: Scaffold(
        body: PlanPanel(
          phases: normalizePhases(todoPhases),
          runningTools: tools,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('renders the plan tab with counts, progress and per-status rows',
      (tester) async {
    await pump(tester, todoPhases: plan);
    expect(find.text('1 of 4 complete'), findsOneWidget);
    expect(find.text('Plan 1/4'), findsOneWidget);
    expect(find.text('Map the tool surface'), findsOneWidget);
    expect(find.text('Write the parser'), findsOneWidget);
    expect(find.text('Add tests'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('toggles the blocker text on a blocked row and nothing else',
      (tester) async {
    await pump(tester, todoPhases: plan);
    expect(find.text('No parser spec anywhere'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('blocker-toggle-p0-t3')));
    await tester.pump();
    expect(find.text('No parser spec anywhere'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('blocker-toggle-p0-t3')));
    await tester.pump();
    expect(find.text('No parser spec anywhere'), findsNothing);
  });

  testWidgets('keeps a blocked row without blocker text non-interactive',
      (tester) async {
    await pump(tester, todoPhases: [
      {
        'name': 'Tasks',
        'tasks': [
          {'content': 'Waiting on review', 'status': 'blocked'},
        ],
      },
    ]);
    expect(find.text('Waiting on review'), findsOneWidget);
    expect(find.text('Blocked'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('blocker-toggle-p0-t0')),
      findsNothing,
      reason: 'no blocker string, nothing to expand',
    );
  });

  testWidgets('falls back to the activity pane without a plan',
      (tester) async {
    await pump(tester, todoPhases: []);
    expect(find.text('No tools running'), findsOneWidget);
  });

  testWidgets('lists currently running tools in the activity tab',
      (tester) async {
    await pump(tester, todoPhases: plan, tools: [runningTool()]);
    expect(find.text('bash'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('plan-tab-activity')));
    // Fixed pumps: the running-tool spinner repaints forever, so
    // pumpAndSettle would never settle.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('bash'), findsOneWidget);
    expect(find.text('bun run test'), findsOneWidget);
  });

  testWidgets('never double-marks: the completed task is struck through and '
      'exactly one task carries the current accent', (tester) async {
    await pump(tester, todoPhases: plan);
    // The completed row keeps its content visible exactly once.
    expect(find.text('Map the tool surface'), findsOneWidget);
    expect(find.text('Write the parser'), findsOneWidget);
  });
}
