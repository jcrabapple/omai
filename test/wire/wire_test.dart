// Tests for the wire accessors: tolerant reads, UiRequest.isBlocking, event
// wrapping and unknown fields.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:omai/wire/wire.dart';

Map<String, Object?> m(Object? Function() f) => f() as Map<String, Object?>;

void main() {
  group('accessors', () {
    test('strOf, intOf, boolOf return null on missing or wrong types', () {
      final raw = jsonDecode('{"a":"x","b":3,"c":true,"d":[1],"e":{"k":1},"f":null,"g":1.5}')
          as Map<String, Object?>;
      expect(strOf(raw, 'a'), 'x');
      expect(strOf(raw, 'b'), isNull);
      expect(strOf(raw, 'missing'), isNull);
      expect(intOf(raw, 'b'), 3);
      expect(intOf(raw, 'g'), 1);
      expect(intOf(raw, 'a'), isNull);
      expect(boolOf(raw, 'c'), isTrue);
      expect(boolOf(raw, 'a'), isNull);
      expect(listOf(raw['d']), [1]);
      expect(mapOf(raw['e']), {'k': 1});
      expect(mapOf(raw['d']), isNull);
      expect(mapOf(raw['f']), isNull);
    });
  });

  group('content blocks', () {
    test('ToolCallBlock.from reads a toolCall block and rejects others', () {
      final call = ToolCallBlock.from({
        'type': 'toolCall',
        'id': 'c1',
        'name': 'bash',
        'arguments': {'command': 'ls'},
        'intent': 'Listing',
      });
      expect(call?.id, 'c1');
      expect(call?.name, 'bash');
      expect(call?.arguments, {'command': 'ls'});
      expect(call?.intent, 'Listing');
      expect(ToolCallBlock.from({'type': 'text', 'text': 'hi'}), isNull);
      expect(ToolCallBlock.from('nope'), isNull);
      expect(ToolCallBlock.from({'type': 'toolCall'}), isNull);
    });
  });

  group('message accessors', () {
    test('reads roles, steering, display, custom type, details, isError', () {
      final user = <String, Object?>{
        'role': 'user',
        'content': 'hi',
        'steering': true,
        'timestamp': 5,
      };
      expect(isRole(user, 'user'), isTrue);
      expect(messageContent(user), 'hi');
      expect(messageSteering(user), isTrue);
      expect(messageTimestamp(user), 5);
      expect(messageSteering(<String, Object?>{'role': 'user'}), isFalse);

      final custom = <String, Object?>{
        'role': 'custom',
        'customType': 'skill-prompt',
        'display': false,
        'details': {'prompt': '/x'},
      };
      expect(messageDisplay(custom), isFalse);
      expect(messageCustomType(custom), 'skill-prompt');
      expect(messageDetails(custom), {'prompt': '/x'});
      expect(messageDisplay(<String, Object?>{'role': 'custom'}), isTrue);

      final result = <String, Object?>{
        'role': 'toolResult',
        'toolCallId': 't1',
        'toolName': 'bash',
        'isError': true,
      };
      expect(messageToolCallId(result), 't1');
      expect(messageToolName(result), 'bash');
      expect(messageIsError(result), isTrue);
      expect(messageIsError(<String, Object?>{}), isFalse);
    });
  });

  group('UiRequest', () {
    test('blocking methods are select, confirm, input, editor', () {
      for (final method in ['select', 'confirm', 'input', 'editor']) {
        final u = UiRequest({'id': 'a', 'method': method});
        expect(isBlockingUi(u), isTrue, reason: method);
        expect(isBlockingUiMap(u.raw), isTrue, reason: method);
      }
      for (final method in ['notify', 'setStatus', 'setWidget', 'setTitle', 'set_editor_text', 'open_url']) {
        final u = UiRequest({'id': 'a', 'method': method});
        expect(isBlockingUi(u), isFalse, reason: method);
      }
      expect(isBlockingUiMap(<String, Object?>{}), isFalse);
    });

    test('reads dialog fields and tolerates unknown fields', () {
      final u = UiRequest({
        'id': 'x',
        'method': 'select',
        'title': 'Allow tool: bash',
        'message': 'run it?',
        'options': ['Approve', 'Deny'],
        'placeholder': 'p',
        'prefill': 'pf',
        'text': 't',
        'timeout': 30,
        'somethingNew': {'nested': 1},
      });
      expect(u.id, 'x');
      expect(u.method, 'select');
      expect(u.title, 'Allow tool: bash');
      expect(u.message, 'run it?');
      expect(u.options, ['Approve', 'Deny']);
      expect(u.placeholder, 'p');
      expect(u.prefill, 'pf');
      expect(u.text, 't');
      expect(u.timeout, 30);
      expect(u.raw.containsKey('somethingNew'), isTrue);
      expect(UiRequest.from(<String, Object?>{'id': 'y', 'method': 'input'})?.id, 'y');
      expect(UiRequest.from('nope'), isNull);
    });
  });

  group('OmpEvent', () {
    test('type defaults to empty string, fields read tolerantly', () {
      final ev = OmpEvent({
        'type': 'tool_execution_start',
        'toolCallId': 't1',
        'toolName': 'bash',
        'args': {'command': 'ls'},
        'intent': 'Listing',
      });
      expect(ev.type, 'tool_execution_start');
      expect(ev.toolCallId, 't1');
      expect(ev.toolName, 'bash');
      expect(ev.args, {'command': 'ls'});
      expect(ev.intent, 'Listing');
      expect(ev.messageId, isNull);
      expect(ev.message, isNull);
      expect(ev.partialMessage, isNull);

      final unknown = OmpEvent({'type': 'advisor_cost_changed', 'x': 1});
      expect(unknown.type, 'advisor_cost_changed');
      expect(unknown.toolCallId, isNull);

      expect(OmpEvent(<String, Object?>{}).type, '');
    });

    test('assistant message events expose message, partial and flags', () {
      final partial = {
        'type': 'message_update',
        'messageId': 'm1',
        'message': {'role': 'assistant', 'content': 'hi'},
        'assistantMessageEvent': {
          'type': 'thinking_delta',
          'partial': {'role': 'assistant', 'content': []},
        },
        'isError': false,
      };
      final ev = OmpEvent(partial);
      expect(ev.messageId, 'm1');
      expect(ev.message?['role'], 'assistant');
      expect(ev.partialMessage?['role'], 'assistant');
      expect(ev.assistantMessageEvent?['type'], 'thinking_delta');
      expect(ev.isError, isFalse);
      expect(ev.agentInvokedFalse, isFalse);
      expect(OmpEvent({'type': 'prompt_result', 'agentInvoked': false}).agentInvokedFalse, isTrue);
    });
  });
}
