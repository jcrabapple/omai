// App shell: signed-out shows Connect, signed-in shows the placeholder home.
// Follow-system light/dark maps to paper vs the chosen dark preset.
//
// Task F: also the landing point for everything Android-native sends up:
// share intents, launcher shortcuts, and notification taps, all over the
// one MethodChannel (see lib/native/).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/connect/connect_screen.dart';
import '../features/new_session/new_session_sheet.dart';
import '../features/session/session_screen.dart';
import '../features/sessions/sessions_screen.dart';
import '../native/keepalive.dart';
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

/// The sessions screen subscribes to this so polling runs only while it is
/// the top route.
final ompRouteObserver = RouteObserver<PageRoute<Object?>>();

final _rootNavigatorKey = GlobalKey<NavigatorState>();

class OmpApp extends ConsumerStatefulWidget {
  const OmpApp({super.key});

  @override
  ConsumerState<OmpApp> createState() => _OmpAppState();
}

class _OmpAppState extends ConsumerState<OmpApp> {
  static const _channel = MethodChannel('us.snakepit.ohmypi/native');

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler(_onNativeCall);
    // Cold start: Android launched us with a share intent or a shortcut.
    _fetchInitialIntent();
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    super.dispose();
  }

  Future<void> _fetchInitialIntent() async {
    try {
      final initial = await _channel.invokeMethod('getInitialIntent');
      if (initial is Map) {
        // Let the first frame land before pushing routes on top of it.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _handleIntent(Map<String, Object?>.from(initial));
        });
      }
    } on PlatformException {
      // No native side (tests) or nothing pending.
    }
  }

  Future<Object?> _onNativeCall(MethodCall call) async {
    final args = call.arguments;
    if (args is Map) _handleIntent(Map<String, Object?>.from(args));
    return null;
  }

  /// Routes from the native side. Notification Stop / approval actions go to
  /// the session's keepalive coordinator via [KeepaliveRegistry]; the rest
  /// are navigation.
  void _handleIntent(Map<String, Object?> args) {
    final type = args['type'];
    final gwId = args['gwId'];
    switch (type) {
      case 'stopTurn':
        if (gwId is String) {
          KeepaliveRegistry.forGwId(gwId)?.stopPressed();
        }
      case 'approvalAction':
        if (gwId is String) {
          final requestId = args['requestId'];
          final action = args['action'];
          if (requestId is String && action is String) {
            KeepaliveRegistry.forGwId(gwId)?.approvalPressed(requestId, action);
          }
        }
      case 'openSession':
        if (gwId is String) _openSession(gwId);
      case 'newSession':
        _newSession(args['prompt'] is String ? args['prompt'] as String : null);
      case 'needsYou':
        _popToRoot();
      default:
        break;
    }
  }

  bool get _signedIn => ref.read(connectionNotifierProvider).signedIn;

  void _popToRoot() {
    final nav = _rootNavigatorKey.currentState;
    if (nav == null) return;
    nav.popUntil((r) => r.isFirst);
  }

  void _openSession(String gwId) {
    if (!_signedIn) return;
    final nav = _rootNavigatorKey.currentState;
    if (nav == null) return;
    _popToRoot();
    nav.push(
        MaterialPageRoute<void>(builder: (_) => SessionScreen(gwId: gwId)));
  }

  Future<void> _newSession(String? prompt) async {
    if (!_signedIn) return;
    final nav = _rootNavigatorKey.currentState;
    final context = _rootNavigatorKey.currentContext;
    if (nav == null || context == null) return;
    _popToRoot();
    await showNewSessionSheet(
      context,
      ref,
      initialPrompt: (prompt ?? '').trim().isEmpty ? null : prompt,
      onCreated: (info) {
        nav.push(MaterialPageRoute<void>(
            builder: (_) => SessionScreen(gwId: info.gwId)));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final connection = ref.watch(connectionNotifierProvider);
    final darkPreset = ref.watch(darkPresetProvider);
    final accent = ref.watch(accentOverrideProvider);

    return MaterialApp(
      title: 'ohmypi',
      navigatorKey: _rootNavigatorKey,
      theme: OmpTheme.data(OmpPreset.paper, accent: accent),
      darkTheme: OmpTheme.data(darkPreset, accent: accent),
      themeMode: ThemeMode.system,
      navigatorObservers: [ompRouteObserver],
      home: connection.signedIn ? const SessionsScreen() : const ConnectScreen(),
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
