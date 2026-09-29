// Ported from web/src/lib/transcript/__tests__/blocks.test.ts.
import 'package:flutter_test/flutter_test.dart';
import 'package:ohmypi/transcript/blocks.dart';
import 'package:ohmypi/transcript/items.dart';

ToolItem tool(String id, [String status = 'done']) => ToolItem(
      id: id,
      toolCallId: id,
      toolName: 'bash',
      summary: '',
      output: '',
      status: status,
    );

UserItem user(String id) => UserItem(id: id, text: 'hi', images: 0, pending: false);

AssistantItem assistant(String id, bool streaming) =>
    AssistantItem(id: id, text: 'x', streaming: streaming);

void main() {
  group('toBlocks', () {
    test('folds consecutive tools and keeps other items in order', () {
      final b = toBlocks([user('u'), tool('t1'), tool('t2'), assistant('a', false), tool('t3')]);
      expect(b.map((x) => x.kind), ['item', 'tools', 'item', 'tools']);
      expect(b[1].key, 'tools:t1');
      final toolsBlock = b[1] as ToolsBlock;
      expect(toolsBlock.tools.map((t) => t.id), ['t1', 't2']);
    });
  });

  group('showsProgress', () {
    test('is true for a streaming assistant or a running tool', () {
      expect(showsProgress([assistant('a', true)]), isTrue);
      expect(showsProgress([tool('t', 'running')]), isTrue);
    });
    test('is false when idle, empty, or the last item is finished', () {
      expect(showsProgress([]), isFalse);
      expect(showsProgress([assistant('a', false)]), isFalse);
      expect(showsProgress([user('u')]), isFalse);
    });
  });
}
