// Widget tests for ThinkingRow, ToolGroup, ToolOutput, DiffBlock, NoticeLine,
// CommandCard and SkillChip, plus the TranscriptItemView switch under all four
// theme presets.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ohmypi/theme/presets.dart';
import 'package:ohmypi/transcript/diff.dart';
import 'package:ohmypi/transcript/items.dart';
import 'package:ohmypi/widgets/items/command_card.dart';
import 'package:ohmypi/widgets/items/diff_block.dart';
import 'package:ohmypi/widgets/items/notice_line.dart';
import 'package:ohmypi/widgets/items/skill_chip.dart';
import 'package:ohmypi/widgets/items/thinking_row.dart';
import 'package:ohmypi/widgets/items/tool_group.dart';
import 'package:ohmypi/widgets/items/tool_output.dart';
import 'package:ohmypi/widgets/transcript_item.dart';

import '../pump_omp.dart';

Text richText(WidgetTester tester) =>
    tester.widget<Text>(find.byWidgetPredicate(
      (w) => w is Text && w.textSpan != null,
    ).first);

ThinkingItem think({bool streaming = false, int? started, int? ended}) =>
    ThinkingItem(
      id: 't1',
      text: 'considering the options',
      streaming: streaming,
      startedAt: started,
      endedAt: ended,
    );

ToolItem tool({
  String status = 'done',
  String output = 'ok',
  List<FileChange>? files,
  int? started,
  int? ended,
}) =>
    ToolItem(
      id: 'tool-1',
      toolCallId: 'call-1',
      toolName: 'read_file',
      summary: 'src/main.dart',
      output: output,
      status: status,
      files: files,
      startedAt: started,
      endedAt: ended,
    );

