// Rail prefs stores: toggle/persist per connection, corrupt storage recovery,
// cap, and the load-vs-write race (a toggle before the load finishes wins).

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omai/state/connection_notifier.dart';
import 'package:omai/state/connection_store.dart';
import 'package:omai/state/rail_prefs.dart';
import 'package:omai/state/reviewed_store.dart';

class _MemoryKv implements ReviewedKv {
  final Map<String, String> map = {};
  @override
  Future<String?> get(String key) async => map[key];
  @override
  Future<void> set(String key, String value) async => map[key] = value;
}

class _Tokens implements TokenStore {
  @override
  Future<String?> read(String connectionId) async => 'tok';
  @override
  Future<void> write(String connectionId, String token) async {}
  @override
  Future<void> delete(String connectionId) async {}
}

class _Prefs implements ConnectionPrefs {
  _Prefs(this.id);
  final String id;
  // The notifier's own async load must agree with the state set below, or
  // it would replace the active connection mid-test.
  @override
  Future<List<ConnectionRecord>> load() async => [
    ConnectionRecord(id: id, url: 'https://g', label: 'G'),
  ];
  @override
  Future<void> save(List<ConnectionRecord> connections) async {}
}

ProviderContainer _container(_MemoryKv kv, {String active = 'c1'}) {
  final c = ProviderContainer(
    overrides: [
      reviewedKvProvider.overrideWithValue(kv),
      connectionPrefsProvider.overrideWithValue(_Prefs(active)),
      tokenStoreProvider.overrideWithValue(_Tokens()),
    ],
  );
  c.read(connectionNotifierProvider.notifier).state = ConnectionState(
    connections: [ConnectionRecord(id: active, url: 'https://g', label: 'G')],
    activeId: active,
  );
  return c;
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('pins toggle, persist under the connection, and reload', () async {
    final kv = _MemoryKv();
    final c = _container(kv);
    addTearDown(c.dispose);
    c.read(pinnedSessionsProvider);
    await _settle();
    await c.read(pinnedSessionsProvider.notifier).toggle('/s/a.jsonl');
    expect(c.read(pinnedSessionsProvider), {'/s/a.jsonl'});
    expect(jsonDecode(kv.map[pinnedSessionsKey('c1')]!), ['/s/a.jsonl']);

    final again = _container(kv);
    addTearDown(again.dispose);
    again.read(pinnedSessionsProvider);
    await _settle();
    expect(again.read(pinnedSessionsProvider), {'/s/a.jsonl'});

    await c.read(pinnedSessionsProvider.notifier).toggle('/s/a.jsonl');
    expect(c.read(pinnedSessionsProvider), isEmpty);
  });

  test('another connection has its own sets', () async {
    final kv = _MemoryKv()
      ..map[hiddenFoldersKey('c1')] = jsonEncode(['/home/j']);
    final c2 = _container(kv, active: 'c2');
    addTearDown(c2.dispose);
    c2.read(hiddenFoldersProvider);
    await _settle();
    expect(c2.read(hiddenFoldersProvider), isEmpty);
  });

  test('hidden folders: remove and showAll', () async {
    final kv = _MemoryKv();
    final c = _container(kv);
    addTearDown(c.dispose);
    c.read(hiddenFoldersProvider);
    await _settle();
    final store = c.read(hiddenFoldersProvider.notifier);
    await store.toggle('/a');
    await store.toggle('/b');
    await store.remove('/a');
    expect(c.read(hiddenFoldersProvider), {'/b'});
    await store.showAll();
    expect(c.read(hiddenFoldersProvider), isEmpty);
    expect(jsonDecode(kv.map[hiddenFoldersKey('c1')]!), isEmpty);
  });

  test('a toggle before the load finishes is not overwritten by it', () async {
    final kv = _MemoryKv()..map[hiddenFoldersKey('c1')] = jsonEncode(['/old']);
    final c = _container(kv);
    addTearDown(c.dispose);
    c.read(hiddenFoldersProvider);
    await c.read(hiddenFoldersProvider.notifier).toggle('/new');
    await _settle();
    expect(c.read(hiddenFoldersProvider), {'/new'});
  });

  test('corrupt storage decodes to an empty set', () {
    expect(decodeStringSet(null), isEmpty);
    expect(decodeStringSet('not-json'), isEmpty);
    expect(decodeStringSet('{"x":1}'), isEmpty);
    expect(decodeStringSet(jsonEncode(['/ok', 3, '', null])), {'/ok'});
  });

  test('the set is capped, oldest first out', () async {
    final kv = _MemoryKv();
    final c = _container(kv);
    addTearDown(c.dispose);
    c.read(pinnedSessionsProvider);
    await _settle();
    final store = c.read(pinnedSessionsProvider.notifier);
    for (var i = 0; i <= railPrefsCap; i++) {
      await store.toggle('/s/$i');
    }
    final pins = c.read(pinnedSessionsProvider);
    expect(pins.length, railPrefsCap);
    expect(pins.contains('/s/0'), isFalse);
    expect(pins.contains('/s/$railPrefsCap'), isTrue);
  });
}
