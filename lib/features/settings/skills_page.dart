// Skills settings page, ported from web/src/components/settings/SkillsPage.svelte:
// the gateway's installed skills sorted by name, each with name (mono),
// description ('No description' fallback) and a linked tag when the skill is
// a symlink. Empty state when the host has none.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/errors.dart';
import '../../state/connection_notifier.dart';
import '../../theme/tokens.dart';
import 'settings_widgets.dart';

/// One installed skill from /api/skills.
class SkillEntry {
  const SkillEntry({required this.name, required this.description, required this.symlink});
  final String name;
  final String description;
  final bool symlink;

  factory SkillEntry.fromJson(Object? json) {
    final m = json is Map<String, dynamic> ? json : const <String, dynamic>{};
    return SkillEntry(
      name: m['name'] is String ? m['name'] as String : '',
      description: m['description'] is String ? m['description'] as String : '',
      symlink: m['symlink'] == true,
    );
  }

  /// Sorted list, ported from the page's localeCompare sort.
  static List<SkillEntry> sorted(Object? json) {
    final installed = json is Map<String, dynamic> ? json['installed'] : null;
    if (installed is! List) return const [];
    final list = [
      for (final e in installed)
        if (e != null) SkillEntry.fromJson(e),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }
}

class SkillsPage extends ConsumerStatefulWidget {
  const SkillsPage({super.key});

  @override
  ConsumerState<SkillsPage> createState() => _SkillsPageState();
}

class _SkillsPageState extends ConsumerState<SkillsPage> {
  List<SkillEntry>? _skills;
  String? _error;

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
      if (_skills != null) return;
      if (prev?.active == null && next.active != null) _load();
    });
  }

  Future<void> _load() async {
    final gen = ++_loadGen;
    setState(() {
      _skills = null;
      _error = null;
    });
    final active = ref.read(connectionNotifierProvider).active;
    if (active == null || !mounted || gen != _loadGen) {
      if (mounted && gen == _loadGen) setState(() => _error = 'Not signed in.');
      return;
    }
    final token = await ref.read(tokenStoreProvider).read(active.id);
    if (!mounted || gen != _loadGen) return;
    final client =
        ref.read(gatewayClientFactoryProvider)(active.url, token ?? '');
    try {
      final json = await client.skills();
      if (!mounted || gen != _loadGen) return;
      setState(() => _skills = SkillEntry.sorted(json));
    } on GatewayClientError catch (e) {
      if (!mounted || gen != _loadGen) return;
      setState(() => _error = e.message);
    } catch (_) {
      if (!mounted || gen != _loadGen) return;
      setState(() => _error = 'Could not reach the gateway.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final skills = _skills;

    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(
        title: const Text('Skills'),
        backgroundColor: tokens.bg,
        foregroundColor: tokens.ink,
        elevation: 0,
      ),
      body: SettingsPageBody(
        children: [
          SettingsSection(
            title: 'Installed skills',
            hint: 'Read from the gateway host. Call one with a slash command in a session.',
            child: SettingsLoadState(
              ready: skills != null,
              error: _error,
              onRetry: _load,
              child: skills == null || skills.isEmpty
                  ? Text(
                      'No skills are installed on the gateway host.',
                      style: TextStyle(color: tokens.ink3, fontSize: OmpMetrics.fsSm),
                    )
                  : Column(
                      children: [
                        for (final s in skills)
                          Padding(
                            key: ValueKey('skill-${s.name}'),
                            padding: const EdgeInsets.only(bottom: OmpMetrics.s1),
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(OmpMetrics.s3),
                              decoration: BoxDecoration(
                                color: tokens.inset,
                                borderRadius:
                                    BorderRadius.circular(OmpMetrics.radiusMd),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          s.name,
                                          style: TextStyle(
                                            color: tokens.ink,
                                            fontSize: OmpMetrics.fsBase,
                                            fontWeight: FontWeight.w600,
                                            fontFamily: 'monospace',
                                          ),
                                        ),
                                      ),
                                      if (s.symlink) ...[
                                        const SizedBox(width: OmpMetrics.s2),
                                        Icon(
                                          Icons.insert_drive_file_outlined,
                                          size: 12,
                                          color: tokens.ink3,
                                        ),
                                        Text(
                                          'linked',
                                          style: TextStyle(
                                            color: tokens.ink3,
                                            fontSize: OmpMetrics.fsXs,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    s.description.isEmpty
                                        ? 'No description'
                                        : s.description,
                                    style: TextStyle(
                                      color: tokens.ink2,
                                      fontSize: OmpMetrics.fsSm,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
