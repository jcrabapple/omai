// MessageActions, review #6: long-press belongs to the SelectionArea (it
// selects a word and shows the toolbar with Inspect / Retry turn); the
// overflow button opens the same menu without selecting.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omai/transcript/items.dart';
import 'package:omai/widgets/items/assistant_message.dart';

import '../pump_omp.dart';

AssistantItem _item(String text) =>
    AssistantItem(id: 'a1', text: text, streaming: false, raw: {'k': 'v'});

void main() {
  testWidgets(
    'long-press selects a word and the selection toolbar offers Inspect',
    (tester) async {
      Object? inspected;
      await pumpOmp(
        tester,
        AssistantMessage(
          item: _item('select me please'),
          onInspect: (raw) => inspected = raw,
        ),
      );

      // The long press selects: the toolbar appearing with Copy (only shown
      // for a non-empty selection) is the observable proof, and our custom
      // Inspect item rides in the same toolbar.
      await tester.longPress(find.text('select me please'));
      await tester.pumpAndSettle();

      expect(
        find.text('Copy'),
        findsOneWidget,
        reason: 'a non-empty selection shows the Copy toolbar item',
      );
      expect(
        find.text('Inspect'),
        findsOneWidget,
        reason: 'message actions live in the selection toolbar',
      );

      await tester.tap(find.text('Inspect'));
      await tester.pumpAndSettle();
      expect(inspected, isNotNull);
      // The toolbar dismissed with the action: no dead button row left.
      expect(find.text('Inspect'), findsNothing);
    },
  );

  testWidgets('the overflow button opens the same menu without selecting', (
    tester,
  ) async {
    await pumpOmp(
      tester,
      AssistantMessage(item: _item('plain text'), onInspect: (_) {}),
    );

    await tester.tap(find.byTooltip('Message actions'));
    await tester.pumpAndSettle();

    expect(
      find.byType(PopupMenuItem<String>),
      findsNWidgets(2),
      reason: 'Copy, Inspect (fork is a user-bubble action)',
    );
    expect(find.text('Fork from here'), findsNothing);
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(find.byType(PopupMenuItem<String>), findsNothing);
  });

  testWidgets('no overflow affordance while the message is streaming', (
    tester,
  ) async {
    await pumpOmp(
      tester,
      AssistantMessage(
        item: AssistantItem(
          id: 'a2',
          text: 'streaming',
          streaming: true,
          raw: {'k': 'v'},
        ),
      ),
    );
    expect(find.byTooltip('Message actions'), findsNothing);
  });
}
