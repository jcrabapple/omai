// Ports of the web drafts behaviour (web/src/lib/composer/drafts.ts and its
// use in Composer.svelte): survives the provider going away, keyed per
// connection + session, cleared on successful send, whitespace clears.
import 'package:flutter_test/flutter_test.dart';
import 'package:ohmypi/composer/drafts.dart';

class MemoryDraftKv implements DraftKv {
  final map = <String, String>{};
  @override
  Future<String?> get(String key) async => map[key];
  @override
  Future<void> set(String key, String value) async => map[key] = value;
  @override
  Future<void> remove(String key) async => map.remove(key);
}

void main() {
  test('saves and loads a draft per connection + session', () async {
    final kv = MemoryDraftKv();
    await saveDraft(kv, 'c1', 'gw-a', 'hello world');
    expect(await loadDraft(kv, 'c1', 'gw-a'), 'hello world');
    // A different session (or connection) sees nothing.
    expect(await loadDraft(kv, 'c1', 'gw-b'), '');
    expect(await loadDraft(kv, 'c2', 'gw-a'), '');
  });

  test('empty or whitespace-only text clears the stored draft', () async {
    final kv = MemoryDraftKv();
    await saveDraft(kv, 'c1', 'gw-a', 'text');
    await saveDraft(kv, 'c1', 'gw-a', '   ');
    expect(kv.map.containsKey(draftKey('c1', 'gw-a')), isFalse);
    expect(await loadDraft(kv, 'c1', 'gw-a'), '');
  });

  test('clearDraft removes the key', () async {
    final kv = MemoryDraftKv();
    await saveDraft(kv, 'c1', 'gw-a', 'text');
    await clearDraft(kv, 'c1', 'gw-a');
    expect(await loadDraft(kv, 'c1', 'gw-a'), '');
  });

  test('the draft survives the kv being read from scratch (app kill)', () async {
    final kv = MemoryDraftKv();
    await saveDraft(kv, 'c1', 'gw-a', 'kept text');
    // A fresh reader over the same storage sees it.
    expect(await loadDraft(MemoryDraftKv()..map.addAll(kv.map), 'c1', 'gw-a'),
        'kept text');
  });
}
