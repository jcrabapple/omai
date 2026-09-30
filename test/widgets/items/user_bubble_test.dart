// Widget tests for UserBubble, ported from the web component's states.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omai/theme/presets.dart';
import 'package:omai/transcript/items.dart';
import 'package:omai/widgets/items/user_bubble.dart';

import '../pump_omp.dart';

UserItem item({
  String text = 'hello',
  bool pending = false,
  bool failed = false,
  Object? note,
  bool? stale,
  String? error,
  int images = 0,
}) => UserItem(
  id: 'u1',
  text: text,
  images: images,
  pending: pending,
  note: note as String?,
  stale: stale,
  failed: failed,
  error: error,
);

void main() {
  testWidgets('renders right-aligned text in a bubble', (tester) async {
    await pumpOmp(tester, UserBubble(item: item(text: 'fix the bug')));
    expect(find.text('fix the bug'), findsOneWidget);
    final bubble = tester.getRect(find.text('fix the bug'));
    expect(bubble.right, lessThan(800));
  });

  testWidgets('shows image count', (tester) async {
    await pumpOmp(tester, UserBubble(item: item(images: 2, text: '')));
    expect(find.text('2 images'), findsOneWidget);
  });

  testWidgets('pending dims and shows Sending', (tester) async {
    await pumpOmp(tester, UserBubble(item: item(pending: true)));
    expect(find.text('Sending'), findsOneWidget);
    final opacity = tester.widget<Opacity>(find.byType(Opacity).first);
    expect(opacity.opacity, 0.6);
  });

  testWidgets('failed shows the error note in the error color', (tester) async {
    await pumpOmp(
      tester,
      UserBubble(item: item(failed: true, error: 'socket closed')),
    );
    final note = tester.widget<Text>(find.text('Not sent: socket closed'));
    final t = tokensOf(tester, OmpPreset.terminal);
    expect(note.style?.color, t.err);
  });

  testWidgets('queued note and stale dimming', (tester) async {
    await pumpOmp(tester, UserBubble(item: item(note: 'queued', stale: true)));
    expect(find.text('Queued'), findsOneWidget);
    final note = tester.widget<Opacity>(
      find
          .ancestor(of: find.text('Queued'), matching: find.byType(Opacity))
          .first,
    );
    expect(note.opacity, 0.7);
  });

  testWidgets('long-press opens the action menu with Fork from here', (
    tester,
  ) async {
    var forked = false;
    await pumpOmp(
      tester,
      UserBubble(item: item(), onInspect: (_) {}, onFork: () => forked = true),
    );
    // The device-review pattern: long-press opens the same menu the overflow
    // button opens, with Fork from first.
    await tester.longPress(find.text('hello'));
    await tester.pumpAndSettle();
    expect(find.text('Fork from here'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Inspect'), findsOneWidget);
    expect(find.text('Select text'), findsOneWidget);

    await tester.tap(find.text('Fork from here'));
    await tester.pumpAndSettle();
    expect(forked, isTrue);
    expect(find.byType(PopupMenuItem<String>), findsNothing);
  });

  testWidgets("'Select text' opens a selectable-text bottom sheet", (
    tester,
  ) async {
    await pumpOmp(tester, UserBubble(item: item(), onInspect: (_) {}));
    await tester.longPress(find.text('hello'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Select text'));
    await tester.pumpAndSettle();

    expect(find.byType(SelectableText), findsOneWidget);
    expect(
      tester.widget<SelectableText>(find.byType(SelectableText)).data,
      'hello',
    );
    final route = ModalRoute.of(tester.element(find.byType(SelectableText)));
    expect(route, isA<ModalBottomSheetRoute>());
    final sheet = route! as ModalBottomSheetRoute;
    expect(sheet.useSafeArea, isTrue);
    expect(sheet.isScrollControlled, isTrue);
  });

  testWidgets('a pending bubble offers no actions on long-press', (
    tester,
  ) async {
    await pumpOmp(tester, UserBubble(item: item(pending: true)));
    await tester.longPress(find.text('hello'));
    await tester.pumpAndSettle();
    expect(find.byType(PopupMenuItem<String>), findsNothing);
    expect(find.text('Fork from here'), findsNothing);
    expect(find.byTooltip('Message actions'), findsNothing);
  });

  testWidgets('a failed bubble still offers Copy so its text can be rescued', (
    tester,
  ) async {
    await pumpOmp(
      tester,
      UserBubble(item: item(failed: true, error: 'socket closed')),
    );
    await tester.longPress(find.text('hello'));
    await tester.pumpAndSettle();
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Select text'), findsOneWidget);
    expect(find.text('Fork from here'), findsNothing);
  });

  testWidgets('no SelectionArea on the bubble: no gesture race', (
    tester,
  ) async {
    await pumpOmp(tester, UserBubble(item: item()));
    expect(find.byType(SelectionArea), findsNothing);
  });

  testWidgets('a short message hugs its content instead of stretching to 85%', (
    tester,
  ) async {
    await pumpOmp(tester, UserBubble(item: item(text: 'hi')));
    final bubble = tester.getRect(
      find
          .descendant(
            of: find.byType(UserBubble),
            matching: find.byWidgetPredicate(
              (w) => w is Container && w.decoration is BoxDecoration,
            ),
          )
          .first,
    );
    // 800dp test surface: the old FractionallySizedBox forced 85% (680dp).
    expect(bubble.width, lessThan(800 * 0.4));
    expect(bubble.width, greaterThan(0));
  });

  testWidgets('a long message still caps at 85% of the available width', (
    tester,
  ) async {
    await pumpOmp(
      tester,
      UserBubble(
        item: item(
          text: 'a fairly long message that should wrap and eventually hit the width cap',
        ),
      ),
    );
    final bubble = tester.getRect(
      find.text(
        'a fairly long message that should wrap and eventually hit the width cap',
      ),
    );
    expect(bubble.width, lessThanOrEqualTo(640 * 0.85 + 1));
  });
}