void main() {
  group('ThinkingRow', () {
    testWidgets('collapsed by default, label from timing', (tester) async {
      await pumpOmp(
        tester,
        ThinkingRow(
            item: think(started: 1000, ended: 13000)),
      );
      expect(find.text('Thought for 12 s'), findsOneWidget);
      expect(find.text('considering the options'), findsNothing);
    });

    testWidgets('streaming reads Thinking, tap expands and collapses',
        (tester) async {
      await pumpOmp(tester, ThinkingRow(item: think(streaming: true)));
      expect(find.text('Thinking'), findsOneWidget);
      await tester.tap(find.text('Thinking'));
      await tester.pumpAndSettle();
      expect(find.text('considering the options'), findsOneWidget);
      await tester.tap(find.text('Thinking'));
      await tester.pumpAndSettle();
      expect(find.text('considering the options'), findsNothing);
    });

    testWidgets('without timing reads Thought', (tester) async {
      await pumpOmp(tester, ThinkingRow(item: think()));
      expect(find.text('Thought'), findsOneWidget);
    });
  });

  group('ToolGroup', () {
    testWidgets('summary row shows name, summary and duration; expands',
        (tester) async {
      await pumpOmp(
        tester,
        ToolGroup(tools: [tool(started: 0, ended: 12000)]),
      );
      expect(find.text('read_file'), findsOneWidget);
      expect(find.text('src/main.dart'), findsOneWidget);
      expect(find.text('12 s'), findsOneWidget);
      expect(find.text('ok'), findsNothing);
      await tester.tap(find.text('read_file'));
      await tester.pumpAndSettle();
      expect(find.text('ok'), findsOneWidget);
      expect(find.text('Copy output'), findsOneWidget);
    });

    testWidgets('errored tool renders red and keeps raw output', (tester) async {
      await pumpOmp(
        tester,
        ToolGroup(tools: [tool(status: 'error', output: 'EACCES')]),
      );
      final name = tester.widget<Text>(find.text('read_file'));
      final t = tokensOf(tester, OmpPreset.terminal);
      expect(name.style?.color, t.err);
      await tester.tap(find.text('read_file'));
      await tester.pumpAndSettle();
      expect(find.text('EACCES'), findsOneWidget);
    });

    testWidgets('file changes show +/- stat and diff blocks on expand',
        (tester) async {
      const diff = '+1|new line\n-1|old line\n 2|kept\n';
      final files = [
        const FileChange(
            path: 'src/a.dart',
            op: 'update',
            diff: diff,
            adds: 1,
            dels: 1,
            created: false),
      ];
      await pumpOmp(tester, ToolGroup(tools: [tool(files: files)]));
      expect(find.text('+1'), findsOneWidget);
      expect(find.text('-1'), findsOneWidget);
      await tester.tap(find.text('read_file'));
      await tester.pumpAndSettle();
      expect(find.byType(DiffBlock), findsOneWidget);
      expect(find.textContaining('new line'), findsOneWidget);
      expect(find.textContaining('old line'), findsOneWidget);
    });

    testWidgets('semantics label carries status, tool and summary',
        (tester) async {
      final handle = tester.ensureSemantics();
      await pumpOmp(tester, ToolGroup(tools: [tool()]));
      expect(find.bySemanticsLabel(RegExp('Done: read_file src/main.dart')),
          findsOneWidget);
      handle.dispose();
    });

    testWidgets('rows are keyed by the tool id', (tester) async {
      await pumpOmp(tester, ToolGroup(tools: [tool()]));
      expect(find.byKey(const ValueKey('tool-1')), findsOneWidget);
    });
  });

  group('ToolOutput', () {
    testWidgets('ANSI spans carry token colors', (tester) async {
      await pumpOmp(
        tester,
        ToolOutput(text: '\x1b[31mred\x1b[0m \x1b[32mgreen\x1b[0m', error: false),
      );
      final rich = richText(tester);
      final spans = (rich.textSpan as TextSpan).children!;
      final t = tokensOf(tester, OmpPreset.terminal);
      final red = spans.whereType<TextSpan>().first;
      expect(red.text, 'red');
      expect(red.style!.color, t.err);
      final green = spans.whereType<TextSpan>().firstWhere((s) => s.text == 'green');
      expect(green.style!.color, t.ok);
    });

    testWidgets('long output truncates at 200 lines with a show-more button',
        (tester) async {
      final text = List.generate(250, (i) => 'line $i').join('\n');
      await pumpOmp(tester, ToolOutput(text: text, error: false));
      expect(find.textContaining('line 199'), findsOneWidget);
      expect(find.textContaining('line 240'), findsNothing);
      expect(find.text('Show all 250 lines'), findsOneWidget);
      await tester.tap(find.text('Show all 250 lines'));
      await tester.pumpAndSettle();
      expect(find.textContaining('line 240'), findsOneWidget);
    });

    testWidgets('empty output and file-change variants', (tester) async {
      await pumpOmp(tester, ToolOutput(text: '  \n', error: false));
      expect(find.text('No output'), findsOneWidget);
      await pumpOmp(
        tester,
        ToolOutput(
          text: '',
          error: false,
          files: const [
            FileChange(
                path: 'new.dart',
                op: 'create',
                diff: '+1|hello\n',
                adds: 1,
                dels: 0,
                created: true),
          ],
        ),
      );
      expect(find.text('A'), findsOneWidget);
      expect(find.textContaining('hello'), findsOneWidget);
    });

    testWidgets('error output keeps text even with files', (tester) async {
      await pumpOmp(
        tester,
        ToolOutput(
          text: 'refused',
          error: true,
          files: const [
            FileChange(
                path: 'x.dart',
                op: 'update',
                diff: '+1|a\n',
                adds: 1,
                dels: 0,
                created: false),
          ],
        ),
      );
      expect(find.text('refused'), findsOneWidget);
      expect(find.byType(DiffBlock), findsNothing);
    });
  });

  group('DiffBlock', () {
    const diff = '+1|added one\n-1|removed\n 2|ctx\n...\n+2|added two\n';

    testWidgets('header shows badge and counts', (tester) async {
      await pumpOmp(
        tester,
        const DiffBlock(
          file: FileChange(
              path: 'lib/very/deep/nested/file.dart',
              op: 'update',
              diff: diff,
              adds: 2,
              dels: 1,
              created: false),
        ),
      );
      expect(find.text('M'), findsOneWidget);
      expect(find.text('…/deep/nested/file.dart'), findsOneWidget);
      expect(find.text('+2'), findsOneWidget);
      expect(find.text('-1'), findsOneWidget);
      expect(find.textContaining('added one'), findsOneWidget);
      expect(find.textContaining('removed'), findsOneWidget);
      expect(find.textContaining('added two'), findsOneWidget);
    });

    testWidgets('created file gets an A badge, empty diff reads Empty file',
        (tester) async {
      await pumpOmp(
        tester,
        const DiffBlock(
          file: FileChange(
              path: 'new.dart',
              op: 'create',
              diff: '',
              adds: 0,
              dels: 0,
              created: true),
        ),
      );
      expect(find.text('A'), findsOneWidget);
      expect(find.text('Empty file'), findsOneWidget);
    });

    testWidgets('word marks highlight the changed slice', (tester) async {
      await pumpOmp(
        tester,
        const DiffBlock(
          file: FileChange(
              path: 'a.dart',
              op: 'update',
              diff: '-1|const alpha = 1;\n+1|const alpha = 2;\n',
              adds: 1,
              dels: 1,
              created: false),
        ),
      );
      final rich = tester.widgetList<Text>(find.byWidgetPredicate(
        (w) => w is Text && w.textSpan != null,
      )).last;
      final spans = (rich.textSpan as TextSpan).children!.whereType<TextSpan>();
      final marked = spans
          .where((s) => s.style?.background != null && (s.text?.isNotEmpty ?? false))
          .toList();
      expect(marked, isNotEmpty);
      expect(marked.any((s) => s.text!.contains('2')), isTrue);
    });

    testWidgets('rows are selectable', (tester) async {
      await pumpOmp(
        tester,
        const DiffBlock(
          file: FileChange(
              path: 'a.dart',
              op: 'update',
              diff: diff,
              adds: 2,
              dels: 1,
              created: false),
        ),
      );
      expect(find.byType(SelectionArea), findsOneWidget);
    });

    testWidgets('large diffs render in 400-row steps with show more',
        (tester) async {
      final big = List.generate(900, (i) => ' ${i + 1}|L$i').join('\n');
      await pumpOmp(
        tester,
        DiffBlock(
          file: FileChange(
              path: 'big.dart',
              op: 'update',
              diff: big,
              adds: 0,
              dels: 0,
              created: false),
        ),
      );
      // First step: 400 rows.
      expect(find.textContaining('L399'), findsOneWidget);
      expect(find.textContaining('L400'), findsNothing);
      expect(find.text('Show 400 more lines'), findsOneWidget);

      await tester.ensureVisible(find.text('Show 400 more lines'));
      await tester.tap(find.text('Show 400 more lines'));
      await tester.pumpAndSettle();
      expect(find.textContaining('L799'), findsOneWidget);
      expect(find.textContaining('L899'), findsNothing);
      expect(find.text('Show 100 more lines'), findsOneWidget);

      await tester.ensureVisible(find.text('Show 100 more lines'));
      await tester.tap(find.text('Show 100 more lines'));
      await tester.pumpAndSettle();
      expect(find.textContaining('L899'), findsOneWidget);
      expect(find.textContaining('Show'), findsNothing);
    });
  });

  group('NoticeLine', () {
    testWidgets('info and error levels', (tester) async {
      await pumpOmp(
        tester,
        const NoticeLine(
            item: NoticeItem(id: 'n1', level: 'info', text: 'compacting')),
      );
      expect(find.text('compacting'), findsOneWidget);
      final info = tester.widget<Text>(find.text('compacting'));
      final t = tokensOf(tester, OmpPreset.terminal);
      expect(info.style?.color, t.ink3);

      await pumpOmp(
        tester,
        const NoticeLine(
            item: NoticeItem(id: 'n2', level: 'error', text: 'stream failed')),
      );
      final err = tester.widget<Text>(find.text('stream failed'));
      expect(err.style?.color, t.err);
    });

    testWidgets('active shows a progress indicator', (tester) async {
      await pumpOmp(
        tester,
        const NoticeLine(
            item: NoticeItem(
                id: 'n3', level: 'info', text: 'compacting', active: true)),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });

  group('CommandCard', () {
    testWidgets('renders the command title and ANSI-colored output',
        (tester) async {
      await pumpOmp(
        tester,
        const CommandCard(
            item: CommandItem(
                id: 'c1',
                command: 'ls -la',
                text: '\x1b[1;32mbinary\x1b[0m plain')),
      );
      expect(find.text('ls -la'), findsOneWidget);
      final rich = richText(tester);
      final spans = (rich.textSpan as TextSpan).children!;
      final t = tokensOf(tester, OmpPreset.terminal);
      final bold = spans.whereType<TextSpan>().first;
      expect(bold.text, 'binary');
      expect(bold.style!.color, t.ok);
      expect(bold.style!.fontWeight, FontWeight.w700);
      final plain = spans.whereType<TextSpan>().last;
      expect(plain.text, ' plain');
    });

    testWidgets('falls back to a generic title', (tester) async {
      await pumpOmp(
        tester,
        const CommandCard(
            item: CommandItem(id: 'c2', text: 'out')),
      );
      expect(find.text('Command output'), findsOneWidget);
    });

    testWidgets('caps at 200 lines with a show-all button', (tester) async {
      final text = List.generate(300, (i) => 'line $i').join('\n');
      await pumpOmp(
        tester,
        CommandCard(item: CommandItem(id: 'c3', text: text)),
      );
      expect(find.textContaining('line 199'), findsOneWidget);
      expect(find.textContaining('line 250'), findsNothing);
      expect(find.text('Show all 300 lines'), findsOneWidget);
      await tester.tap(find.text('Show all 300 lines'));
      await tester.pumpAndSettle();
      expect(find.textContaining('line 299'), findsOneWidget);
    });
  });

  group('SkillChip', () {
    testWidgets('collapsed by default, expands to the prompt', (tester) async {
      await pumpOmp(
        tester,
        const SkillChip(
            item: SkillItem(id: 's1', name: 'deploy', content: 'THE PROMPT')),
      );
      expect(find.text('Skill: deploy'), findsOneWidget);
      expect(find.text('THE PROMPT'), findsNothing);
      await tester.tap(find.text('Skill: deploy'));
      await tester.pumpAndSettle();
      expect(find.text('THE PROMPT'), findsOneWidget);
      expect(find.descendant(
          of: find.byType(SkillChip),
          matching: find.byType(SelectionArea)), findsOneWidget);
      await tester.tap(find.text('Skill: deploy'));
      await tester.pumpAndSettle();
      expect(find.text('THE PROMPT'), findsNothing);
    });
  });

  group('TranscriptItemView', () {
    testWidgets('smoke: every item kind under all four presets',
        (tester) async {
      const items = <Item>[
        UserItem(id: 'u', text: 'user text', images: 0, pending: false),
        AssistantItem(id: 'a', text: 'assistant text', streaming: false),
        ThinkingItem(id: 't', text: 'hmm', streaming: false),
        ToolItem(
            id: 'tool',
            toolCallId: 'c',
            toolName: 'bash',
            summary: 'ls',
            output: 'files',
            status: 'done'),
        SkillItem(id: 's', name: 'skill', content: 'prompt'),
        CommandItem(id: 'c', text: 'output'),
        NoticeItem(id: 'n', level: 'info', text: 'notice'),
      ];
      for (final preset in OmpPreset.values) {
        for (final item in items) {
          await pumpOmp(tester, TranscriptItemView(item: item),
              preset: preset);
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull, reason: 'preset ${preset.name}');
      }
    });

    testWidgets('routes a ToolItem through ToolGroup and unknown kinds stay empty',
        (tester) async {
      await pumpOmp(
        tester,
        TranscriptItemView(
          item: const ToolItem(
              id: 'x',
              toolCallId: 'c',
              toolName: 'edit',
              summary: 'a.dart',
              output: '',
              status: 'running'),
        ),
      );
      expect(find.text('edit'), findsOneWidget);
      expect(find.byType(ToolGroup), findsOneWidget);
    });
  });
}
