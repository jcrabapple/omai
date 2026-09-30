// Appearance settings, ported from web/src/components/settings/AppearancePage.svelte:
// theme cards (terminal, graphite, paper, contrast) with token-coloured
// previews and a selected state, the follow-system switch, the accent
// swatches (theme default plus the eight accents from accents.ts) with a
// low-contrast warning, density and text size segmented controls, and reset.
// Everything applies live through the appearance store.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/appearance_store.dart';
import '../../theme/presets.dart';
import '../../theme/tokens.dart';
import 'settings_widgets.dart';

const _presetCards = <(OmpPreset, String, String)>[
  (OmpPreset.terminal, 'Terminal', 'Dark, green'),
  (OmpPreset.graphite, 'Graphite', 'Dark, blue'),
  (OmpPreset.paper, 'Paper', 'Light'),
  (OmpPreset.contrast, 'Contrast', 'Dark, high contrast'),
];

/// WCAG contrast ratio between two colors (1..21).
double contrastRatio(Color a, Color b) {
  double lum(Color c) {
    final l = c.computeLuminance();
    return l;
  }

  final lighter = lum(a) > lum(b) ? lum(a) : lum(b);
  final darker = lum(a) > lum(b) ? lum(b) : lum(a);
  return (lighter + 0.05) / (darker + 0.05);
}

class AppearancePage extends ConsumerWidget {
  const AppearancePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(appearanceProvider);
    final store = ref.read(appearanceProvider.notifier);
    final tokens = Theme.of(context).extension<OmpTokens>()!;

    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(
        title: const Text('Appearance'),
        backgroundColor: tokens.bg,
        foregroundColor: tokens.ink,
        elevation: 0,
      ),
      body: SettingsPageBody(
        children: [
          SettingsSection(
            title: 'Theme',
            hint: 'Paper follows the light side when follow system is on.',
            child: Column(
              children: [
                for (final (preset, name, desc) in _presetCards)
                  _PresetCard(
                    preset: preset,
                    name: name,
                    description: desc,
                    selected: appearance.preset == preset,
                    onTap: () => store.setPreset(preset),
                  ),
              ],
            ),
          ),
          SettingsSection(
            title: 'Follow system',
            hint:
                'Use paper when the device is light, the dark theme otherwise.',
            child: SwitchListTile(
              key: const ValueKey('appearance-follow-system'),
              value: appearance.followSystem,
              onChanged: (v) => store.setFollowSystem(v),
              title: Text(
                'Follow system light or dark',
                style: TextStyle(
                  color: tokens.ink,
                  fontSize: OmpMetrics.fsBase,
                ),
              ),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          SettingsSection(
            title: 'Accent',
            hint: 'The theme default keeps each preset its own color.',
            child: _AccentSwatches(
              selectedHex: appearance.accentHex,
              presetBg: OmpTheme.tokens(
                appearance.effectivePreset(
                  MediaQuery.platformBrightnessOf(context),
                ),
              ).bg,
              onSelect: store.setAccent,
            ),
          ),
          SettingsSection(
            title: 'Density',
            child: _Segmented<AppearanceDensity>(
              key: const ValueKey('appearance-density'),
              value: appearance.density,
              labels: const {
                AppearanceDensity.comfortable: 'Comfortable',
                AppearanceDensity.compact: 'Compact',
              },
              onChanged: store.setDensity,
            ),
          ),
          SettingsSection(
            title: 'Text size',
            hint: 'Multiplies the system font size.',
            child: _TextScaleSegmented(
              value: appearance.textScale,
              onChanged: store.setTextScale,
            ),
          ),
          SettingsSection(
            title: 'Reset',
            child: OutlinedButton(
              key: const ValueKey('appearance-reset'),
              onPressed: () => store.reset(),
              child: const Text('Reset appearance'),
            ),
          ),
        ],
      ),
    );
  }
}

class _PresetCard extends StatelessWidget {
  const _PresetCard({
    required this.preset,
    required this.name,
    required this.description,
    required this.selected,
    required this.onTap,
  });

