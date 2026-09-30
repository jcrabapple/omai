// Every modal sheet in the app must stay below the status bar. The app runs
// edge-to-edge, so a scroll-controlled sheet that grows to full height would
// otherwise slide under the clock and battery icons (seen on the S26 with the
// New session sheet). The guard: every showModalBottomSheet call passes
// useSafeArea: true (source scan), and a widget test pins what that buys.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every showModalBottomSheet call opts into useSafeArea', () {
    final call = RegExp(r'showModalBottomSheet\s*(<[^>]*>)?\s*\(');
    final safe = RegExp(r'useSafeArea:\s*true');
    var sheets = 0;
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final text = entity.readAsStringSync();
      final calls = call.allMatches(text).length;
      if (calls == 0) continue;
      sheets += calls;
      expect(
        safe.allMatches(text).length,
        greaterThanOrEqualTo(calls),
        reason: '${entity.path} opens a sheet without useSafeArea: true',
      );
    }
    expect(sheets, greaterThanOrEqualTo(5), reason: 'scan found the sheets');
  });

  Future<double> sheetTop(
    WidgetTester tester, {
    required bool useSafeArea,
  }) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 40, bottom: 20);
    tester.view.viewPadding = const FakeViewPadding(top: 40, bottom: 20);
    addTearDown(tester.view.reset);

    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            ctx = c;
            return const Scaffold();
          },
        ),
      ),
    );
    showModalBottomSheet<void>(
      context: ctx,
      isScrollControlled: true,
      useSafeArea: useSafeArea,
      builder: (_) =>
          const SingleChildScrollView(child: SizedBox(height: 2000)),
    );
    await tester.pumpAndSettle();
    return tester.getTopLeft(find.byType(SingleChildScrollView)).dy;
  }

  testWidgets(
    'a full-height sheet with useSafeArea stays below the status bar',
    (tester) async {
      expect(
        await sheetTop(tester, useSafeArea: true),
        greaterThanOrEqualTo(40),
      );
    },
  );

  testWidgets('without it the same sheet reaches under the status bar', (
    tester,
  ) async {
    // Pins the failure mode the flag exists for.
    expect(await sheetTop(tester, useSafeArea: false), lessThan(40));
  });
}
