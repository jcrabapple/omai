// Widget tests for UserBubble, ported from the web component's states.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ohmypi/theme/presets.dart';
import 'package:ohmypi/transcript/items.dart';
import 'package:ohmypi/widgets/items/user_bubble.dart';

import '../pump_omp.dart';

UserItem item({
  String text = 'hello',
  bool pending = false,
  bool failed = false,
  Object? note,
  bool? stale,
  String? error,
  int images = 0,
}) =>
    UserItem(
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
    await pumpOmp(tester,
        UserBubble(item: item(failed: true, error: 'socket closed')));
    final note = tester.widget<Text>(find.text('Not sent: socket closed'));
    final t = tokensOf(tester, OmpPreset.terminal);
    expect(note.style?.color, t.err);
  });

  testWidgets('queued note and stale dimming', (tester) async {
    await pumpOmp(
        tester, UserBubble(item: item(note: 'queued', stale: true)));
    expect(find.text('Queued'), findsOneWidget);
    final note = tester.widget<Opacity>(find.ancestor(
        of: find.text('Queued'), matching: find.byType(Opacity)).first);
    expect(note.opacity, 0.7);
  });

  testWidgets('long press opens copy and inspect actions', (tester) async {
    await pumpOmp(tester, UserBubble(item: item()));
    await tester.longPress(find.text('hello'));
    await tester.pumpAndSettle();
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Inspect'), findsOneWidget);
  });
}
