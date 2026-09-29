// Port of web/src/lib/composer/__tests__/slash.test.ts, plus the SlashCommand
// tolerant parse and the modes/approval helpers the composer uses.
import 'package:flutter_test/flutter_test.dart';
import 'package:ohmypi/composer/approval.dart';
import 'package:ohmypi/composer/modes.dart';
import 'package:ohmypi/composer/slash.dart';
import 'package:ohmypi/wire/wire.dart';

SlashCommand cmd(String name,
        {String description = '',
        String source = 'custom',
        List<String> aliases = const [],
        String? inputHint,
        List<Map<String, Object?>> subcommands = const []}) =>
    SlashCommand(
      name: name,
      description: description,
      source: source,
      aliases: aliases,
      inputHint: inputHint,
      subcommands: [
        for (final s in subcommands)
          SlashCommandSub(
              name: s['name'] as String,
              description: s['description'] as String?),
      ],
    );

final cmds = <SlashCommand>[
  cmd('compact', description: 'Compact the context', source: 'builtin'),
  cmd('model', description: 'Pick a model', source: 'builtin'),
  cmd('skill:humanizer', description: 'Rewrite text', source: 'skill'),
  cmd('deploy', description: 'Deploy it', source: 'extension', inputHint: '<env>'),
  cmd('review', description: 'Review changes', source: 'custom'),
];

List<String> names(List<SlashGroup> groups) =>
    flattenGroups(groups).map((m) => m.command.name).toList();

void main() {
  group('slash menu', () {
    test('opens only while the draft is a single slash token', () {
      expect(slashQuery('/'), '');
      expect(slashQuery('/comp'), 'comp');
      expect(slashQuery('/compact now'), isNull);
      expect(slashQuery('hello /x'), isNull);
    });

    test('groups by source in a fixed order when the query is empty', () {
      final g = filterCommands(cmds, '');
      expect(g.map((x) => x.key).toList(),
          ['commands', 'skills', 'extensions', 'custom']);
      expect(names([g.first]), ['compact', 'model']);
    });

    test('filters by name and drops empty groups', () {
      final g = filterCommands(cmds, 'mod');
      expect(g.map((x) => x.key).toList(), ['commands']);
      expect(names(g), ['model']);
    });

    test('matches a skill by its bare name', () {
      expect(names(filterCommands(cmds, 'hum')), ['skill:humanizer']);
    });

    test('fuzzy matches a subsequence and ranks prefix hits first', () {
      expect(names(filterCommands(cmds, 'cmp')), contains('compact'));
      final same = [
        cmd('undo-remove', source: 'builtin'),
        cmd('remove', source: 'builtin'),
      ];
      expect(names(filterCommands(same, 'rem')).first, 'remove');
    });

    test('returns nothing when nothing matches', () {
      expect(filterCommands(cmds, 'zzz'), isEmpty);
    });

    test('commands that take input are inserted, not sent', () {
      expect(wantsInput(cmds[3]), isTrue);
      expect(wantsInput(cmds[0]), isFalse);
      expect(slashText(cmds[3]), '/deploy ');
    });

    test('subcommands also mean the command wants input', () {
      expect(wantsInput(cmd('pick', subcommands: [
        {'name': 'a'}
      ])), isTrue);
    });

    test('unknown sources group under custom', () {
      final g = filterCommands([cmd('thing', source: 'file')], '');
      expect(g.map((x) => x.key), ['custom']);
    });

    test('parses raw gateway command objects tolerantly', () {
      final parsed = SlashCommand.listFrom([
        {
          'name': 'compact',
          'description': 'Compact\nthe context',
          'source': 'builtin',
          'aliases': ['cc'],
          'input': {'hint': '<what>'},
        },
        {'name': ''}, // no name: dropped
        'not a map', // wrong shape: dropped
      ]);
      expect(parsed.length, 1);
      expect(parsed.first.aliases, ['cc']);
      expect(parsed.first.inputHint, '<what>');
      expect(firstDescriptionLine(parsed.first), 'Compact');
      // An alias matches by prefix.
      expect(names(filterCommands(parsed, 'cc')), ['compact']);
    });
  });

  group('modes', () {
    test('approval label falls back to Yolo', () {
      expect(approvalLabel('write'), 'Write');
      expect(approvalLabel('always-ask'), 'Always ask');
      expect(approvalLabel('yolo'), 'Yolo');
      expect(approvalLabel(null), 'Yolo');
      expect(approvalLabel('unknown'), 'Yolo');
    });

    test('thinking choices are off plus the model efforts', () {
      expect(thinkingChoices(['high', 'off', 'low']), ['off', 'high', 'low']);
      expect(thinkingChoices(const []), isEmpty);
      expect(thinkingChoices(null), isEmpty);
    });
  });

  group('approval helpers', () {
    test('option tones', () {
      expect(optionTone('Allow once'), 'approve');
      expect(optionTone('  yes'), 'approve');
      expect(optionTone('Deny'), 'deny');
      expect(optionTone('cancel'), 'deny');
      expect(optionTone('Maybe later'), 'neutral');
    });

    test('splitTitle separates the headline from the command', () {
      final s = splitTitle('Run command\r\nls -la /tmp\nsecond');
      expect(s.headline, 'Run command');
      expect(s.detail, 'ls -la /tmp\nsecond');
      expect(splitTitle(null).headline, '');
      expect(splitTitle('just a headline').detail, '');
    });

    test('editorStart prefers prefill, then text', () {
      final req = UiRequest({
        'id': 'r1',
        'method': 'editor',
        'prefill': 'draft text',
      });
      expect(editorStart(req), 'draft text');
      expect(
          editorStart(UiRequest({'id': 'r2', 'method': 'editor', 'text': 't'})),
          't');
      expect(editorStart(UiRequest({'id': 'r3', 'method': 'editor'})), '');
    });

    test('answer payloads and the 409 classification', () {
      expect(UiAnswer.cancelled.toMap(), {'cancelled': true});
      expect(UiAnswer.value('yes').toMap(), {'value': 'yes'});
      expect(UiAnswer.confirmed(true).toMap(), {'confirmed': true});
      expect(classifyAnswerError(null), 'failed');
    });
  });
}
