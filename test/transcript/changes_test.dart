// Ported from web/src/lib/transcript/__tests__/changes.test.ts.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ohmypi/transcript/changes.dart';
import 'package:ohmypi/transcript/diff.dart';
import 'package:ohmypi/transcript/items.dart';
import 'package:ohmypi/transcript/reducer.dart';

void main() {
  final edits = jsonDecode(File('test/fixtures/transcript/edits.json').readAsStringSync())
      as Map<String, Object?>;
  final items = reduce(
          emptyTranscript(),
          HistoryInput((edits['messages'] as List).cast<Map<String, Object?>>()))
      .items;

  group('collectChanges', () {
    test('rolls up every file change with counts', () {
      final r = collectChanges(items);
      expect(
          r.groups.map((g) => g.path),
          [
            'src/greeter.py',
            '/work/CHANGELOG.md',
            'src/config.py',
            'src/config.schema.json',
          ]);
      expect(r.files, 4);
      expect(r.edits, 4);
      expect(r.adds, 9);
      expect(r.dels, 2);
    });

    test('keeps the latest diff per path and totals from it', () {
      final twice = [
        ...items,
        ToolItem(
          id: 'tool:again',
          toolCallId: 'again',
          toolName: 'edit',
          args: {'path': 'src/greeter.py'},
          summary: 'src/greeter.py',
          output: '',
          status: 'done',
          files: [
            const FileChange(
                path: 'src/greeter.py',
                op: 'update',
                diff: '-1|x\n+1|y',
                adds: 1,
                dels: 1,
                created: false),
          ],
        ),
      ];
      final r = collectChanges(twice);
      expect(r.files, 4);
      expect(r.edits, 5);
      expect(r.groups[0].file.diff, '-1|x\n+1|y');
      expect(r.adds, 9);
    });

    test('ignores items without files', () {
      expect(collectChanges(const []),
          const ChangesRollup([], 0, 0, 0, 0));
      expect(collectChanges(items.where((it) => it.kind != 'tool').toList()).files, 0);
    });

    test('skips errored tools entirely', () {
      const failed = ToolItem(
        id: 'tool:bad',
        toolCallId: 'bad',
        toolName: 'edit',
        args: {'path': 'nope.py'},
        summary: 'nope.py',
        output: 'no such file',
        status: 'error',
        files: [
          FileChange(
              path: 'nope.py',
              op: 'update',
              diff: '+1|never happened',
              adds: 1,
              dels: 0,
              created: false),
        ],
      );
      final r = collectChanges([failed, ...items]);
      expect(r.files, 4);
      expect(r.edits, 4);
      expect(r.groups.map((g) => g.path), isNot(contains('nope.py')));
    });

    test('normalizes separators and trailing slashes when grouping paths', () {
      Item entry(String path) => ToolItem(
            id: 'tool:$path',
            toolCallId: path,
            toolName: 'edit',
            args: {'path': path},
            summary: path,
            output: '',
            status: 'done',
            files: [
              FileChange(
                  path: path,
                  op: 'update',
                  diff: '+1|x',
                  adds: 1,
                  dels: 0,
                  created: false),
            ],
          );
      final r = collectChanges(
          [entry(r'src\lib\a.ts'), entry('src/lib/a.ts'), entry('docs/'), entry('docs')]);
      expect(r.groups.map((g) => g.path), ['src/lib/a.ts', 'docs']);
      expect(r.files, 2);
    });
  });
}
