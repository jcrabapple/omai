// The model catalog from `omp models --json`, ported from
// web/src/lib/state/models.svelte.ts. The first fetch can take about a
// minute, so the list the picker shows is stale-first: an error keeps the
// last copy on screen and lands in `error`; a refresh reports itself through
// `refreshing`. Rebuilt (and refetched) when the active connection changes.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/errors.dart';
import '../api/models.dart';
import 'connection_notifier.dart';

class ModelsState {
  const ModelsState({
    this.models = const [],
    this.ready = false,
    this.refreshing = false,
    this.error,
  });

  final List<CatalogModel> models;

  /// True once any list is on screen, so the picker can stop showing
  /// skeletons.
  final bool ready;

  /// True while a fetch is in flight, including over an already-loaded list.
  final bool refreshing;

  /// Last failure. Null once a fetch succeeds. Never clears the list.
  final String? error;

  ModelsState copyWith({
    List<CatalogModel>? models,
    bool? ready,
    bool? refreshing,
    String? error,
    bool clearError = false,
  }) {
    return ModelsState(
      models: models ?? this.models,
      ready: ready ?? this.ready,
      refreshing: refreshing ?? this.refreshing,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// True when [m] matches every whitespace-separated word of [query] across
/// provider, id and name.
bool matchesModel(CatalogModel m, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  final haystack = '${m.provider} ${m.id} ${m.name}'.toLowerCase();
  return q.split(RegExp(r'\s+')).every(haystack.contains);
}

class ModelGroup {
  const ModelGroup({required this.provider, required this.models});
  final String provider;
  final List<CatalogModel> models;
}

/// Filtered, then grouped by provider (alphabetical); models within a group
/// sort by display name. Ported from groupModels().
List<ModelGroup> groupModels(List<CatalogModel> models, [String query = '']) {
  final by = <String, List<CatalogModel>>{};
  for (final m in models) {
    if (!matchesModel(m, query)) continue;
    (by[m.provider] ??= []).add(m);
  }
  final providers = by.keys.toList()..sort();
  return [
    for (final p in providers)
      ModelGroup(
        provider: p,
        models: by[p]!..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase())),
      ),
  ];
}

class ModelsStore extends Notifier<ModelsState> {
  int _generation = 0;
  String? _connId;

  /// The in-flight fetch, if any. A refresh requested while one runs joins
  /// it instead of racing a second request whose result the generation
  /// guard would then discard.
  Future<void>? _inFlight;

  @override
  ModelsState build() {
    final id =
        ref.watch(connectionNotifierProvider.select((s) => s.active?.id ?? ''));
    if (id != _connId) {
      _connId = id;
      _generation++;
      _inFlight = null;
      Future<void>.microtask(() => refresh());
      return const ModelsState();
    }
    return state;
  }

  /// Load the catalog. Safe to call every time a picker opens: while a fetch
  /// is already in flight it returns that fetch's future.
  Future<void> refresh() {
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;
    final future = _load();
    _inFlight = future.whenComplete(() => _inFlight = null);
    return _inFlight!;
  }

  Future<void> _load() async {
    final connection = ref.read(connectionNotifierProvider);
    final active = connection.active;
    if (active == null || !ref.mounted) return;
    final token = await ref.read(tokenStoreProvider).read(active.id);
    if (!ref.mounted || token == null || token.isEmpty) return;
    final client = ref.read(gatewayClientFactoryProvider)(active.url, token);

    final gen = ++_generation;
    state = state.copyWith(refreshing: true, clearError: true);
    try {
      final catalog = await client.catalogModels();
      if (gen != _generation || !ref.mounted) return;
      state = state.copyWith(
        models: catalog.models,
        ready: true,
        refreshing: false,
      );
    } on GatewayClientError catch (e) {
      if (gen != _generation || !ref.mounted) return;
      state = state.copyWith(refreshing: false, error: e.message);
    } catch (_) {
      if (gen != _generation || !ref.mounted) return;
      state = state.copyWith(refreshing: false, error: 'Could not load models');
    }
  }

  /// Retry after a failure. Same as [refresh]; named for the picker button.
  void retry() {
    unawaited(refresh());
  }

  CatalogModel? find(String? provider, String? id) =>
      state.models
          .where((m) => m.provider == provider && m.id == id)
          .firstOrNull;
}

final modelsStoreProvider =
    NotifierProvider<ModelsStore, ModelsState>(ModelsStore.new);
