// Connection settings, ported from web/src/components/settings/ConnectionPage.svelte:
// the /api/system rows (gateway version and uptime, omp version, live
// sessions, idle reap, config file), 'Signed in with' from /api/me, the
// active gateway URL, and sign out behind a confirm dialog. Tolerant JSON
// accessors at the boundary; loading shows a small progress indicator.

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/errors.dart';
import '../../state/connection_notifier.dart';
import '../../theme/tokens.dart';
import 'settings_widgets.dart';

/// Typed view over the /api/system payload.
class SystemInfo {
  const SystemInfo({
    this.gatewayVersion,
    this.uptimeSec,
    this.maxSessions,
    this.idleReapSec,
    this.ompVersion,
    this.configFile,
    this.liveSessions,
  });

  factory SystemInfo.fromJson(Object? json) {
    final m = json is Map<String, dynamic> ? json : const <String, dynamic>{};
    final gw = m['gateway'] is Map<String, dynamic>
        ? m['gateway'] as Map<String, dynamic>
        : const <String, dynamic>{};
    final omp = m['omp'] is Map<String, dynamic>
        ? m['omp'] as Map<String, dynamic>
        : const <String, dynamic>{};
    String? s(Map<Object?, Object?> map, String k) {
      final v = map[k];
      return v is String && v.isNotEmpty ? v : null;
    }
    int? i(Map<Object?, Object?> map, String k) {
      final v = map[k];
      return v is num ? v.toInt() : null;
    }
    return SystemInfo(
      gatewayVersion: s(gw, 'version'),
      uptimeSec: i(gw, 'uptimeSec'),
      maxSessions: i(gw, 'maxSessions'),
      idleReapSec: i(gw, 'idleReapSec'),
      ompVersion: s(omp, 'version'),
      configFile: s(omp, 'configFile'),
      liveSessions: i(m, 'liveSessions'),
    );
  }

  final String? gatewayVersion;
  final int? uptimeSec;
  final int? maxSessions;
  final int? idleReapSec;
  final String? ompVersion;
  final String? configFile;
  final int? liveSessions;

  bool get isEmpty => gatewayVersion == null && ompVersion == null && liveSessions == null;
}

/// '3d 4h' style uptime, ported from web/src/lib/format.ts uptime().
String formatUptime(int seconds) {
  final d = seconds ~/ 86400;
  final h = (seconds % 86400) ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  if (d > 0) return '$d d $h h';
  if (h > 0) return '$h h $m m';
  return '$m m';
}

class ConnectionPage extends ConsumerStatefulWidget {
  const ConnectionPage({super.key});

  @override
  ConsumerState<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends ConsumerState<ConnectionPage> {
  SystemInfo? _system;
  String? _signedInWith;
  String? _error;
  bool _loading = true;
  bool _signingOut = false;

  /// Bumps on every load: a response from a previous load or connection
  /// must never overwrite a newer one (review triage #13).
  int _loadGen = 0;

  @override
  void initState() {
    super.initState();
    _load();
    // The connection notifier may still be settling when the page opens;
    // reload once the active connection appears.
    ref.listenManual(connectionNotifierProvider, (prev, next) {
      if (_system != null || _error != null || _loading) return;
      if (prev?.active == null && next.active != null) _load();
    });
  }

  Future<void> _load() async {
    final gen = ++_loadGen;
    setState(() {
      _loading = true;
      _error = null;
    });
    final connection = ref.read(connectionNotifierProvider);
    final active = connection.active;
    if (active == null) {
      if (!mounted || gen != _loadGen) return;
      setState(() => _loading = false);
      return;
    }
    final token = await ref.read(tokenStoreProvider).read(active.id);
    if (!mounted || gen != _loadGen) return;
    final client = ref
        .read(gatewayClientFactoryProvider)
        (active.url, token ?? '');
    try {
      final results = await Future.wait([
        client.system(),
        client.me().catchError((Object _) => ''),
      ]);
      if (!mounted || gen != _loadGen) return;
      setState(() {
        _system = SystemInfo.fromJson(results[0]);
        final method = results[1] as String;
        _signedInWith = switch (method) {
          'bearer' => 'Access token',
          'cookie' => 'Browser cookie',
          _ => null,
        };
        _loading = false;
      });
    } on GatewayClientError catch (e) {
      if (!mounted || gen != _loadGen) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || gen != _loadGen) return;
      setState(() {
        _error = 'Could not reach the gateway.';
        _loading = false;
      });
    }
  }

  Future<void> _signOut() async {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: tokens.canvas,
        title: Text('Sign out', style: TextStyle(color: tokens.ink)),
        content: Text(
          'Live sessions keep running on the gateway.',
          style: TextStyle(color: tokens.ink2),
        ),
        actions: [
          TextButton(
            key: const ValueKey('connection-signout-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel', style: TextStyle(color: tokens.ink2)),
          ),
          TextButton(
            key: const ValueKey('connection-signout-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Sign out', style: TextStyle(color: tokens.err)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _signingOut = true);
    await ref.read(connectionNotifierProvider.notifier).signOut();
    if (!mounted) return;
    setState(() => _signingOut = false);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final connection = ref.watch(connectionNotifierProvider);
    final active = connection.active;
    final system = _system;

    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(
        title: const Text('Connection'),
        backgroundColor: tokens.bg,
        foregroundColor: tokens.ink,
        elevation: 0,
      ),
      body: SettingsPageBody(
        children: [
          SettingsSection(
            title: 'Gateway and omp',
            hint: 'The host this app talks to.',
            child: SettingsLoadState(
              ready: !_loading && _error == null,
              error: _error,
              onRetry: _load,
              child: system == null || system.isEmpty
                  ? Text(
                      'The gateway did not report any host information.',
                      style: TextStyle(color: tokens.ink3, fontSize: OmpMetrics.fsSm),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (active != null)
                          SettingsRow(label: 'Gateway URL', value: active.url, mono: true),
                        if (system.gatewayVersion != null)
                          SettingsRow(label: 'Gateway', value: system.gatewayVersion!, mono: true),
                        if (system.uptimeSec != null)
                          SettingsRow(
                              label: 'Gateway uptime',
                              value: formatUptime(system.uptimeSec!)),
                        if (system.ompVersion != null)
                          SettingsRow(label: 'omp', value: system.ompVersion!, mono: true),
                        if (system.liveSessions != null && system.maxSessions != null)
                          SettingsRow(
                            label: 'Live sessions',
                            value: '${system.liveSessions} of ${system.maxSessions}',
                          ),
                        if (system.idleReapSec != null)
                          SettingsRow(
                            label: 'Idle sessions stop after',
                            value: formatUptime(system.idleReapSec!),
                          ),
                        if (_signedInWith != null)
                          SettingsRow(label: 'Signed in with', value: _signedInWith!),
                        if (system.configFile != null)
                          SettingsRow(label: 'Config file', value: system.configFile!, mono: true),
                      ],
                    ),
            ),
          ),
          SettingsSection(
            title: 'Sign out',
            hint: 'Clears the saved connection on this device. Sessions on the gateway are not stopped.',
            child: OutlinedButton(
              key: const ValueKey('connection-signout'),
              onPressed:
                  (_signingOut || !connection.signedIn) ? null : _signOut,
              child: const Text('Sign out'),
            ),
          ),
        ],
      ),
    );
  }
}
