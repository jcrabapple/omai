// The Settings screen shell, ported from web/src/components/SettingsOverlay.svelte
// (phone layout: the list of pages, then one page). Each page lives in its own
// file under lib/features/settings/. Entry point for the orchestrator's
// Sessions screen button:
//   Navigator.push(... SettingsScreen())
// or straight to one page with SettingsScreen(initial: SettingsPage.appearance).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/tokens.dart';
import 'appearance_page.dart';
import 'connection_page.dart';
import 'diagnostics_page.dart';
import 'models_page.dart';
import 'skills_page.dart';
import 'usage_page.dart';

/// The pages Settings offers, in display order.
enum SettingsPage { appearance, connection, diagnostics, models, skills, usage }

class _PageSpec {
  const _PageSpec(this.page, this.title, this.hint, this.icon);
  final SettingsPage page;
  final String title;
  final String hint;
  final IconData icon;
}

const _pages = <_PageSpec>[
  _PageSpec(SettingsPage.appearance, 'Appearance',
      'Theme, accent, density and text size', Icons.palette_outlined),
  _PageSpec(SettingsPage.connection, 'Connection',
      'Gateway, sign-in status and sign out', Icons.lan_outlined),
  _PageSpec(SettingsPage.diagnostics, 'Diagnostics',
      'Checks that the gateway path works end to end', Icons.healing_outlined),
  _PageSpec(SettingsPage.models, 'Models',
      'The model catalog from the gateway', Icons.memory_outlined),
  _PageSpec(SettingsPage.skills, 'Skills',
      'Skills installed on the gateway host', Icons.build_outlined),
  _PageSpec(SettingsPage.usage, 'Usage',
      'Provider usage report', Icons.query_stats_outlined),
];

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, this.initial});

  /// Opens straight to this page instead of the list.
  final SettingsPage? initial;

  void _open(BuildContext context, SettingsPage page) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => _pageWidget(page)),
    );
  }

  static Widget _pageWidget(SettingsPage page) => switch (page) {
    SettingsPage.appearance => const AppearancePage(),
    SettingsPage.connection => const ConnectionPage(),
    SettingsPage.diagnostics => const DiagnosticsPage(),
    SettingsPage.models => const ModelsPage(),
    SettingsPage.skills => const SkillsPage(),
    SettingsPage.usage => const UsagePage(),
  };

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final initialPage = initial;
    if (initialPage != null) return _pageWidget(initialPage);
    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: tokens.bg,
        foregroundColor: tokens.ink,
        elevation: 0,
      ),
      body: Consumer(
        builder: (context, ref, _) {
          return ListView(
            children: [
              for (final spec in _pages)
                ListTile(
                  key: ValueKey('settings-page-${spec.page.name}'),
                  leading: Icon(spec.icon, color: tokens.ink2),
                  title: Text(
                    spec.title,
                    style: TextStyle(color: tokens.ink, fontSize: OmpMetrics.fsLg),
                  ),
                  subtitle: Text(
                    spec.hint,
                    style: TextStyle(color: tokens.ink3, fontSize: OmpMetrics.fsSm),
                  ),
                  trailing: Icon(Icons.chevron_right, color: tokens.ink3),
                  minLeadingWidth: 0,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: OmpMetrics.s4,
                    vertical: OmpMetrics.s1,
                  ),
                  onTap: () => _open(context, spec.page),
                ),
            ],
          );
        },
      ),
    );
  }
}
