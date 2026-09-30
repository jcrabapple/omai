// Shared pump helper for item widget tests: one MaterialApp per theme preset.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omai/theme/presets.dart';
import 'package:omai/theme/tokens.dart';

OmpTokens tokensOf(WidgetTester tester, OmpPreset preset) {
  final context = tester.element(find.byType(Scaffold).first);
  return Theme.of(context).extension<OmpTokens>()!;
}

Future<void> pumpOmp(
  WidgetTester tester,
  Widget child, {
  OmpPreset preset = OmpPreset.terminal,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: OmpTheme.data(preset),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
  await tester.pump();
}
