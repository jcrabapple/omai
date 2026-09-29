// Model picker widget tests: grouped rows with context window and price,
// current model checked, search filters, onPick fires, loading and error
// states render. Pure widget; no gateway.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ohmypi/api/models.dart';
import 'package:ohmypi/theme/presets.dart';
import 'package:ohmypi/widgets/model_picker.dart';

CatalogModel _m(String provider, String id, String name,
        {int contextWindow = 200000, double input = 3, double output = 15}) =>
    CatalogModel.fromJson({
      'provider': provider,
      'id': id,
      'selector': '$provider/$id',
      'name': name,
      'contextWindow': contextWindow,
      'maxTokens': 8192,
      'reasoning': true,
      'cost': {'input': input, 'output': output, 'cacheRead': 0, 'cacheWrite': 0},
    });

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(
    theme: OmpTheme.data(OmpPreset.terminal),
    home: Scaffold(body: child),
  ));
  await tester.pump();
}

void main() {
  final models = [
    _m('anthropic', 'sonnet', 'Claude Sonnet'),
    _m('anthropic', 'haiku', 'Claude Haiku'),
    _m('openai', 'gpt', 'GPT'),
  ];

  testWidgets('renders groups with headers, facts and the current check',
      (tester) async {
    CatalogModel? picked;
    await _pump(
        tester,
        ModelPicker(
          models: models,
          current: const CurrentModel(provider: 'anthropic', id: 'haiku'),
          onPick: (m) => picked = m,
        ));

    expect(find.text('ANTHROPIC'), findsOneWidget);
    expect(find.text('OPENAI'), findsOneWidget);
    expect(find.text('Claude Sonnet'), findsOneWidget);
    expect(find.text('GPT'), findsOneWidget);
    // context window + price facts: "200k · $3 / $15".
    expect(find.text('200k · \$3 / \$15'), findsNWidgets(3));
    // Exactly one check: the current model. The check is an Icon.
    final checked = tester.widgetList<Icon>(
        find.widgetWithIcon(InkWell, Icons.check)).length;
    expect(checked, 1);
    expect(picked, isNull);
  });

  testWidgets('defaultLabel shows a first row that picks null', (tester) async {
    CatalogModel? picked;
    await _pump(
        tester,
        ModelPicker(
          models: models,
          defaultLabel: 'Default model',
          onPick: (m) => picked = m,
        ));

    expect(find.text('Default model'), findsOneWidget);
    await tester.tap(find.text('Default model'));
    expect(picked, isNull);
  });

  testWidgets('search filters models and empty result says so', (tester) async {
    CatalogModel? picked;
    await _pump(
        tester,
        ModelPicker(
          models: models,
          onPick: (m) => picked = m,
        ));

    await tester.enterText(find.byType(TextField), 'gpt');
    await tester.pump();
    expect(find.text('Claude Sonnet'), findsNothing);
    expect(find.text('GPT'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'llama');
    await tester.pump();
    expect(find.text('No model matches "llama"'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'sonnet');
    await tester.pump();
    await tester.tap(find.text('Claude Sonnet'));
    expect(picked?.selector, 'anthropic/sonnet');
  });

  testWidgets('first load shows skeletons; error shows retry; retry fires',
      (tester) async {
    var retries = 0;
    await _pump(
        tester,
        ModelPicker(models: const [], loading: true, onPick: (_) {}));
    expect(find.bySemanticsLabel('Fetching models'), findsOneWidget);

    await _pump(
        tester,
        ModelPicker(
          models: const [],
          error: 'rate limited',
          onRetry: () => retries++,
          onPick: (_) {},
        ));
    expect(find.text('Could not load models'), findsOneWidget);
    expect(find.text('rate limited'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retries, 1);
  });

  testWidgets('an error with a stale list keeps the list usable', (tester) async {
    await _pump(
        tester,
        ModelPicker(
          models: models,
          refreshing: true,
          error: 'rate limited',
          onPick: (_) {},
        ));
    expect(find.text('Claude Sonnet'), findsOneWidget);
    expect(find.text('Could not load models'), findsNothing);
  });

  testWidgets('rows meet the 48dp minimum touch target', (tester) async {
    await _pump(
        tester,
        ModelPicker(
          models: models,
          onPick: (_) {},
        ));
    final row = tester.getSize(find
        .ancestor(
            of: find.text('Claude Sonnet'),
            matching: find.byType(ConstrainedBox))
        .first);
    expect(row.height, greaterThanOrEqualTo(48));
  });
}
