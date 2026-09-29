// App shell: signed-out shows Connect, signed-in shows the placeholder home.
// Follow-system light/dark maps to paper vs the chosen dark preset.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/connect/connect_screen.dart';
import '../features/home/home_screen.dart';
import '../state/connection_notifier.dart';
import '../theme/presets.dart';
import '../theme/tokens.dart';

/// The dark preset used when the system is in dark mode. Settings will own
/// this later; terminal is the default today.
class DarkPresetNotifier extends Notifier<OmpPreset> {
  @override
  OmpPreset build() => OmpPreset.terminal;
  void set(OmpPreset p) => state = p;
}

final darkPresetProvider =
    NotifierProvider<DarkPresetNotifier, OmpPreset>(DarkPresetNotifier.new);

/// Custom accent override from settings; null keeps the preset accent.
class AccentOverrideNotifier extends Notifier<Color?> {
  @override
  Color? build() => null;
  void set(Color? c) => state = c;
}

final accentOverrideProvider =
    NotifierProvider<AccentOverrideNotifier, Color?>(AccentOverrideNotifier.new);

class OmpApp extends ConsumerWidget {
  const OmpApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(connectionNotifierProvider);
    final darkPreset = ref.watch(darkPresetProvider);
    final accent = ref.watch(accentOverrideProvider);

    return MaterialApp(
      title: 'ohmypi',
      theme: OmpTheme.data(OmpPreset.paper, accent: accent),
      darkTheme: OmpTheme.data(darkPreset, accent: accent),
      themeMode: ThemeMode.system,
      home: connection.signedIn ? const HomeScreen() : const ConnectScreen(),
    );
  }
}

/// Shared page scaffold so feature screens stay consistent.
class OmpPage extends StatelessWidget {
  const OmpPage({
    super.key,
    required this.title,
    this.actions,
    required this.child,
  });

  final String title;
  final List<Widget>? actions;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(
        title: Text(title),
        backgroundColor: tokens.bg,
        foregroundColor: tokens.ink,
        elevation: 0,
        actions: actions,
      ),
      body: child,
    );
  }
}
