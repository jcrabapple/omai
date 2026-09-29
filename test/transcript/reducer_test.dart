// Ported from web/src/lib/transcript/__tests__/reducer.test.ts. Every case
// kept; nothing skipped or weakened.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ohmypi/transcript/diff.dart' show FileChange;
import 'package:ohmypi/transcript/items.dart';
import 'package:ohmypi/transcript/reducer.dart';
import 'package:ohmypi/wire/wire.dart';

typedef Frame = Map<String, Object?>;

final Map<String, Object?> historyFixture =
    jsonDecode(File('test/fixtures/transcript/messages.json').readAsStringSync())
        as Map<String, Object?>;
final List<Frame> turnFixture =
    (jsonDecode(File('test/fixtures/transcript/turn-tools-markdown.json').readAsStringSync())
            as List)
        .cast<Frame>();
final List<Frame> slashFixture =
    (((jsonDecode(File('test/fixtures/transcript/slash.json').readAsStringSync())
                    as Map<String, Object?>)['events']) as List)
        .cast<Frame>();
final Map<String, Object?> editsFixture =
    jsonDecode(File('test/fixtures/transcript/edits.json').readAsStringSync())
        as Map<String, Object?>;

List<Map<String, Object?>> historyMessages() =>
    (historyFixture['messages'] as List).cast<Map<String, Object?>>();

EventInput ev(Map<String, Object?> event, [int? at]) => EventInput(OmpEvent(event), at: at);

TranscriptState play(List<Frame> frames, [TranscriptState? from]) =>
    frames.fold(from ?? emptyTranscript(),
        (s, f) => reduce(s, ev((f['event'] as Map).cast<String, Object?>())));

/// Drop what legitimately differs between history and live (timing, source
/// objects, other-client note). Mirrors the web suite's normalize().
List<Map<String, Object?>> normalize(List<Item> items) => items.map((it) => it.normalized()).toList();

int indexOfUserPrefix(List<Item> items, String prefix) {
  final i = items.indexWhere((it) => it is UserItem && it.text.startsWith(prefix));
  expect(i, greaterThanOrEqualTo(0));
  return i;
}

List<Item> fromUser(List<Item> items, String prefix) => items.sublist(indexOfUserPrefix(items, prefix));

Map<String, Object?> userMsg(String text, int timestamp) => {
      'role': 'user',
      'content': [
        {'type': 'text', 'text': text}
      ],
      'timestamp': timestamp,
    };

Map<String, Object?> steerMsg(String text, int timestamp) =>
    {...userMsg(text, timestamp), 'steering': true};

UserItem userAt(TranscriptState s, [int i = 0]) {
  final it = s.items[i];
  if (it is! UserItem) throw StateError('expected a user item');
  return it;
}

Map<String, Object?>? noteOf(Item i) => i is UserItem ? {'note': i.note} : null;

