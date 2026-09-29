// Render blocks: the reducer's items with consecutive tool calls folded into
// one group. Ported from web/src/lib/transcript/blocks.ts.
import 'items.dart';

sealed class Block {
  final String key;
  const Block(this.key);

  String get kind;
}

class ItemBlock extends Block {
  final Item item;
  const ItemBlock({required String key, required this.item}) : super(key);

  @override
  String get kind => 'item';
}

class ToolsBlock extends Block {
  final List<ToolItem> tools;
  const ToolsBlock({required String key, required this.tools}) : super(key);

  @override
  String get kind => 'tools';
}

List<Block> toBlocks(List<Item> items) {
  final out = <Block>[];
  for (final item in items) {
    if (item is ToolItem) {
      final last = out.isEmpty ? null : out.last;
      if (last is ToolsBlock) {
        last.tools.add(item);
      } else {
        out.add(ToolsBlock(key: 'tools:${item.id}', tools: [item]));
      }
    } else {
      out.add(ItemBlock(key: item.id, item: item));
    }
  }
  return out;
}

/// True while the newest item is already showing progress, so no extra
/// "Working" line is needed.
bool showsProgress(List<Item> items) {
  if (items.isEmpty) return false;
  final last = items.last;
  if (last is AssistantItem || last is ThinkingItem) {
    return last is AssistantItem ? last.streaming : (last as ThinkingItem).streaming;
  }
  if (last is ToolItem) return last.status == 'running';
  if (last is NoticeItem) return last.active == true;
  return false;
}
