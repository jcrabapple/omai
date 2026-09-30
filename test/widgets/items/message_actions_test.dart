// MessageActions: a long-press anywhere on the message opens the same action
// menu the overflow button opens (the device-review pattern, e.g. ChatGPT on
// Android), with haptic feedback. 'Select text' opens a bottom sheet where
// the text stays selectable. The overflow button keeps working unchanged.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
    // The streaming markdown render is throttled: let the tick land.
    await tester.pump(const Duration(milliseconds: 150));
    // Target the rendered text, not the widget box: a finder on the whole
    // AssistantMessage can derive an offset that misses the hit-test target,
    // which made this test pass vacuously.
    await tester.longPress(
      find.textContaining('streaming', findRichText: true),
    );
    await tester.pumpAndSettle();
    expect(find.text('Inspect'), findsNothing);
    expect(find.byType(PopupMenuItem<String>), findsNothing);
  });

  testWidgets(
    'long-press anchors the menu at the press point on a tall message',
    (tester) async {
      tester.view.physicalSize = const Size(400, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final body = StringBuffer();
      for (var i = 0; i < 300; i++) {
        body.writeln('paragraph $i of a very tall message');
      }
      await pumpOmp(tester, AssistantMessage(item: _item(body.toString())));
      // Scroll so the top of the message is well above the viewport.
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -500),
      );
      await tester.pumpAndSettle();

      // Long-press in the lower half of the screen, inside the message text
      // (high enough that the menu still fits below the anchor).
      const press = Offset(200, 420);
      await tester.longPressAt(press);
      await tester.pumpAndSettle();

      final menuTop = tester.getTopLeft(
        find.byType(PopupMenuItem<String>).first,
      );
      expect(
        menuTop.dy,
        closeTo(press.dy, 100),
        reason: 'the menu opens near the finger, not at the top of the message',
      );
      expect(menuTop.dy, greaterThanOrEqualTo(0), reason: 'on screen');
    },
  );

  testWidgets('the overflow button anchors the menu at the button', (
    tester,
  ) async {
    final body = StringBuffer();
    for (var i = 0; i < 40; i++) {
      body.writeln('paragraph $i of a tall message');
    }
    await pumpOmp(tester, AssistantMessage(item: _item(body.toString())));
    // The bottom of the message, button included, is off screen at first:
    // scroll down until the button is on screen with room below it.
    await tester.scrollUntilVisible(
      find.byTooltip('Message actions'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    final button = tester.getTopLeft(find.byTooltip('Message actions'));
    await tester.tap(find.byTooltip('Message actions'));
    await tester.pumpAndSettle();

    final menuTop = tester.getTopLeft(find.byType(PopupMenuItem<String>).first);
    expect(
      menuTop.dy,
      closeTo(button.dy, 100),
      reason: 'the menu opens at the button, not the top of the message',
    );
  });

  testWidgets('semantics: exactly one long-press node per message', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpOmp(
      tester,
      AssistantMessage(item: _item('hello there'), onInspect: (_) {}),
    );
    final nodes = _allSemanticsNodes(tester);
    final longPressNodes = nodes
        .where((n) => n.getSemanticsData().hasAction(SemanticsAction.longPress))
        .toList();
    expect(
      longPressNodes,
      hasLength(1),
      reason: 'TalkBack must not create a second long-press stop per message',
    );
    // The one stop reads the label AND the message text.
    expect(
      longPressNodes.single.getSemanticsData().label,
      contains('hello there'),
    );
    handle.dispose();
  });
}

List<SemanticsNode> _allSemanticsNodes(WidgetTester tester) {
  final owner =
      // ignore: deprecated_member_use
      tester.binding.pipelineOwner.semanticsOwner!;
  final out = <SemanticsNode>[];
  void visit(SemanticsNode? n) {
    if (n == null) return;
    out.add(n);
    n.visitChildren((c) {
      visit(c);
      return true;
    });
  }

  visit(owner.rootSemanticsNode);
  return out;
}