void main() {
  group('history', () {
    final s = reduce(emptyTranscript(), HistoryInput(historyMessages()));

    test('builds items in reading order', () {
      expect(s.items.map((i) => i.kind), [
        'skill', 'thinking', 'assistant', 'user', 'thinking', 'tool', 'tool', 'assistant',
      ]);
    });

    test('parses the skill name and keeps the injected prompt', () {
      final skill = s.items[0];
      if (skill is! SkillItem) throw StateError('expected skill');
      expect(skill.name, 'humanizer');
      expect(skill.prompt, '/skill:humanizer');
      expect(skill.content, isNotEmpty);
    });

    test('pairs tool calls with their results and uses the intent as summary', () {
      final tools = s.items.whereType<ToolItem>().toList();
      expect(
          tools.map((t) => [t.toolName, t.status, t.summary]),
          [
            ['bash', 'done', 'Listing gateway directory'],
            ['read', 'done', 'Reading README.md first lines'],
          ]);
      expect(tools[0].args, {'command': 'ls gateway'});
      expect(tools[0].output, contains('bridge.py'));
    });

    test('is not running and has no interrupted tools', () {
      expect(s.running, isFalse);
      expect(s.items.any((i) => i is ToolItem && i.status == 'interrupted'), isFalse);
    });

    test('marks tools without a result interrupted when the session is idle, running when streaming',
        () {
      final open = historyMessages().sublist(0, 4);
      final idle = reduce(emptyTranscript(), HistoryInput(open));
      expect(idle.items.whereType<ToolItem>().map((t) => t.status), ['interrupted', 'interrupted']);
      final busy = reduce(emptyTranscript(), HistoryInput(open, streaming: true));
      expect(busy.running, isTrue);
      expect(busy.items.whereType<ToolItem>().map((t) => t.status), ['running', 'running']);
    });
  });

  group('live events', () {
    test('yields the same items as history for the same turn', () {
      final live = play(turnFixture);
      final hist = reduce(emptyTranscript(), HistoryInput(historyMessages()));
      const prefix = 'Run `ls gateway`';
      expect(normalize(fromUser(live.items, prefix)), normalize(fromUser(hist.items, prefix)));
    });

    test('handles a capture that starts in the middle of a message', () {
      final live = play(turnFixture);
      final first = live.items.firstWhere((i) => i is AssistantItem) as AssistantItem;
      expect(first.text, contains('Skill'));
      expect(live.items.where((i) => i is AssistantItem && i.streaming), isEmpty);
    });

    test('tracks the run state and finishes streaming flags', () {
      final start = turnFixture
          .indexWhere((f) => (f['event'] as Map<String, Object?>)['type'] == 'agent_start');
      final mid = play(turnFixture.sublist(start, start + 1));
      expect(mid.running, isTrue);
      expect(play(turnFixture).running, isFalse);
    });

    test('shows streaming text as it grows and closes it on message_end', () {
      bool isMsg7(Frame f) => (f['event'] as Map<String, Object?>)['messageId'] == 'msg-7';
      final updates = turnFixture.where((f) {
        final e = f['event'] as Map<String, Object?>;
        return e['type'] == 'message_update' && e['messageId'] == 'msg-7';
      }).toList();
      final start = turnFixture.firstWhere(isMsg7);
      var s = reduce(emptyTranscript(), ev((start['event'] as Map).cast<String, Object?>()));
      s = reduce(s, ev((updates[0]['event'] as Map).cast<String, Object?>()));
      final streaming = s.items.firstWhere((i) => i is AssistantItem) as AssistantItem;
      expect(streaming.streaming, isTrue);
      final end = turnFixture.firstWhere((f) {
        final e = f['event'] as Map<String, Object?>;
        return e['type'] == 'message_end' && e['messageId'] == 'msg-7';
      });
      s = reduce(s, ev((end['event'] as Map).cast<String, Object?>()));
      final done = s.items.firstWhere((i) => i is AssistantItem) as AssistantItem;
      expect(done.streaming, isFalse);
      expect(s.items.whereType<AssistantItem>(), hasLength(1));
    });

    test('is idempotent when live events replay on top of history', () {
      final hist = reduce(emptyTranscript(), HistoryInput(historyMessages()));
      final after = play(turnFixture, hist);
      expect(after.items.map((i) => i.id), hist.items.map((i) => i.id));
      expect(normalize(after.items), normalize(hist.items));
    });

    test('ignores unknown event types and returns the same state', () {
      final s = emptyTranscript();
      expect(reduce(s, ev({'type': 'advisor_cost_changed'})), same(s));
      expect(reduce(s, ev({'type': 'something_new', 'x': 1})), same(s));
      expect(reduce(s, ev({'type': 'message_update'})), same(s));
    });

    test('never reopens a finished tool when a start or update is replayed', () {
      var s = reduce(
          emptyTranscript(),
          ev({
            'type': 'tool_execution_start',
            'toolCallId': 't1',
            'toolName': 'bash',
            'args': {'command': 'ls'}
          }, 10));
      s = reduce(
          s,
          ev({
            'type': 'tool_execution_end',
            'toolCallId': 't1',
            'toolName': 'bash',
            'result': {
              'content': [
                {'type': 'text', 'text': 'ok'}
              ]
            },
            'isError': false,
          }, 20));
      s = reduce(
          s,
          ev({
            'type': 'tool_execution_start',
            'toolCallId': 't1',
            'toolName': 'bash',
            'args': {'command': 'ls'}
          }, 30));
      s = reduce(
          s,
          ev({
            'type': 'tool_execution_update',
            'toolCallId': 't1',
            'partialResult': {'content': []}
          }, 31));
      final t = s.items[0] as ToolItem;
      expect(t.status, 'done');
      expect(t.output, 'ok');
      expect(t.startedAt, 10);
      expect(t.endedAt, 20);
      expect(t.summary, 'ls');
    });

    test('marks errored tools and interrupts leftovers on agent_end', () {
      var s = reduce(
          emptyTranscript(),
          ev({
            'type': 'tool_execution_start',
            'toolCallId': 'a',
            'toolName': 'bash',
            'args': {}
          }));
      s = reduce(
          s,
          ev({
            'type': 'tool_execution_start',
            'toolCallId': 'b',
            'toolName': 'bash',
            'args': {}
          }));
      s = reduce(
          s,
          ev({
            'type': 'tool_execution_end',
            'toolCallId': 'a',
            'result': 'boom',
            'isError': true,
          }));
      s = reduce(s, ev({'type': 'agent_end'}));
      expect(s.items.map((i) => (i as ToolItem).status), ['error', 'interrupted']);
    });

    test('keeps items of one message together even when other items arrive in between', () {
      Map<String, Object?> msg(List<Object?> content) =>
          {'role': 'assistant', 'timestamp': 5, 'content': content};
      var s = reduce(
          emptyTranscript(),
          ev({
            'type': 'message_update',
            'message': msg([
              {'type': 'text', 'text': 'hi'}
            ]),
            'assistantMessageEvent': {'type': 'text_delta'},
          }));
      s = reduce(
          s,
          const LocalSendInput(localId: 'x', text: 'steer me', mode: 'steer'));
      s = reduce(
          s,
          ev({
            'type': 'message_update',
            'message': msg([
              {'type': 'thinking', 'thinking': 'hm'},
              {'type': 'text', 'text': 'hi'}
            ]),
            'assistantMessageEvent': {'type': 'thinking_delta'},
          }));
      s = reduce(
          s,
          ev({
            'type': 'message_update',
            'message': msg([
              {'type': 'text', 'text': 'hi'},
              {'type': 'toolCall', 'id': 'c1', 'name': 'bash', 'arguments': {}}
            ]),
            'assistantMessageEvent': {'type': 'toolcall_end'},
          }));
      expect(s.items.map((i) => i.kind), ['thinking', 'assistant', 'tool', 'user']);
    });
  });

  group('echo dedupe and local sends', () {
    test('shows a local send as pending, then confirms it on echo without a duplicate', () {
      var s = reduce(
          emptyTranscript(),
          const LocalSendInput(localId: '1', text: 'hello', mode: 'prompt'));
      expect(s.items, hasLength(1));
      expect((s.items[0] as UserItem).pending, isTrue);
      s = reduce(s, ev({'type': 'message_start', 'message': userMsg('hello', 100), 'messageId': 'msg-1'}));
      s = reduce(s, ev({'type': 'message_end', 'message': userMsg('hello', 100), 'messageId': 'msg-1'}));
      expect(s.items, hasLength(1));
      final it = s.items[0] as UserItem;
      expect(it.kind, 'user');
      expect(it.pending, isFalse);
      expect(it.id, 'local:1');
      expect(it.messageKey, 'user:100');
      expect(it.note, isNull);
    });

    test('matches the echo on trimmed text and only once per pending item', () {
      var s = reduce(emptyTranscript(), const LocalSendInput(localId: '1', text: 'same ', mode: 'prompt'));
      s = reduce(s, const LocalSendInput(localId: '2', text: 'same', mode: 'follow_up'));
      s = reduce(s, ev({'type': 'message_start', 'message': userMsg('same', 1)}));
      expect(s.items.map((i) => (i as UserItem).pending), [false, true]);
      s = reduce(s, ev({'type': 'message_start', 'message': userMsg('same', 2)}));
      expect(s.items.map((i) => (i as UserItem).pending), [false, false]);
      expect(s.items, hasLength(2));
    });

    test('adds a user message from another client with a note', () {
      final s = reduce(emptyTranscript(), ev({'type': 'message_start', 'message': userMsg('from phone', 7)}));
      final it = s.items[0] as UserItem;
      expect(it.kind, 'user');
      expect(it.text, 'from phone');
      expect(it.note, 'other-client');
      expect(it.pending, isFalse);
    });

    test('notes steer and queued sends', () {
      var s = reduce(emptyTranscript(), const LocalSendInput(localId: '1', text: 'a', mode: 'steer'));
      s = reduce(s, const LocalSendInput(localId: '2', text: 'b', mode: 'follow_up'));
      s = reduce(
          s,
          const LocalSendInput(localId: '3', text: 'c', mode: 'prompt', images: [
            {'type': 'image', 'data': 'x', 'mimeType': 'image/png'}
          ]));
      expect(s.items.map((i) => (i as UserItem).note), ['steer-pending', 'queued', null]);
      expect((s.items[2] as UserItem).images, 1);
    });

    test('ignores a repeated local send id', () {
      final s = reduce(emptyTranscript(), const LocalSendInput(localId: '1', text: 'a', mode: 'prompt'));
      expect(reduce(s, const LocalSendInput(localId: '1', text: 'a', mode: 'prompt')), same(s));
    });

    test('marks a failed send', () {
      var s = reduce(emptyTranscript(), const LocalSendInput(localId: '1', text: 'a', mode: 'prompt'));
      s = reduce(s, const LocalSendFailedInput(localId: '1', error: 'Could not reach the gateway'));
      final it = s.items[0] as UserItem;
      expect(it.pending, isFalse);
      expect(it.failed, isTrue);
      expect(it.error, 'Could not reach the gateway');
    });

    test('settles leftover pending sends on session_settled', () {
      var s = reduce(
          emptyTranscript(),
          const LocalSendInput(localId: '1', text: 'expanded later', mode: 'prompt'));
      s = reduce(s, ev({'type': 'session_settled'}));
      expect((s.items[0] as UserItem).pending, isFalse);
    });

    test('keeps an unechoed local send across a history reload, and drops it once history has it',
        () {
      final base = reduce(emptyTranscript(), HistoryInput(historyMessages()));
      var s = reduce(base, const LocalSendInput(localId: '1', text: 'brand new', mode: 'prompt'));
      s = reduce(s, HistoryInput(historyMessages()));
      final last = s.items.last;
      expect(last, isA<UserItem>());
      expect((last as UserItem).text, 'brand new');
      expect(last.pending, isTrue);
      final withEcho = [
        ...historyMessages(),
        {'role': 'user', 'content': 'brand new', 'timestamp': 9e12},
      ];
      s = reduce(s, HistoryInput(withEcho));
      expect(
          s.items.where((i) => i is UserItem && i.text == 'brand new'), hasLength(1));
      expect((s.items.last as UserItem).pending, isFalse);
    });
  });

  group('steer lifecycle', () {
    test('inserts a steer-pending item whenever a steer is sent, running or not', () {
      var s = reduce(emptyTranscript(), ev({'type': 'agent_start'}));
      s = reduce(s, const LocalSendInput(localId: '1', text: 'turn left', mode: 'steer'));
      final first = s.items[0] as UserItem;
      expect(first.kind, 'user');
      expect(first.note, 'steer-pending');
      expect(first.pending, isTrue);
      expect(userAt(s).stale, isNull);
      final idle = reduce(
          emptyTranscript(),
          const LocalSendInput(localId: '2', text: 'hi', mode: 'steer'));
      expect(userAt(idle).note, 'steer-pending');
    });

    test('upgrades the pending steer to steered when the steering echo arrives', () {
      var s = reduce(emptyTranscript(), ev({'type': 'agent_start'}));
      s = reduce(s, const LocalSendInput(localId: '1', text: 'turn left', mode: 'steer'));
      s = reduce(s, ev({'type': 'message_start', 'message': steerMsg('turn left', 50), 'messageId': 'm1'}));
      expect(s.items, hasLength(1));
      final it = s.items[0] as UserItem;
      expect(it.pending, isFalse);
      expect(it.note, 'steer');
      expect(it.messageKey, 'user:50');
    });

    test('marks a steer stale when the turn ends without an echo', () {
      var s = reduce(emptyTranscript(), ev({'type': 'agent_start'}));
      s = reduce(s, const LocalSendInput(localId: '1', text: 'turn left', mode: 'steer'));
      s = reduce(s, ev({'type': 'agent_end'}));
      final it = s.items[0] as UserItem;
      expect(it.pending, isFalse);
      expect(it.note, 'steer-pending');
      expect(it.stale, isTrue);
    });

    test('marks a still-pending steer stale on session_settled', () {
      var s = reduce(emptyTranscript(), ev({'type': 'agent_start'}));
      s = reduce(s, const LocalSendInput(localId: '1', text: 'turn left', mode: 'steer'));
      s = reduce(s, ev({'type': 'session_settled'}));
      final it = s.items[0] as UserItem;
      expect(it.pending, isFalse);
      expect(it.note, 'steer-pending');
      expect(it.stale, isTrue);
    });

    test('renders a steering message from another client as steered', () {
      final s = reduce(
          emptyTranscript(), ev({'type': 'message_start', 'message': steerMsg('from phone', 7)}));
      final it = s.items[0] as UserItem;
      expect(it.kind, 'user');
      expect(it.text, 'from phone');
      expect(it.note, 'steer');
      expect(it.pending, isFalse);
    });

    test('clears the queued note when the next turn picks the follow-up up', () {
      var s = reduce(
          emptyTranscript(),
          const LocalSendInput(localId: '1', text: 'also run tests', mode: 'follow_up'));
      expect(userAt(s).note, 'queued');
      s = reduce(s, ev({'type': 'message_start', 'message': userMsg('also run tests', 20)}));
      expect(s.items, hasLength(1));
      expect((s.items[0] as UserItem).pending, isFalse);
      expect(userAt(s).note, isNull);
    });

    test('replays historical steering messages as steered', () {
      final messages = [
        steerMsg('steered once', 5),
        userMsg('plain later', 6),
      ];
      final s = reduce(emptyTranscript(), HistoryInput(messages));
      expect(
          s.items.map((i) => i is UserItem ? i.note : null), ['steer', null]);
    });

    test('does not swallow a plain prompt whose text matches a pending steer', () {
      var s = reduce(emptyTranscript(), ev({'type': 'agent_start'}));
      s = reduce(s, const LocalSendInput(localId: '1', text: 'turn left', mode: 'steer'));
      s = reduce(s, ev({'type': 'message_start', 'message': userMsg('turn left', 30), 'messageId': 'm2'}));
      expect(s.items, hasLength(2));
      expect((s.items[0] as UserItem).note, 'steer-pending');
      expect((s.items[0] as UserItem).pending, isTrue);
      final second = s.items[1] as UserItem;
      expect(second.kind, 'user');
      expect(second.text, 'turn left');
      expect(second.note, 'other-client');
      expect(second.pending, isFalse);
    });

    test('does not let a steering echo upgrade a queued follow-up with the same text', () {
      var s = reduce(
          emptyTranscript(),
          const LocalSendInput(localId: '1', text: 'run tests too', mode: 'follow_up'));
      s = reduce(
          s,
          const LocalSendInput(localId: '2', text: 'run tests too', mode: 'steer'));
      s = reduce(
          s,
          ev({'type': 'message_start', 'message': steerMsg('run tests too', 40), 'messageId': 'm3'}));
      expect(s.items, hasLength(2));
      expect((s.items[0] as UserItem).note, 'queued');
      expect((s.items[0] as UserItem).pending, isTrue);
      final second = s.items[1] as UserItem;
      expect(second.kind, 'user');
      expect(second.note, 'steer');
      expect(second.pending, isFalse);
      expect(second.messageKey, 'user:40');
    });

    test('revives a stale steer in place when its echo arrives after the turn ended', () {
      var s = reduce(emptyTranscript(), ev({'type': 'agent_start'}));
      s = reduce(s, const LocalSendInput(localId: '1', text: 'turn left', mode: 'steer'));
      s = reduce(s, ev({'type': 'agent_end'}));
      expect((s.items[0] as UserItem).pending, isFalse);
      expect((s.items[0] as UserItem).stale, isTrue);
      s = reduce(s, ev({'type': 'message_start', 'message': steerMsg('turn left', 50), 'messageId': 'm1'}));
      expect(s.items, hasLength(1));
      final it = s.items[0] as UserItem;
      expect(it.pending, isFalse);
      expect(it.stale, isFalse);
      expect(it.note, 'steer');
      expect(it.messageKey, 'user:50');
    });

    test('matches two identical steers in order', () {
      var s = reduce(emptyTranscript(), const LocalSendInput(localId: '1', text: 'hold', mode: 'steer'));
      s = reduce(s, const LocalSendInput(localId: '2', text: 'hold', mode: 'steer'));
      s = reduce(s, ev({'type': 'message_start', 'message': steerMsg('hold', 60), 'messageId': 'm1'}));
      s = reduce(s, ev({'type': 'message_start', 'message': steerMsg('hold', 61), 'messageId': 'm2'}));
      expect(s.items, hasLength(2));
      final a = s.items[0] as UserItem;
      final b = s.items[1] as UserItem;
      expect(a.note, 'steer');
      expect(a.pending, isFalse);
      expect(a.messageKey, 'user:60');
      expect(b.note, 'steer');
      expect(b.pending, isFalse);
      expect(b.messageKey, 'user:61');
    });

    test('marks a pending steer item stale on agent_end too', () {
      final seeded = TranscriptState(
        items: [
          const UserItem(id: 'u1', text: 'turn left', images: 0, pending: true, note: 'steer')
        ],
        pendingUi: const [],
        running: false,
        counter: 0,
      );
      final s = reduce(seeded, ev({'type': 'agent_end'}));
      final it = s.items[0] as UserItem;
      expect(it.pending, isFalse);
      expect(it.stale, isTrue);
      expect(it.note, 'steer-pending');
    });

    test('does not re-stale a confirmed steer on a later agent_end', () {
      var s = reduce(emptyTranscript(), ev({'type': 'agent_start'}));
      s = reduce(s, const LocalSendInput(localId: '1', text: 'turn left', mode: 'steer'));
      s = reduce(s, ev({'type': 'message_start', 'message': steerMsg('turn left', 50), 'messageId': 'm1'}));
      s = reduce(s, ev({'type': 'agent_end'}));
      s = reduce(s, ev({'type': 'agent_start'}));
      s = reduce(s, ev({'type': 'agent_end'}));
      final it = s.items[0] as UserItem;
      expect(it.pending, isFalse);
      expect(it.note, 'steer');
      expect(it.stale, isNull);
    });
  });

  group('slash commands', () {
    test('turns command output into command items with ANSI intact', () {
      final s = play(slashFixture);
      final cmds = s.items.whereType<CommandItem>().toList();
      expect(cmds, hasLength(2));
      expect(cmds[0].kind, 'command');
      expect(cmds[0].command, isNull);
      expect(cmds[0].text, contains('Context window'));
      expect(cmds[0].text, contains('\x1b['));
      expect(RegExp('^Usage').hasMatch(cmds[1].text), isTrue);
    });

    test('renders the skill prompt without a user echo, before the assistant reply', () {
      final s = play(slashFixture);
      expect(s.items.map((i) => i.kind),
          ['command', 'command', 'skill', 'thinking', 'assistant']);
      expect((s.items[2] as SkillItem).kind, 'skill');
      expect((s.items[2] as SkillItem).name, 'humanizer');
      expect(s.items.any((i) => i is UserItem), isFalse);
    });

    test('gives the same skill item from history', () {
      final live = play(slashFixture).items.firstWhere((i) => i is SkillItem);
      final hist =
          reduce(emptyTranscript(), HistoryInput(historyMessages())).items.firstWhere((i) => i is SkillItem);
      expect(normalize([live]), normalize([hist]));
    });

    test('replaces the pending slash bubble with the command output in place', () {
      var s = reduce(
          emptyTranscript(),
          const LocalSendInput(localId: '1', text: '/context', mode: 'prompt'));
      s = reduce(s, ev({'type': 'command_output', 'text': 'Context window: 10'}));
      expect(s.items, hasLength(1));
      final it = s.items[0] as CommandItem;
      expect(it.kind, 'command');
      expect(it.command, '/context');
      expect(it.text, 'Context window: 10');
      expect(it.id, 'local:1');
    });

    test('replaces the pending /skill bubble with the skill item', () {
      var s = reduce(
          emptyTranscript(),
          const LocalSendInput(localId: '1', text: '/skill:humanizer', mode: 'prompt'));
      final starts = slashFixture
          .where((f) => (f['event'] as Map<String, Object?>)['type'] == 'message_start')
          .toList();
      s = play(starts.sublist(0, 1), s);
      expect(s.items, hasLength(1));
      expect((s.items[0] as SkillItem).kind, 'skill');
      expect((s.items[0] as SkillItem).name, 'humanizer');
    });

    test('settles a silent slash command on prompt_result', () {
      var s = reduce(
          emptyTranscript(),
          const LocalSendInput(localId: '1', text: '/name foo', mode: 'prompt'));
      s = reduce(
          s,
          ev({
            'type': 'prompt_result',
            'agentInvoked': false,
            'status': 'completed',
          }));
      final it = s.items[0] as UserItem;
      expect(it.kind, 'user');
      expect(it.pending, isFalse);
    });
  });

  group('pending UI', () {
    Map<String, Object?> ask(String id, [String method = 'confirm']) =>
        {'id': id, 'method': method, 'title': 'Run it?'};

    test('collects blocking requests once and resolves them', () {
      var s = reduce(emptyTranscript(), ev({...ask('a'), 'type': 'extension_ui_request'}));
      s = reduce(s, ev({...ask('a'), 'type': 'extension_ui_request'}));
      s = reduce(s, ev({...ask('b', 'select'), 'type': 'extension_ui_request'}));
      expect(s.pendingUi.map((u) => u.id), ['a', 'b']);
      s = reduce(
          s,
          ev({
            'type': 'ui_resolved',
            'id': 'a',
            'reason': 'answered',
          }));
      expect(s.pendingUi.map((u) => u.id), ['b']);
      final again = reduce(s, ev({'type': 'ui_resolved', 'id': 'zzz'}));
      expect(again, same(s));
    });

    test('never queues fire-and-forget methods', () {
      final start = emptyTranscript();
      for (final method in ['setWidget', 'setStatus', 'setTitle', 'set_editor_text', 'open_url']) {
        expect(
            reduce(start, ev({'type': 'extension_ui_request', 'id': method, 'method': method})),
            same(start));
      }
      expect(
          turnFixture.any((f) => (f['event'] as Map<String, Object?>)['type'] == 'extension_ui_request'),
          isTrue);
      expect(play(turnFixture).pendingUi, isEmpty);
    });

    test('turns notify into one notice', () {
      var s = reduce(
          emptyTranscript(),
          ev({
            'type': 'extension_ui_request',
            'id': 'n1',
            'method': 'notify',
            'message': 'Build done',
            'notifyType': 'info',
          }));
      s = reduce(
          s,
          ev({
            'type': 'extension_ui_request',
            'id': 'n1',
            'method': 'notify',
            'message': 'Build done',
          }));
      expect(s.items, hasLength(1));
      final it = s.items[0] as NoticeItem;
      expect(it.kind, 'notice');
      expect(it.text, 'Build done');
      expect(it.level, 'info');
    });

    test('replaces the list from a session snapshot and drops non-blocking entries', () {
      var s = reduce(emptyTranscript(), ev({...ask('old'), 'type': 'extension_ui_request'}));
      s = reduce(
          s,
          PendingUiInput([
            UiRequest(ask('new')),
            UiRequest({'id': 'w', 'method': 'setWidget'}),
          ]));
      expect(s.pendingUi.map((u) => u.id), ['new']);
    });

    test('survives a history reload', () {
      var s = reduce(emptyTranscript(), ev({...ask('keep'), 'type': 'extension_ui_request'}));
      s = reduce(s, HistoryInput(historyMessages()));
      expect(s.pendingUi.map((u) => u.id), ['keep']);
    });
  });

  group('notices', () {
    test('updates the compaction notice in place', () {
      var s = reduce(
          emptyTranscript(),
          ev({
            'type': 'auto_compaction_start',
            'reason': 'threshold',
          }));
      final first = s.items[0] as NoticeItem;
      expect(first.kind, 'notice');
      expect(first.active, isTrue);
      expect(first.text, 'Compacting context');
      s = reduce(s, ev({'type': 'auto_compaction_end', 'aborted': false}));
      expect(s.items, hasLength(1));
      final it = s.items[0] as NoticeItem;
      expect(it.active, isFalse);
      expect(it.text, 'Context compacted');
      expect(it.level, 'info');
    });

    test('reports a failed compaction and a retry that gave up as errors', () {
      var s = reduce(
          emptyTranscript(),
          ev({
            'type': 'auto_compaction_end',
            'errorMessage': 'no room',
          }));
      final failed = s.items[0] as NoticeItem;
      expect(failed.level, 'error');
      expect(failed.text, 'Compaction failed: no room');
      s = reduce(
          s,
          ev({
            'type': 'auto_retry_start',
            'attempt': 1,
            'maxAttempts': 3,
            'errorMessage': '529',
          }));
      s = reduce(
          s,
          ev({
            'type': 'auto_retry_end',
            'success': false,
            'finalError': 'overloaded',
          }));
      final last = s.items.last as NoticeItem;
      expect(last.level, 'error');
      expect(last.text, 'Gave up retrying: overloaded');
      expect(last.active, isFalse);
    });

    test('notes model and thinking changes and extension errors', () {
      var s = reduce(
          emptyTranscript(),
          ev({
            'type': 'model_changed',
            'model': {'id': 'm', 'name': 'Model M', 'provider': 'p'},
          }));
      s = reduce(s, ev({'type': 'thinking_level_changed', 'level': 'high'}));
      s = reduce(s, ev({'type': 'extension_error', 'error': 'bad hook'}));
      expect(s.items.map((i) => i is NoticeItem ? i.text : null),
          ['Model: Model M', 'Thinking: high', 'Extension error: bad hook']);
      expect(s.items.map((i) => i.id).toSet().length, 3);
    });
  });

  group('helpers', () {
    test('summarizes tool arguments in the documented order', () {
      expect(summarize({'command': 'ls', 'path': 'x'}, null), 'ls');
      expect(summarize({'path': 'a.ts'}, null), 'a.ts');
      expect(summarize({'file_path': 'b.ts'}, null), 'b.ts');
      expect(summarize({'pattern': 'foo'}, null), 'foo');
      expect(summarize({'query': 'q'}, null), 'q');
      expect(summarize({'url': 'https://x'}, null), 'https://x');
      expect(summarize({'n': 1}, null), '{"n":1}');
      expect(summarize({'command': 'ls'}, 'Listing'), 'Listing');
      expect(summarize(null, null), '');
    });

    test('extracts result text from the shapes omp uses', () {
      expect(resultText(null), '');
      expect(resultText('plain'), 'plain');
      expect(
          resultText({
            'content': [
              {'type': 'text', 'text': 'a'},
              {'type': 'image'},
              {'type': 'text', 'text': 'b'},
            ]
          }),
          'a\nb');
      expect(resultText({'content': 'str'}), 'str');
      expect(resultText({'other': 1}), '{\n  "other": 1\n}');
    });

    test('splits content blocks', () {
      final b = splitContent([
        {'type': 'thinking', 'thinking': 'a'},
        {'type': 'text', 'text': 'b'},
        {'type': 'image'},
        {'type': 'toolCall', 'id': '1', 'name': 'x'},
        {'type': 'text', 'text': 'c'},
      ]);
      expect(b.thinking, 'a');
      expect(b.text, 'bc');
      expect(b.images, 1);
      expect(b.calls, hasLength(1));
      expect(splitContent('s').text, 's');
      expect(splitContent(null).text, '');
    });
  });

  group('file changes', () {
    test('extracts per-file diffs from an edit result', () {
      var s = reduce(
          emptyTranscript(),
          ev({
            'type': 'tool_execution_start',
            'toolCallId': 'e1',
            'toolName': 'edit',
            'args': {'path': 'a.py'},
          }));
      s = reduce(
          s,
          ev({
            'type': 'tool_execution_end',
            'toolCallId': 'e1',
            'toolName': 'edit',
            'result': {
              'content': [
                {'type': 'text', 'text': 'ok'}
              ],
              'details': {
                'diff': ' 1|a\n-2|b\n+2|c\n 3|d',
                'op': 'update',
                'path': 'a.py',
              },
            },
          }));
      final t = s.items[0] as ToolItem;
      expect(t.files, [
        const FileChange(
            path: 'a.py',
            op: 'update',
            diff: ' 1|a\n-2|b\n+2|c\n 3|d',
            adds: 1,
            dels: 1,
            created: false),
      ]);
    });

    test('synthesizes the write diff from call arguments', () {
      var s = reduce(
          emptyTranscript(),
          ev({
            'type': 'tool_execution_start',
            'toolCallId': 'w1',
            'toolName': 'write',
            'args': {'path': 'notes.md', 'content': 'a\nb\n'},
          }));
      s = reduce(
          s,
          ev({
            'type': 'tool_execution_end',
            'toolCallId': 'w1',
            'toolName': 'write',
            'result': {
              'content': [
                {'type': 'text', 'text': 'ok'}
              ],
              'details': {'resolvedPath': '/work/notes.md'},
            },
          }));
      final t = s.items[0] as ToolItem;
      expect(t.files, [
        const FileChange(
            path: '/work/notes.md',
            op: 'write',
            diff: '+1|a\n+2|b',
            adds: 2,
            dels: 0,
            created: true),
      ]);
    });

    test('keeps files when start or update events replay after the end', () {
      final end = ev({
        'type': 'tool_execution_end',
        'toolCallId': 'e1',
        'toolName': 'edit',
        'result': {
          'details': {'diff': '+1|new', 'op': 'create', 'path': 'n.txt'},
        },
      });
      var s = reduce(emptyTranscript(), end);
      s = reduce(
          s,
          ev({
            'type': 'tool_execution_start',
            'toolCallId': 'e1',
            'toolName': 'edit',
            'args': {'path': 'n.txt'},
          }));
      s = reduce(
          s,
          ev({
            'type': 'tool_execution_update',
            'toolCallId': 'e1',
            'partialResult': {'content': []},
          }));
      final t = s.items[0] as ToolItem;
      expect(t.status, 'done');
      expect(t.files, [
        const FileChange(path: 'n.txt', op: 'create', diff: '+1|new', adds: 1, dels: 0, created: true),
      ]);
    });

    test('gives no files to tools without diff details', () {
      var s = reduce(
          emptyTranscript(),
          ev({
            'type': 'tool_execution_start',
            'toolCallId': 'b1',
            'toolName': 'bash',
            'args': {'command': 'ls'},
          }));
      s = reduce(
          s,
          ev({
            'type': 'tool_execution_end',
            'toolCallId': 'b1',
            'toolName': 'bash',
            'result': {
              'content': [
                {'type': 'text', 'text': 'x'}
              ],
              'details': {'wallTimeMs': 4},
            },
          }));
      expect((s.items[0] as ToolItem).files, isNull);
    });

    test('drops files when the edit result is an error', () {
      var s = reduce(
          emptyTranscript(),
          ev({
            'type': 'tool_execution_start',
            'toolCallId': 'e2',
            'toolName': 'edit',
            'args': {'path': 'gone.py'},
          }));
      s = reduce(
          s,
          ev({
            'type': 'tool_execution_end',
            'toolCallId': 'e2',
            'toolName': 'edit',
            'result': {
              'content': [
                {'type': 'text', 'text': 'no such file'}
              ],
              'details': {
                'diff': '+1|would have been',
                'op': 'update',
                'path': 'gone.py',
              },
            },
            'isError': true,
          }));
      final t = s.items[0] as ToolItem;
      expect(t.status, 'error');
      expect(t.files, isNull);
    });

    test('extracts files when a write start arrives after its end', () {
      var s = reduce(
          emptyTranscript(),
          ev({
            'type': 'tool_execution_end',
            'toolCallId': 'w2',
            'toolName': 'write',
            'result': {
              'content': [
                {'type': 'text', 'text': 'ok'}
              ],
              'details': {'resolvedPath': '/work/late.md'},
            },
          }));
      expect((s.items[0] as ToolItem).files, isNull);
      s = reduce(
          s,
          ev({
            'type': 'tool_execution_start',
            'toolCallId': 'w2',
            'toolName': 'write',
            'args': {'path': 'late.md', 'content': 'hello\n'},
          }));
      expect((s.items[0] as ToolItem).files, [
        const FileChange(
            path: '/work/late.md',
            op: 'write',
            diff: '+1|hello',
            adds: 1,
            dels: 0,
            created: true),
      ]);
    });

    test('keeps files dropped when args arrive late for an errored result', () {
      var s = reduce(
          emptyTranscript(),
          ev({
            'type': 'tool_execution_end',
            'toolCallId': 'e3',
            'toolName': 'edit',
            'result': {
              'content': [
                {'type': 'text', 'text': 'rejected'}
              ],
              'details': {'diff': '+1|nope', 'op': 'update', 'path': 'x.py'},
            },
            'isError': true,
          }));
      s = reduce(
          s,
          ev({
            'type': 'tool_execution_start',
            'toolCallId': 'e3',
            'toolName': 'edit',
            'args': {'path': 'x.py'},
          }));
      expect((s.items[0] as ToolItem).status, 'error');
      expect((s.items[0] as ToolItem).files, isNull);
    });

    test('yields the same files from history and live for the same turn', () {
      final live = play((editsFixture['events'] as List).cast<Frame>());
      final hist =
          reduce(emptyTranscript(), HistoryInput((editsFixture['messages'] as List).cast<Map<String, Object?>>()));
      const prefix = 'Tighten the greeter';
      expect(normalize(fromUser(live.items, prefix)), normalize(fromUser(hist.items, prefix)));

      final tools = hist.items.whereType<ToolItem>().toList();
      expect(tools.map((t) => t.files?.length), [1, 1, 2]);
      expect(tools[0].files![0], const FileChange(
        path: 'src/greeter.py',
        op: 'update',
        diff: ' 1|def greet(name):\n-2|    return f"Hello, {name}!"\n+2|    return f"Hello again, {name}!"\n 3|',
        adds: 1,
        dels: 1,
        created: false,
      ));
      expect(tools[1].files![0].path, '/work/CHANGELOG.md');
      expect(tools[1].files![0].op, 'write');
      expect(tools[1].files![0].created, isTrue);
      expect(tools[1].files![0].adds, 4);
      expect(tools[1].files![0].dels, 0);
      expect(tools[1].args,
          {'path': 'CHANGELOG.md', 'content': '# Changelog\n\n## 1.1\n- Greeter keeps its greeting.\n'});
      expect(tools[2].files!.map((f) => f.path), ['src/config.py', 'src/config.schema.json']);
      expect(tools.map((t) => t.files).toString(), isNot(contains('xd://')));
    });
  });

  // Regression tests for Gemini review findings: TS `||` truthiness must not
  // become Dart `??` (empty strings are values, not absent).
  group('truthiness regressions', () {
    test('tool raw call is the toolCall block, not the split', () {
      final s = reduce(
          emptyTranscript(),
          ev({
            'type': 'message_start',
            'messageId': 'm1',
            'message': {
              'role': 'assistant',
              'content': [
                {
                  'type': 'toolCall',
                  'id': 'tc1',
                  'name': 'bash',
                  'arguments': {'command': 'ls'},
                }
              ],
            },
          }));
      final tool = s.items.whereType<ToolItem>().single;
      final call = (tool.raw as Map)['call'];
      expect(call, isA<ToolCallBlock>());
      final block = call as ToolCallBlock;
      expect(block.id, 'tc1');
      expect(block.name, 'bash');
      expect(block.arguments, {'command': 'ls'});
    });

    test('an errored result clears a tool that previously had files', () {
      var s = reduce(
          emptyTranscript(),
          ev({
            'type': 'tool_execution_start',
            'toolCallId': 't1',
            'toolName': 'write',
            'args': {'path': 'a.py', 'content': 'x = 1\n'},
          }));
      expect((s.items.single as ToolItem).files, isNull);
      s = reduce(
          s,
          ev({
            'type': 'tool_execution_end',
            'toolCallId': 't1',
            'result': {'content': 'ok', 'details': {'path': 'a.py', 'diff': '+1|x = 1\n'}},
          }));
      expect((s.items.single as ToolItem).files, isNotNull);
      // An error result un-does the change: files must be cleared, not kept.
      s = reduce(
          s,
          ev({
            'type': 'tool_execution_end',
            'toolCallId': 't1',
            'isError': true,
            'result': {'content': 'boom'},
          }));
      expect((s.items.single as ToolItem).files, isNull);
    });

    test('copyWith can clear nullable fields', () {
      const files = [FileChange(path: 'a', op: 'write', diff: '', adds: 0, dels: 0, created: true)];
      final tool = ToolItem(
              id: 'tool:t', toolCallId: 't', toolName: 'write', summary: '', output: '', status: 'done')
          .copyWith(files: files);
      expect(tool.copyWith(files: null).files, isNull);
      expect(tool.copyWith(files: null).status, 'done');
      final user = const UserItem(id: 'u', text: 'hi', images: 0, pending: false, failed: true)
          .copyWith(failed: null);
      expect(user.failed, isNull);
      final notice = const NoticeItem(id: 'n', level: 'info', text: 'x', tag: 'retry', active: true)
          .copyWith(tag: null, active: null);
      expect(notice.tag, isNull);
      expect(notice.active, isNull);
      final thinking = const ThinkingItem(id: 'th', text: 't', streaming: false, startedAt: 1, endedAt: 2)
          .copyWith(startedAt: null, endedAt: null);
      expect(thinking.startedAt, isNull);
      expect(thinking.endedAt, isNull);
    });

    test('an empty messageId falls back instead of keying on id:', () {
      final s = reduce(
          emptyTranscript(),
          ev({
            'type': 'message_start',
            'messageId': '',
            'message': {
              'role': 'assistant',
              'content': 'hello',
            },
          }));
      expect(s.items.single.messageKey, 'assistant:anon');
    });

    test('notify with an empty message uses the title', () {
      final s = reduce(
          emptyTranscript(),
          ev({
            'type': 'extension_ui_request',
            'method': 'notify',
            'id': 'u1',
            'message': '',
            'title': 'Fallback title',
          }));
      expect((s.items.single as NoticeItem).text, 'Fallback title');
    });

    test('an empty intent on a later patch does not erase the previous one', () {
      var s = reduce(
          emptyTranscript(),
          ev({
            'type': 'tool_execution_start',
            'toolCallId': 't9',
            'toolName': 'bash',
            'args': {'command': 'ls'},
            'intent': 'Listing files',
          }));
      s = reduce(
          s,
          ev({
            'type': 'tool_execution_update',
            'toolCallId': 't9',
            'toolName': 'bash',
            'intent': '',
          }));
      expect((s.items.single as ToolItem).intent, 'Listing files');
    });

    test('empty error strings on compaction and retry events count as absent', () {
      var s = reduce(
          emptyTranscript(),
          ev({'type': 'auto_compaction_start', 'id': 'c1'}));
      s = reduce(s, ev({'type': 'auto_compaction_end', 'errorMessage': ''}));
      final compaction = s.items.whereType<NoticeItem>().last;
      expect(compaction.text, 'Context compacted');
      expect(compaction.level, 'info');

      s = reduce(s, ev({'type': 'auto_retry_start', 'attempt': 2, 'errorMessage': ''}));
      expect((s.items.whereType<NoticeItem>().last).text, 'Retrying, attempt 2');

      s = reduce(s, ev({'type': 'auto_retry_end', 'success': false, 'finalError': ''}));
      expect((s.items.whereType<NoticeItem>().last).text, 'Gave up retrying');
      expect((s.items.whereType<NoticeItem>().last).level, 'error');
    });

    test('CommandItem.normalized includes messageKey', () {
      const item = CommandItem(id: 'c:1', messageKey: 'user:id:abc', text: 'out');
      expect(item.normalized()['messageKey'], 'user:id:abc');
    });
  });
}
