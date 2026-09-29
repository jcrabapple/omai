// Connection records: `{id, url, label}` in SharedPreferences, token in
// secure storage keyed by connection id (CLIENTS.md rule 6: everything
// persisted is namespaced by connection id from day one). No Flutter imports
// beyond the plugins themselves.

import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ConnectionRecord {
  const ConnectionRecord({required this.id, required this.url, required this.label});

  /// New record with a permanent random id (16 hex chars from Random.secure).
  /// The id never changes afterwards: secure-storage token keys depend on it.
  factory ConnectionRecord.create({required String url, required String label}) =>
      ConnectionRecord(id: randomConnectionId(), url: url, label: label);

  factory ConnectionRecord.fromJson(Map<String, dynamic> json) {
    return ConnectionRecord(
      id: json['id'] is String ? json['id'] as String : '',
      url: json['url'] is String ? json['url'] as String : '',
      label: json['label'] is String ? json['label'] as String : '',
    );
  }

  final String id;
  final String url;
  final String label;

  Map<String, dynamic> toJson() => {'id': id, 'url': url, 'label': label};

  ConnectionRecord copyWith({String? label}) =>
      ConnectionRecord(id: id, url: url, label: label ?? this.label);
}

/// 16 random hex chars. Generated once when a [ConnectionRecord] is created
/// and never derived from other state, so token keys cannot drift.
String randomConnectionId() {
  final rng = Random.secure();
  return List.generate(8, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// Persistence seam so tests run against in-memory maps.
abstract class ConnectionPrefs {
  Future<List<ConnectionRecord>> load();
  Future<void> save(List<ConnectionRecord> connections);
}

class SharedPrefsConnectionPrefs implements ConnectionPrefs {
  SharedPrefsConnectionPrefs();

  static const _key = 'connections.v1';
  final SharedPreferencesAsync _prefs = SharedPreferencesAsync();

  @override
  Future<List<ConnectionRecord>> load() async {
    final raw = await _prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final e in decoded)
          if (e is Map<String, dynamic>) ConnectionRecord.fromJson(e),
      ];
    } on FormatException {
      return const [];
    }
  }

  @override
  Future<void> save(List<ConnectionRecord> connections) async {
    await _prefs.setString(
        _key, jsonEncode([for (final c in connections) c.toJson()]));
  }
}

/// Token storage seam, keyed by connection id.
abstract class TokenStore {
  Future<String?> read(String connectionId);
  Future<void> write(String connectionId, String token);
  Future<void> delete(String connectionId);
}

class SecureTokenStore implements TokenStore {
  const SecureTokenStore();

  static String _key(String connectionId) => 'gw-token.$connectionId';

  @override
  Future<String?> read(String connectionId) =>
      const FlutterSecureStorage().read(key: _key(connectionId));

  @override
  Future<void> write(String connectionId, String token) =>
      const FlutterSecureStorage().write(key: _key(connectionId), value: token);

  @override
  Future<void> delete(String connectionId) =>
      const FlutterSecureStorage().delete(key: _key(connectionId));
}
