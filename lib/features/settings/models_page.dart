// Models settings page, ported from web/src/components/settings/ModelsPage.svelte
// minus the session-switching button (read-only in v1): the catalog grouped
// by provider, a search field across name / provider / id, each row showing
// name, context window and the reasoning flag. Loading and grouping reuse
// lib/state/models_store.dart unchanged.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../state/models_store.dart';
import '../../theme/tokens.dart';
import 'settings_widgets.dart';

class ModelsPage extends ConsumerStatefulWidget {
  const ModelsPage({super.key});

  @override
  ConsumerState<ModelsPage> createState() => _ModelsPageState();
}

class _ModelsPageState extends ConsumerState<ModelsPage> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final models = ref.watch(modelsStoreProvider);
    final groups = groupModels(models.models, _query);
    final count = groups.fold<int>(0, (n, g) => n + g.models.length);

    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(
        title: const Text('Models'),
        backgroundColor: tokens.bg,
        foregroundColor: tokens.ink,
        elevation: 0,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              OmpMetrics.s4,
              OmpMetrics.s4,
              OmpMetrics.s4,
              OmpMetrics.s2,
            ),
            child: TextField(
              key: const ValueKey('models-search'),
              decoration: const InputDecoration(
                hintText: 'Search by name, provider or id',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(
            child: SettingsLoadState(
              ready: models.ready,
              error: models.error,
              onRetry: () =>
                  ref.read(modelsStoreProvider.notifier).retry(),
              child: groups.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(OmpMetrics.s4),
                      child: Text(
                        _query.trim().isEmpty
                            ? 'The catalog has no models.'
                            : 'No models match "${_query.trim()}"',
                        style:
                            TextStyle(color: tokens.ink3, fontSize: OmpMetrics.fsSm),
                      ),
                    )
                  : ListView(
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: OmpMetrics.s4,
                          ),
                          child: Text(
                            '$count ${count == 1 ? 'model' : 'models'}',
                            style: TextStyle(
                              color: tokens.ink3,
                              fontSize: OmpMetrics.fsXs,
                            ),
                          ),
                        ),
                        for (final g in groups) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(
                              OmpMetrics.s4,
                              OmpMetrics.s4,
                              OmpMetrics.s4,
                              OmpMetrics.s1,
                            ),
                            child: Text(
                              g.provider.toUpperCase(),
                              style: TextStyle(
                                color: tokens.ink3,
                                fontSize: OmpMetrics.fsXs,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                          for (final m in g.models)
                            _ModelRow(model: m),
                        ],
                        const SizedBox(height: OmpMetrics.s6),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({required this.model});

  final CatalogModel model;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final contextLabel = _compactNumber(model.contextWindow);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: OmpMetrics.s4,
        vertical: OmpMetrics.s1,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  model.name,
                  style: TextStyle(color: tokens.ink, fontSize: OmpMetrics.fsBase),
                ),
                Text(
                  '$contextLabel context'
                  '${model.reasoning ? ' · reasoning' : ''}',
                  style: TextStyle(color: tokens.ink3, fontSize: OmpMetrics.fsSm),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// compactNumber from web/src/lib/format.ts: 128k, 1m.
  static String _compactNumber(int n) {
    if (n >= 1000000) {
      final v = n / 1000000;
      return v == v.roundToDouble() ? '${v.toInt()}m' : '${v.toStringAsFixed(1)}m';
    }
    if (n >= 1000) {
      final v = n / 1000;
      return v == v.roundToDouble() ? '${v.toInt()}k' : '${v.toStringAsFixed(1)}k';
    }
    return '$n';
  }
}
