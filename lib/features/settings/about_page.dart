// About settings page: the app name, the version read from Android's
// PackageManager at runtime (getAppVersion on us.snakepit.omai/native; no
// package_info_plus), the build mode, the active gateway URL and Flutter's
// built-in license page. A failed or junk version shows 'Unknown' rather
// than erroring.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../native/method_channel_bridge.dart';
import '../../state/connection_notifier.dart';
import '../../theme/tokens.dart';
import 'settings_widgets.dart';

/// 'Debug', 'Profile' or 'Release' from the compile-time constants.
String buildModeLabel() {
  if (kReleaseMode) return 'Release';
  if (kProfileMode) return 'Profile';
  return 'Debug';
}

class AboutPage extends ConsumerStatefulWidget {
  const AboutPage({super.key});

  @override
  ConsumerState<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends ConsumerState<AboutPage> {
  ({String versionName, int versionCode})? _version;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final v = await fetchAppVersion();
    if (!mounted) return;
    setState(() => _version = v);
  }

  String get _versionText {
    final v = _version;
    return v == null ? 'Unknown' : '${v.versionName} (${v.versionCode})';
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final gatewayUrl = ref.watch(connectionNotifierProvider).active?.url;
    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(
        title: const Text('About'),
        backgroundColor: tokens.bg,
        foregroundColor: tokens.ink,
        elevation: 0,
      ),
      body: SettingsPageBody(
        children: [
          SettingsSection(
            title: 'Omai',
            hint: 'Android client for the ohmypi gateway.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SettingsRow(label: 'Version', value: _versionText),
                SettingsRow(label: 'Build mode', value: buildModeLabel()),
                SettingsRow(
                  label: 'Gateway',
                  value: gatewayUrl ?? 'Not connected',
                ),
              ],
            ),
          ),
          SettingsSection(
            title: 'Legal',
            child: ListTile(
              key: const ValueKey('about-licenses'),
              contentPadding: EdgeInsets.zero,
              minLeadingWidth: 0,
              title: Text(
                'Open source licenses',
                style: TextStyle(
                  color: tokens.ink,
                  fontSize: OmpMetrics.fsBase,
                ),
              ),
              trailing: Icon(Icons.chevron_right, color: tokens.ink3),
              onTap: () => showLicensePage(
                context: context,
                applicationName: 'Omai',
                applicationVersion: _versionText,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