  final OmpPreset preset;
  final String name;
  final String description;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final preview = OmpTheme.tokens(preset);
    return Semantics(
      checked: selected,
      inMutuallyExclusiveGroup: true,
      button: true,
      child: Padding(
        padding: const EdgeInsets.only(bottom: OmpMetrics.s2),
        child: InkWell(
          key: ValueKey('appearance-preset-${preset.name}'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(OmpMetrics.radiusMd),
          child: Container(
            constraints: const BoxConstraints(minHeight: OmpMetrics.hit),
            padding: const EdgeInsets.all(OmpMetrics.s3),
            decoration: BoxDecoration(
              color: tokens.inset,
              borderRadius: BorderRadius.circular(OmpMetrics.radiusMd),
              border: Border.all(
                color: selected ? preview.accent : tokens.line,
                width: selected ? 2 : 1,
              ),
            ),
            child: Row(
              children: [
                // Token-coloured preview: bg, canvas, ink, accent.
                Container(
                  width: 48,
                  height: 32,
                  decoration: BoxDecoration(
                    color: preview.bg,
                    borderRadius: BorderRadius.circular(OmpMetrics.radiusSm),
                    border: Border.all(color: tokens.line),
                  ),
                  padding: const EdgeInsets.all(4),
                  child: Row(
                    children: [
                      Expanded(
                        child: ColoredBox(
                          color: preview.canvas,
                          child: const SizedBox.expand(),
                        ),
                      ),
                      const SizedBox(width: 2),
                      Expanded(
                        child: ColoredBox(
                          color: preview.accent,
                          child: const SizedBox.expand(),
                        ),
                      ),
                      const SizedBox(width: 2),
                      Expanded(
                        child: ColoredBox(
                          color: preview.ink,
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: OmpMetrics.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: TextStyle(
                          color: tokens.ink,
                          fontSize: OmpMetrics.fsBase,
                        ),
                      ),
                      Text(
                        description,
                        style: TextStyle(
                          color: tokens.ink3,
                          fontSize: OmpMetrics.fsSm,
                        ),
                      ),
                    ],
                  ),
                ),
                if (selected)
                  Icon(
                    Icons.check,
                    color: preview.accent,
                    size: 20,
                    semanticLabel: '$name selected',
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AccentSwatches extends StatelessWidget {
  const _AccentSwatches({
    required this.selectedHex,
    required this.presetBg,
    required this.onSelect,
  });

  final String? selectedHex;
  final Color presetBg;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;

    Widget swatch({
      String? key,
      required VoidCallback onTap,
      required Color color,
      required String label,
      required bool selected,
    }) {
      final lowContrast = contrastRatio(color, presetBg) < 3.0;
      return Semantics(
        checked: selected,
        inMutuallyExclusiveGroup: true,
        button: true,
        label:
            '$label accent${lowContrast ? ', low contrast on this theme' : ''}',
        child: InkWell(
          key: ValueKey('appearance-accent-${key ?? 'default'}'),
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: OmpMetrics.hit,
            height: OmpMetrics.hit,
            child: Center(
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? tokens.ink : tokens.line,
                    width: selected ? 2 : 1,
                  ),
                ),
                child: selected
                    ? Icon(
                        Icons.check,
                        size: 18,
                        color: color.computeLuminance() > 0.4
                            ? Colors.black
                            : Colors.white,
                      )
                    : null,
              ),
            ),
          ),
        ),
      );
    }

    final themeDefault = swatch(
      key: null,
      color: tokens.accent,
      label: 'Theme default',
      selected: selectedHex == null,
      onTap: () => onSelect(null),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: OmpMetrics.s2,
          runSpacing: OmpMetrics.s2,
          children: [
            themeDefault,
            for (final a in AccentChoice.all)
              Builder(
                builder: (context) {
                  final c = Color(
                    int.parse('FF${a.hex.substring(1)}', radix: 16),
                  );
                  return swatch(
                    key: a.id,
                    color: c,
                    label: a.label,
                    selected: selectedHex == a.hex,
                    onTap: () => onSelect(a.hex),
                  );
                },
              ),
          ],
        ),
        for (final a in AccentChoice.all)
          if (selectedHex == a.hex &&
              contrastRatio(
                    Color(int.parse('FF${a.hex.substring(1)}', radix: 16)),
                    presetBg,
                  ) <
                  3.0)
            Padding(
              key: const ValueKey('appearance-accent-low-contrast'),
              padding: const EdgeInsets.only(top: OmpMetrics.s2),
              child: Text(
                'This accent is hard to read on the current theme.',
                style: TextStyle(color: tokens.warn, fontSize: OmpMetrics.fsSm),
              ),
            ),
      ],
    );
  }
}

/// A full-width segmented picker. Flutter's SegmentedButton sizes itself to
/// its labels and ignores the available width, so "Small/Default/Large/
/// Larger" ran off a 384dp phone. Here every segment gets an equal share of
/// the width and a label that shrinks to fit rather than overflowing.
class _Segmented<T> extends StatelessWidget {
  const _Segmented({
    super.key,
    required this.value,
    required this.labels,
    required this.onChanged,
  });

  final T value;
  final Map<T, String> labels;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final radius = BorderRadius.circular(OmpMetrics.radiusMd);
    final entries = labels.entries.toList();
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: tokens.lineStrong),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < entries.length; i++) ...[
                if (i > 0)
                  VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: tokens.lineStrong,
                  ),
                Expanded(
                  child: _Segment(
                    label: entries[i].value,
                    selected: entries[i].key == value,
                    onTap: () => onChanged(entries[i].key),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: label,
      excludeSemantics: true,
      // The InkWell's own action is excluded with its node; expose tap here.
      onTap: onTap,
      child: Material(
        color: selected
            ? tokens.accent.withValues(alpha: 0.18)
            : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: OmpMetrics.hit),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: OmpMetrics.s2,
                vertical: OmpMetrics.s2,
              ),
              child: Center(
                // Shrink the label rather than overflow at huge text sizes.
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    maxLines: 1,
                    style: TextStyle(
                      color: selected ? tokens.ink : tokens.ink3,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TextScaleSegmented extends StatelessWidget {
  const _TextScaleSegmented({required this.value, required this.onChanged});

  final double value;
  final ValueChanged<double> onChanged;

  static final _labels = <double, String>{
    0.9: 'Small',
    1.0: 'Default',
    1.15: 'Large',
    1.3: 'Larger',
  };

  @override
  Widget build(BuildContext context) {
    return _Segmented<double>(
      key: const ValueKey('appearance-text-size'),
      value: appearanceTextScales.contains(value) ? value : 1.0,
      labels: _labels,
      onChanged: onChanged,
    );
  }
}
