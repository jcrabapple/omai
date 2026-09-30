// Models, Skills and Usage page widget tests: grouped catalog with search,
// sorted skills with the empty state, and the ANSI usage report rendered,
// with the response's error text and the empty-report note.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omai/features/settings/models_page.dart';
import 'package:omai/theme/presets.dart';
import 'package:omai/features/settings/skills_page.dart';
import 'package:omai/features/settings/usage_page.dart';

import 'fakes.dart';

Future<void> pumpPage(
  WidgetTester tester,
  Widget page,
  FakeGateway fake,
) async {
  final container = fake.container;
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
      theme: OmpTheme.data(OmpPreset.terminal),
      home: page),
    ),
  );
  await tester.pumpAndSettle();
}

const catalogBody = {
  'models': [
    {
      'provider': 'zeta',
      'id': 'zeta-mini',
      'selector': 'zeta/zeta-mini',
      'name': 'Zeta Mini',
      'contextWindow': 128000,
      'maxTokens': 8192,
      'reasoning': false,
    },
    {
      'provider': 'acme',
      'id': 'acme-1',
      'selector': 'acme/acme-1',
      'name': 'Acme One',
      'contextWindow': 1000000,
      'reasoning': true,
    },
  ],
};

void main() {
  group('models', () {
    testWidgets('grouped by provider with context and reasoning flag',
        (tester) async {
      await pumpPage(tester, const ModelsPage(), FakeGateway({
        '/api/catalog/models': catalogBody,
      }));
      expect(find.text('ACME'), findsOneWidget);
      expect(find.text('ZETA'), findsOneWidget);
      expect(find.text('Zeta Mini'), findsOneWidget);
      expect(find.text('128k context'), findsOneWidget);
      expect(find.text('1m context · reasoning'), findsOneWidget);
      expect(find.text('2 models'), findsOneWidget);
    });

    testWidgets('search filters by name, provider and id', (tester) async {
      await pumpPage(tester, const ModelsPage(), FakeGateway({
        '/api/catalog/models': catalogBody,
      }));
      await tester.enterText(
        find.byKey(const ValueKey('models-search')),
        'zeta',
      );
      await tester.pumpAndSettle();
      expect(find.text('Zeta Mini'), findsOneWidget);
      expect(find.text('Acme One'), findsNothing);

      await tester.enterText(
        find.byKey(const ValueKey('models-search')),
        'acme-1',
      );
      await tester.pumpAndSettle();
      expect(find.text('Acme One'), findsOneWidget);
      expect(find.text('Zeta Mini'), findsNothing);
    });

    testWidgets('no matches shows the empty state', (tester) async {
      await pumpPage(tester, const ModelsPage(), FakeGateway({
        '/api/catalog/models': catalogBody,
      }));
      await tester.enterText(
        find.byKey(const ValueKey('models-search')),
        'nope',
      );
      await tester.pumpAndSettle();
      expect(find.text('No models match "nope"'), findsOneWidget);
    });
  });

  group('skills', () {
    testWidgets('sorted, with linked tag and description fallback',
        (tester) async {
      await pumpPage(tester, const SkillsPage(), FakeGateway({
        '/api/skills': {
          'installed': [
            {'name': 'zeta-skill', 'description': 'Does zeta things', 'symlink': false},
            {'name': 'acme-skill', 'description': '', 'symlink': true},
          ],
        },
      }));
      expect(find.text('acme-skill'), findsOneWidget);
      expect(find.text('zeta-skill'), findsOneWidget);
      // Sorted: acme first.
      expect(
        tester.getTopLeft(find.text('acme-skill')).dy <
            tester.getTopLeft(find.text('zeta-skill')).dy,
        isTrue,
      );
      expect(find.text('No description'), findsOneWidget);
      expect(find.text('linked'), findsOneWidget);
    });

    testWidgets('empty state when nothing is installed', (tester) async {
      await pumpPage(tester, const SkillsPage(), FakeGateway({
        '/api/skills': {'installed': []},
      }));
      expect(
        find.text('No skills are installed on the gateway host.'),
        findsOneWidget,
      );
    });

    testWidgets('an error shows with Retry', (tester) async {
      await pumpPage(tester, const SkillsPage(), FakeGateway({
        '/api/skills': 500,
      }));
      expect(find.text('Retry'), findsOneWidget);
    });
  });

  group('usage', () {
    testWidgets('renders the ANSI report and strips the escapes',
        (tester) async {
      await pumpPage(tester, const UsagePage(), FakeGateway({
        '/api/usage': {
          'raw': '\x1b[1mAcme\x1b[0m tokens used: 1,234',
        },
      }));
      expect(find.textContaining('Acme tokens used: 1,234'), findsOneWidget);
      expect(find.textContaining('\x1b'), findsNothing);
      expect(find.byKey(const ValueKey('usage-report-text')), findsOneWidget);
    });

    testWidgets('the response error text is shown next to the report',
        (tester) async {
      await pumpPage(tester, const UsagePage(), FakeGateway({
        '/api/usage': {'raw': 'partial', 'error': 'some providers timed out'},
      }));
      expect(
        find.byKey(const ValueKey('usage-error-note')),
        findsOneWidget,
      );
      expect(find.text('some providers timed out'), findsOneWidget);
    });

    testWidgets('an empty report shows the note', (tester) async {
      await pumpPage(tester, const UsagePage(), FakeGateway({
        '/api/usage': {'raw': ''},
      }));
      expect(
        find.text('The gateway returned no usage data.'),
        findsOneWidget,
      );
    });
  });
}
