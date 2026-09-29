// Searchable model list grouped by provider, ported from
// web/src/components/ModelPicker.svelte. Pure widget: the catalog, the
// current selection and the pick callback all come in through the
// constructor, so tests need no gateway. [showModelPickerSheet] wires it to
// the models store as a modal bottom sheet.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../format.dart';
import '../state/models_store.dart';
import '../theme/tokens.dart';

/// Which model is in use, marked with a check. Null means no choice yet.
class CurrentModel {
  const CurrentModel({this.provider, this.id});
  final String? provider;
  final String? id;
}

class ModelPicker extends StatefulWidget {
  const ModelPicker({
    super.key,
    required this.models,
    required this.onPick,
    this.loading = false,
    this.refreshing = false,
    this.error,
    this.onRetry,
    this.current,
    this.defaultLabel,
  });

  final List<CatalogModel> models;

  /// Called with the picked model, or null when [defaultLabel] is set and the
  /// user chooses it (i.e. clears the choice).
  final ValueChanged<CatalogModel?> onPick;

  /// True while no list has arrived yet: skeletons.
  final bool loading;

  /// True while a refresh runs over an already-loaded list.
  final bool refreshing;

  /// Last load failure. Keeps any previously loaded [models] on screen.
  final String? error;
  final VoidCallback? onRetry;

  final CurrentModel? current;

  /// Show a first row that clears the choice.
  final String? defaultLabel;

  @override
  State<ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<ModelPicker> {
  String _query = '';

  bool _isCurrent(CatalogModel m) =>
      widget.current?.provider == m.provider && widget.current?.id == m.id;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final groups = groupModels(widget.models, _query);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              OmpMetrics.s4, OmpMetrics.s3, OmpMetrics.s4, OmpMetrics.s1),
          child: TextField(
            onChanged: (v) => setState(() => _query = v),
            decoration: InputDecoration(
              hintText: 'Search models',
              prefixIcon: const Icon(Icons.search, size: 20),
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(OmpMetrics.radiusMd),
              ),
            ),
          ),
        ),
        if (widget.error != null && widget.models.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: OmpMetrics.s4, vertical: OmpMetrics.s3),
            child: Column(
              children: [
                Text('Could not load models',
                    style: TextStyle(
                        color: tokens.ink, fontSize: OmpMetrics.fsBase)),
                if ((widget.error ?? '').isNotEmpty)
                  Text(widget.error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: tokens.ink3, fontSize: OmpMetrics.fsSm)),
                const SizedBox(height: OmpMetrics.s2),
                if (widget.onRetry != null)
                  TextButton(
                      onPressed: widget.onRetry, child: const Text('Try again')),
              ],
            ),
          )
        else if (widget.loading)
          Padding(
            padding: const EdgeInsets.all(OmpMetrics.s5),
            child: Column(
              children: [
                for (var i = 0; i < 5; i++)
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(vertical: OmpMetrics.s1),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: 0.7,
                        child: Container(height: 14, color: tokens.inset),
                      ),
                    ),
                  ),
                Semantics(
                  label: 'Fetching models',
                  liveRegion: true,
                  child: const SizedBox.shrink(),
                ),
              ],
            ),
          )
        else
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: OmpMetrics.s2),
              children: [
                if (widget.defaultLabel != null)
                  _PickerRow(
                    tokens: tokens,
                    label: widget.defaultLabel!,
                    facts: '',
                    selected: _isDefaultSelected(),
                    onTap: () => widget.onPick(null),
                  ),
                for (final g in groups) ...[
                  Padding(
                    padding: const EdgeInsets.only(
                        left: OmpMetrics.s3,
                        top: OmpMetrics.s3,
                        bottom: OmpMetrics.s1),
                    child: Semantics(
                      header: true,
                      child: Text(g.provider.toUpperCase(),
                          style: TextStyle(
                              color: tokens.ink3,
                              fontSize: OmpMetrics.fsXs,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.4)),
                    ),
                  ),
                  for (final m in g.models)
                    _PickerRow(
                      tokens: tokens,
                      label: m.name,
                      facts: '${compactNumber(m.contextWindow)} · '
                          '${priceLabel(m.cost.input, m.cost.output)}',
                      selected: _isCurrent(m),
                      onTap: () => widget.onPick(m),
                    ),
                ],
                if (groups.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(OmpMetrics.s4),
                    child: Text('No model matches "$_query"',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: tokens.ink3, fontSize: OmpMetrics.fsSm)),
                  ),
                if (widget.refreshing)
                  Padding(
                    padding: const EdgeInsets.all(OmpMetrics.s2),
                    child: Center(
                      child: SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: tokens.accent),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  bool _isDefaultSelected() =>
      widget.current?.provider == null && widget.current?.id == null;
}

class _PickerRow extends StatelessWidget {
  const _PickerRow({
    required this.tokens,
    required this.label,
    required this.facts,
    required this.selected,
    this.onTap,
  });

  final OmpTokens tokens;
  final String label;
  final String facts;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label. $facts',
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: OmpMetrics.s4, vertical: OmpMetrics.s2),
            child: Row(
              children: [
                Expanded(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: tokens.ink, fontSize: OmpMetrics.fsBase)),
                ),
                const SizedBox(width: OmpMetrics.s2),
                Text(facts,
                    style: TextStyle(
                        color: tokens.ink3, fontSize: OmpMetrics.fsXs)),
                SizedBox(
                  width: 28,
                  child: selected
                      ? Icon(Icons.check, size: 16, color: tokens.accent)
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens the picker as a modal bottom sheet wired to the models store.
/// [current] marks the model in use; [onPick] receives the choice (null when
/// the user picks [defaultLabel]).
Future<void> showModelPickerSheet(
  BuildContext context,
  WidgetRef ref, {
  CurrentModel? current,
  String? defaultLabel,
  required ValueChanged<CatalogModel?> onPick,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => Padding(
      // The search field summons the keyboard; isScrollControlled disables
      // the automatic inset handling, so pad by viewInsets or the keyboard
      // covers the list.
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
      child: Consumer(builder: (context, ref, _) {
      final store = ref.read(modelsStoreProvider.notifier);
      final models = ref.watch(modelsStoreProvider);
      return SafeArea(
        child: ConstrainedBox(
          // Cap by the space actually available above the keyboard, not by
          // the raw 70% of the screen (keyboard insets would push the sheet
          // off-screen otherwise).
          constraints: BoxConstraints(
              maxHeight: math.max(
                  0,
                  MediaQuery.of(sheetContext).size.height * 0.7 -
                      MediaQuery.of(sheetContext).viewInsets.bottom)),
          child: ModelPicker(
            models: models.models,
            loading: !models.ready && models.error == null,
            refreshing: models.refreshing,
            error: models.error,
            onRetry: store.retry,
            current: current,
            defaultLabel: defaultLabel,
            onPick: (m) {
              Navigator.of(sheetContext).pop();
              onPick(m);
            },
          ),
        ),
      );
    }),
    ),
  );
}
