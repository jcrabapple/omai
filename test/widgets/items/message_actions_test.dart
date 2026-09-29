// MessageActions long-press menu anchoring: the menu must open at the press
// point, not at a fixed corner offset.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ohmypi/widgets/items/message_actions.dart';

import '../pump_omp.dart';

void main() {
  testWidgets('the menu opens near the long-press point', (tester) async {
    await pumpOmp(
      tester,
      Padding(
        padding: const EdgeInsets.only(top: 300, left: 400),
        child: MessageActions(
          text: 'some text',
          raw: {'k': 'v'},
          label: 'message',
          child: const Text('target'),
        ),
      ),
    );

    // Press comfortably away from the old hardcoded (48, 48) anchor.
    await tester.longPress(find.text('target'));
    await tester.pumpAndSettle();

    final menu = find.descendant(
        of: find.byType(PopupMenuItem<String>), matching: find.text('Copy'));
    expect(menu, findsOneWidget,
        reason: 'only the popup menu offers Copy here');
    expect(
        find.descendant(
            of: find.byType(PopupMenuItem<String>),
            matching: find.text('Inspect')),
        findsOneWidget);
    final topLeft = tester.getTopLeft(menu);
    expect(topLeft.dy, greaterThan(250),
        reason: 'the menu follows the press vertically');
    expect(topLeft.dx, greaterThan(200),
        reason: 'the menu follows the press horizontally, not the (48, 48) corner');
  });
}
