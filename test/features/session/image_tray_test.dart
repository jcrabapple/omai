// Image tray hit-target layout test (review finding: the 48dp remove target
// hung half outside the 56x56 Stack, so hit testing clipped it to about 36dp
// and the list clipped the rest). The remove target must be at least 48x48,
// fully inside its item, and must not reach into the next item.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omai/composer/images.dart';
import 'package:omai/features/session/image_tray.dart';
import 'package:omai/theme/presets.dart';

// A real 1x1 PNG so Image.memory decodes in tests.
final pngBytes = Uint8List.fromList(base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
));

void main() {
  testWidgets('the remove target is 48x48, inside its item, clear of the next',
      (tester) async {
    tester.view.physicalSize = const Size(800, 300);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final semantics = tester.ensureSemantics();
    final removed = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: OmpTheme.data(OmpPreset.terminal),
        home: Scaffold(
          body: ImageTray(
            images: [
              AttachedImage(id: 1, bytes: pngBytes, mimeType: 'image/png'),
              AttachedImage(id: 2, bytes: pngBytes, mimeType: 'image/png'),
            ],
            onRemove: removed.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final item1 =
        tester.getRect(find.byKey(const ValueKey('image-tray-item-0')));
    final item2 =
        tester.getRect(find.byKey(const ValueKey('image-tray-item-1')));
    // The hit target of the remove control: its InkWell render box.
    final target1 = tester.getRect(find.byType(InkWell).at(0));
    final target2 = tester.getRect(find.byType(InkWell).at(1));

    bool inside(Rect outer, Rect inner) =>
        inner.left >= outer.left &&
        inner.top >= outer.top &&
        inner.right <= outer.right &&
        inner.bottom <= outer.bottom;
    expect(target1.width, greaterThanOrEqualTo(48));
    expect(target1.height, greaterThanOrEqualTo(48));
    // Fully inside the item's own box (hit testing stops at item bounds).
    expect(
      inside(item1, target1),
      isTrue,
      reason: 'the remove target must sit inside the item it belongs to',
    );
    expect(
      inside(item2, target2),
      isTrue,
    );
    // And it must not reach into the neighbouring item.
    expect(
      target1.overlaps(item2),
      isFalse,
      reason: 'adjacent items must not overlap',
    );

    await tester.tap(find.bySemanticsLabel('Remove image 1'));
    await tester.pumpAndSettle();
    expect(removed, [1]);
    semantics.dispose();
  });
}
