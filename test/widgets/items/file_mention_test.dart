// FileMentionRow: the attached-files row under a user message, plus the
// content sheet opened on tap.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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

    final sheet =
        ModalRoute.of(tester.element(find.textContaining('void main() {}')))!
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
    // The full view is virtualized: the tail appears once its chunk is
    // built on demand, not because everything was built at once.
    final scroller = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );
    expect(
      tester
          .widgetList<Text>(
            find.descendant(
              of: find.byType(ListView),
              matching: find.byType(Text),
            ),
          )
          .length,
      lessThan(20),
      reason: 'only the chunks near the viewport are built',
    );
    // The scroll extent is estimated while only a few chunks are measured:
    // jump repeatedly until it settles at the real bottom.
    for (var i = 0; i < 10; i++) {
      scroller.position.jumpTo(scroller.position.maxScrollExtent);
      await tester.pump();
    }
    expect(find.textContaining('line 4999'), findsOneWidget);
    expect(
      tester
          .widgetList<Text>(
            find.descendant(
              of: find.byType(ListView),
              matching: find.byType(Text),
            ),
          )
          .length,
      lessThan(20),
      reason: 'still virtualized at the bottom of the list',
    );
  });

  testWidgets('Show all on a 3 MB file stays virtualized and capped', (
    tester,
  ) async {
    final lines = List.generate(
      120000,
      (i) => 'row $i of a very big file',
    ).join('\n');
    expect(lines.length, greaterThan(3000000));
    await pumpOmp(
      tester,
      FileMentionRow(
        item: item([
          {'path': 'massive.log', 'lineCount': 120000, 'content': lines},
        ]),
      ),
    );
    await tester.tap(find.textContaining('massive.log'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Show all'));
    await tester.pumpAndSettle();

    // Hard cap with an honest note: the first 200k characters only.
    expect(find.text('Showing the first 200k characters.'), findsOneWidget);
    // Virtualized: only the chunks near the viewport are built, never all of
    // them (200k chars at ~2k per chunk would be ~100 chunks).
    final built = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byType(ListView),
            matching: find.byWidgetPredicate(
              (w) => w is Text && w.data != null && w.data!.startsWith('row'),
            ),
          ),
        )
        .length;
    expect(built, greaterThan(0));
    expect(built, lessThan(30));
    expect(tester.takeException(), isNull);
  });

  testWidgets("Copy all puts the FULL content on the clipboard", (
    tester,
  ) async {
    final content = List.generate(
      30000,
      (i) => 'row $i',
    ).join('\n'); // > 200k chars? no: keep over preview, under cap is fine
    final big = content + content + content + content + content;
    expect(big.length, greaterThan(contentPreviewChars));
    final clipboard = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        clipboard.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pumpOmp(
      tester,
      FileMentionRow(
        item: item([
          {'path': 'big.txt', 'lineCount': 1, 'content': big},
        ]),
      ),
    );
    await tester.tap(find.textContaining('big.txt'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Show all'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy all'));
    await tester.pump();
    expect(clipboard.last.method, 'Clipboard.setData');
    expect((clipboard.last.arguments as Map<Object?, Object?>)['text'], big);
  });

  testWidgets('semantics: each file row is its own tappable node', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpOmp(
      tester,
      FileMentionRow(
        item: item([
          {'path': 'main.dart', 'lineCount': 1, 'content': 'x'},
          {'path': 'big.bin', 'skippedReason': 'tooLarge'},
          {'path': 'logo.png', 'image': true},
        ]),
      ),
    );
    final nodes = _allNodes(tester);
    String label(SemanticsNode n) => n.getSemanticsData().label;
    final main = nodes.where((n) => label(n).contains('main.dart')).toList();
    final bin = nodes.where((n) => label(n).contains('too large')).toList();
    expect(main, hasLength(1), reason: 'main.dart is its own focusable node');
    expect(bin, hasLength(1), reason: 'the skipped file stays its own node');
    // The row is its own stop: the rest of the group (skipped files, the
    // 'Attached files' label) must not merge into its label.
    expect(label(main.single), isNot(contains('too large')));
    expect(label(main.single), isNot(contains('image')));
    expect(
      main.single.getSemanticsData().hasAction(SemanticsAction.tap),
      isTrue,
      reason: 'each file row keeps its own tap action',
    );
    handle.dispose();
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

List<SemanticsNode> _allNodes(WidgetTester tester) {
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
