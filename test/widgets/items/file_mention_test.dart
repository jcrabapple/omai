// FileMentionRow: the attached-files row under a user message, plus the
// content sheet opened on tap.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omai/transcript/items.dart';
import 'package:omai/widgets/items/file_mention.dart';
import 'package:omai/widgets/transcript_item.dart';

import '../pump_omp.dart';

FileMentionItem item(List<Map<String, Object?>> files) =>
    FileMentionItem(id: 'fm:1', files: FileMentionFile.listFrom(files));

void main() {
  testWidgets('one row per file with line counts', (tester) async {
    await pumpOmp(
      tester,
      TranscriptItemView(
        item: item([
          {'path': 'main.dart', 'lineCount': 120, 'content': 'x'},
          {'path': 'lib/util.dart', 'lineCount': 5, 'content': 'y'},
        ]),
      ),
    );
    expect(find.byType(FileMentionRow), findsOneWidget);
    expect(find.textContaining('main.dart'), findsOneWidget);
    expect(find.textContaining('120 lines'), findsOneWidget);
    expect(find.textContaining('util.dart'), findsOneWidget);
    expect(find.textContaining('5 lines'), findsOneWidget);
  });

  testWidgets('skipped files show the reason; images are labelled', (
    tester,
  ) async {
    await pumpOmp(
      tester,
      TranscriptItemView(
        item: item([
          {'path': 'big.bin', 'skippedReason': 'tooLarge'},
          {'path': 'logo.png', 'image': true},
          {'path': 'note.txt', 'skippedReason': 'binary'},
        ]),
      ),
    );
    expect(find.textContaining('too large'), findsOneWidget);
    expect(find.textContaining('binary'), findsOneWidget);
    expect(find.textContaining('image'), findsOneWidget);
  });

  testWidgets('more than three files collapse into one summary row', (
    tester,
  ) async {
    await pumpOmp(
      tester,
      TranscriptItemView(
        item: item([
          for (var i = 0; i < 5; i++)
            {'path': 'f$i.dart', 'lineCount': 1, 'content': 'x'},
        ]),
      ),
    );
    expect(find.textContaining('5 files'), findsOneWidget);
    expect(find.textContaining('f4.dart'), findsNothing);
  });

  testWidgets('tapping a file opens the content sheet', (tester) async {
    await pumpOmp(
      tester,
      TranscriptItemView(
        item: item([
          {'path': 'main.dart', 'lineCount': 1, 'content': 'void main() {}'},
        ]),
      ),
    );
    await tester.tap(find.textContaining('main.dart'));
    await tester.pumpAndSettle();

    expect(find.byType(SelectableText), findsOneWidget);
    final sheet =
        ModalRoute.of(tester.element(find.byType(SelectableText)))!
            as ModalBottomSheetRoute;
    expect(sheet.useSafeArea, isTrue);
    expect(sheet.isScrollControlled, isTrue);
    expect(find.textContaining('void main() {}'), findsOneWidget);
  });

  testWidgets('a huge file renders capped, with Show all revealing the rest', (
    tester,
  ) async {
    final lines = List.generate(5000, (i) => 'line $i').join('\n');
    await pumpOmp(
      tester,
      FileMentionRow(
        item: item([
          {'path': 'huge.log', 'lineCount': 5000, 'content': lines},
        ]),
      ),
    );
    await tester.tap(find.textContaining('huge.log'));
    await tester.pumpAndSettle();

    expect(find.text('Show all'), findsOneWidget);
    // The preview caps the initial render at contentPreviewChars: the tail
    // is not built until Show all.
    expect(find.textContaining('line 4999'), findsNothing);
    await tester.tap(find.text('Show all'));
    await tester.pumpAndSettle();
    expect(find.text('Show all'), findsNothing);
    expect(find.textContaining('line 4999'), findsOneWidget);
  });

  testWidgets('malformed rows still render', (tester) async {
    await pumpOmp(
      tester,
      TranscriptItemView(
        item: item([
          {},
          {'path': 42},
        ]),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
