// MessageActions: a long-press anywhere on the message opens the same action
// menu the overflow button opens (the device-review pattern, e.g. ChatGPT on
// Android), with haptic feedback. 'Select text' opens a bottom sheet where
// the text stays selectable. The overflow button keeps working unchanged.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omai/transcript/items.dart';
import 'package:omai/widgets/items/assistant_message.dart';

import '../pump_omp.dart';

AssistantItem _item(String text) =>
    AssistantItem(id: 'a1', text: text, streaming: false, raw: {'k': 'v'});

void main() {
  testWidgets('long-press opens the message action menu with Inspect', (
    tester,
  ) async {
    Object? inspected;
    await pumpOmp(
      tester,
      AssistantMessage(
        item: _item('select me please'),
        onInspect: (raw) => inspected = raw,
      ),
    );

    await tester.longPress(find.text('select me please'));
    await tester.pumpAndSettle();

    // The same menu the overflow button opens, plus Select text.
    expect(find.text('Inspect'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Select text'), findsOneWidget);

    await tester.tap(find.text('Inspect'));
    await tester.pumpAndSettle();
    expect(inspected, isNotNull);
    expect(find.text('Inspect'), findsNothing);
  });

  testWidgets("'Select text' opens a selectable-text bottom sheet", (
    tester,
  ) async {
    await pumpOmp(
      tester,
      AssistantMessage(item: _item('select me please'), onInspect: (_) {}),
    );
    await tester.longPress(find.text('select me please'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Select text'));
    await tester.pumpAndSettle();

    expect(find.byType(SelectableText), findsOneWidget);
    expect(
      tester.widget<SelectableText>(find.byType(SelectableText)).data,
      'select me please',
    );
    final route = ModalRoute.of(tester.element(find.byType(SelectableText)));
    expect(route, isA<ModalBottomSheetRoute>());
    final sheet = route! as ModalBottomSheetRoute;
    expect(sheet.useSafeArea, isTrue);
    expect(sheet.isScrollControlled, isTrue);
  });

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
      findsNWidgets(3),
      reason: 'Copy, Inspect, Select text (fork is a user-bubble action)',
    );
    expect(find.text('Fork from here'), findsNothing);
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(find.byType(PopupMenuItem<String>), findsNothing);
  });

  testWidgets('no menu and no overflow affordance while the message streams', (
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
    await tester.longPress(find.byType(AssistantMessage));
    await tester.pumpAndSettle();
    expect(find.text('Inspect'), findsNothing);
    expect(find.byType(PopupMenuItem<String>), findsNothing);
  });
}
