// Ported from web/src/lib/state/__tests__/reviewed.test.ts (the persistence
// tests; the two send-clears-pin cases are D2, see the bottom of this file).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ohmypi/state/connection_notifier.dart';
import 'package:ohmypi/state/connection_store.dart';
import 'package:ohmypi/state/reviewed_store.dart';

/// In-memory stand-in for device storage, with per-key gates so tests can
/// hold loads in flight.
class MemoryKv implements ReviewedKv {
  final map = <String, String>{};
  final _gates = <String, Completer<void>>{};

  void gate(String key) => _gates[key] = Completer<void>();

  void release(String key) => _gates[key]?.complete();

  @override
  Future<String?> get(String key) async {
    final gate = _gates[key];
    if (gate != null) await gate.future;
    return map[key];
  }

  @override
  Future<void> set(String key, String value) async => map[key] = value;
}

class MemoryPrefs implements ConnectionPrefs {
  MemoryPrefs([this.records = const []]);
  final List<ConnectionRecord> records;

  @override
  Future<List<ConnectionRecord>> load() async => records;

  @override
  Future<void> save(List<ConnectionRecord> connections) async {}
}

class _FixedTokens implements TokenStore {
  const _FixedTokens();

  @override
  Future<String?> read(String connectionId) async => 'tok';

  @override
  Future<void> write(String connectionId, String token) async {}

  @override
  Future<void> delete(String connectionId) async {}
}

final _c1 = ConnectionRecord(id: 'c1', url: 'https://g', label: 'G1');
final _c2 = ConnectionRecord(id: 'c2', url: 'https://g2', label: 'G2');

/// [activeId] picks the signed-in connection ('c1' or 'c2'); the notifier's
/// async initial load settles to it once the first test pumps the event
/// queue (see the connection-switch tests).
ProviderContainer makeContainer(MemoryKv kv, {String activeId = ''}) {
  final container = ProviderContainer(overrides: [
    reviewedKvProvider.overrideWithValue(kv),
    if (activeId.isNotEmpty) ...[
      // The most recently added connection is the default active one.
      connectionPrefsProvider
          .overrideWithValue(MemoryPrefs(activeId == 'c2' ? [_c2, _c1] : [_c1, _c2])),
      tokenStoreProvider.overrideWithValue(const _FixedTokens()),
    ] else
      connectionPrefsProvider.overrideWithValue(MemoryPrefs()),
  ]);
  addTearDown(container.dispose);
  return container;
}

void _setActive(ProviderContainer container, String id) {
  final c = container.read(connectionNotifierProvider);
  container.read(connectionNotifierProvider.notifier).state = ConnectionState(
      connections: c.connections,
      activeId: c.connections.any((r) => r.id == id) ? id : null);
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

  test('a connection switch discards an in-flight load for the old connection',
      () async {
    final kv = MemoryKv();
    kv.map['ompgw-reviewed:c1'] = '["stale"]';
    kv.map['ompgw-reviewed:c2'] = '["fresh"]';
    kv.gate('ompgw-reviewed:c1');
    final container = makeContainer(kv, activeId: 'c1');
    await pumpEventQueue(); // let the connection load settle on c1
    final sub = container.listen(reviewedStoreProvider, (_, _) {});
    await pumpEventQueue();

    // Switch connections while c1's load is still pending.
    _setActive(container, 'c2');
    await pumpEventQueue();
    expect(container.read(reviewedStoreProvider).done, {'fresh'});

    // Now the old load completes: it must be discarded, not merged in.
    kv.release('ompgw-reviewed:c1');
    await pumpEventQueue();
    expect(container.read(reviewedStoreProvider).done, {'fresh'},
        reason: "the first connection's data never lands in the second's state");
    sub.close();
  });

  test('clear() marks the store dirty so a pending load cannot resurrect data',
      () async {
    final kv = MemoryKv();
    kv.map['ompgw-reviewed:c1'] = '["x"]';
    kv.gate('ompgw-reviewed:c1');
    final container = makeContainer(kv, activeId: 'c1');
    final store = container.read(reviewedStoreProvider.notifier);
    container.read(reviewedStoreProvider);
    await pumpEventQueue();

    await store.clear();
    kv.release('ompgw-reviewed:c1');
    await pumpEventQueue();

    expect(container.read(reviewedStoreProvider).done, isEmpty,
        reason: 'the in-flight load must not overwrite clear()');
  });

  // TODO(D2): port the two remaining reviewed.test.ts cases once the send
  // path exists - "clears the review pin when a prompt is sent from the
  // session" and "keeps the pin when the send fails".
}
