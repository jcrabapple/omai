// Ported from web/src/lib/state/__tests__/reviewed.test.ts (the persistence
// tests; the two send-clears-pin cases are D2, see the bottom of this file).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ohmypi/state/connection_notifier.dart';
import 'package:ohmypi/state/connection_store.dart';
import 'package:ohmypi/state/reviewed_store.dart';

/// In-memory stand-in for device storage.
class MemoryKv implements ReviewedKv {
  final Map<String, String> map = {};

  @override
  Future<String?> get(String key) async => map[key];

  @override
  Future<void> set(String key, String value) async => map[key] = value;
}

class MemoryPrefs implements ConnectionPrefs {
  @override
  Future<List<ConnectionRecord>> load() async => const [];

  @override
  Future<void> save(List<ConnectionRecord> connections) async {}
}

ProviderContainer makeContainer(MemoryKv kv) {
  final container = ProviderContainer(overrides: [
    reviewedKvProvider.overrideWithValue(kv),
    connectionPrefsProvider.overrideWithValue(MemoryPrefs()),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('flags, unpins and persists the needs-review set', () async {
    final kv = MemoryKv();
    final container = makeContainer(kv);
    final store = container.read(reviewedStoreProvider.notifier);
    container.read(reviewedStoreProvider);

    await store.flag('gw-a');
    expect(container.read(reviewedStoreProvider).needsReview.contains('gw-a'),
        isTrue);
    expect(kv.map['ompgw-needs-review:'], '["gw-a"]');

    await store.unflag('gw-a');
    expect(container.read(reviewedStoreProvider).needsReview.contains('gw-a'),
        isFalse);
    expect(kv.map['ompgw-needs-review:'], '[]');
  });

  test('marks done, undoes, clears and persists the done set', () async {
    final kv = MemoryKv();
    final container = makeContainer(kv);
    final store = container.read(reviewedStoreProvider.notifier);
    container.read(reviewedStoreProvider);

    await store.markDone('gw-a');
    await store.markDone('gw-b');
    expect(store.has('gw-a'), isTrue);
    expect((container.read(reviewedStoreProvider).done.toList()..sort()),
        ['gw-a', 'gw-b']);

    await store.undo('gw-a');
    expect(store.has('gw-a'), isFalse);
    expect(container.read(reviewedStoreProvider).done, ['gw-b']);

    await store.clear();
    expect(store.has('gw-b'), isFalse);
    expect(kv.map['ompgw-reviewed:'], '[]');
  });

  test('loads persisted sets once at construction and resets on junk',
      () async {
    final kv = MemoryKv();
    kv.map['ompgw-reviewed:'] = '["kept"]';
    kv.map['ompgw-needs-review:'] = '{"not":"an array"}';
    final container = makeContainer(kv);
    container.read(reviewedStoreProvider);
    await pumpEventQueue();

    final state = container.read(reviewedStoreProvider);
    expect(state.done.contains('kept'), isTrue);
    expect(state.needsReview, isEmpty);

    kv.map['ompgw-needs-review:'] = 'not json at all';
    final container2 = makeContainer(kv);
    container2.read(reviewedStoreProvider);
    await pumpEventQueue();
    expect(container2.read(reviewedStoreProvider).needsReview, isEmpty);
    container2.dispose();
  });

  test('markDone also clears the review pin', () async {
    final kv = MemoryKv();
    final container = makeContainer(kv);
    final store = container.read(reviewedStoreProvider.notifier);
    container.read(reviewedStoreProvider);

    await store.flag('gw-a');
    await store.markDone('gw-a');
    expect(container.read(reviewedStoreProvider).needsReview, isEmpty);
    expect(kv.map['ompgw-needs-review:'], '[]');
  });

  test('caps the done ledger', () async {
    final kv = MemoryKv();
    final container = makeContainer(kv);
    final store = container.read(reviewedStoreProvider.notifier);
    container.read(reviewedStoreProvider);

    for (var i = 0; i < doneLedgerCap + 10; i++) {
      await store.markDone('gw-$i');
    }
    final done = container.read(reviewedStoreProvider).done;
    expect(done.length, doneLedgerCap);
    expect(done.contains('gw-0'), isFalse);
    expect(done.contains('gw-${doneLedgerCap + 9}'), isTrue);
  });

  // TODO(D2): port the two remaining reviewed.test.ts cases once the send
  // path exists - "clears the review pin when a prompt is sent from the
  // session" and "keeps the pin when the send fails".
}
