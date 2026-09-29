// InspectorSheet tests, ported from
// web/src/components/__tests__/InspectorSheet.test.ts (the circular-data case
// is web-only: Dart items hold JSON-decoded data, which cannot contain
// cycles).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ohmypi/theme/presets.dart';
import 'package:ohmypi/widgets/items/inspector_sheet.dart';

Future<void> _pump(WidgetTester tester, Object? raw) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: OmpTheme.data(OmpPreset.terminal),
      home: Scaffold(body: InspectorSheet(raw: raw)),
    ),
  );
  await tester.pump();
}

void main() {
  setUp(() {});

  testWidgets('shows pretty JSON with a line count', (tester) async {
    await _pump(tester, {
      'role': 'user',
      'content': [
        {'type': 'text', 'text': 'hi'},
      ],
    });
    final text = tester.widget<Text>(
      find.descendant(
        of: find.byType(SelectionArea),
        matching: find.byType(Text),
      ),
    );
    expect(text.data, contains('"role": "user"'));
    expect(text.data!.split('\n').length, greaterThan(3));
    expect(find.textContaining(RegExp(r'^\d+ lines$')), findsOneWidget);
  });

  testWidgets('copies exactly what is shown', (tester) async {
    const raw = {'a': 1};
    final clipboard = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        clipboard.add(call);
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await _pump(tester, raw);
    await tester.tap(find.byKey(const ValueKey('inspector-copy')));
    await tester.pump();
    expect(clipboard.last.method, 'Clipboard.setData');
    expect(
      (clipboard.last.arguments as Map<Object?, Object?>)['text'],
      const JsonEncoder.withIndent('  ').convert(raw),
    );
    expect(find.text('JSON copied'), findsOneWidget);
  });

  testWidgets('has an empty state when there is nothing to show',
      (tester) async {
    await _pump(tester, null);
    expect(find.textContaining('no source'), findsOneWidget);
    expect(find.byKey(const ValueKey('inspector-copy')), findsNothing);
  });
}
