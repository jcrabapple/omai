// Usage settings page, ported from web/src/components/settings/UsagePage.svelte:
// the /api/usage report rendered from ANSI escapes through
// lib/render/ansi.dart, in monospace inside a horizontally scrollable,
// selectable region. A Refresh button re-fetches (the gateway can take up
// to about 90 seconds). The response's own error text is shown when present;
// an empty report gets a note.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/errors.dart';
import '../../render/ansi.dart';
import '../../state/connection_notifier.dart';
import '../../theme/tokens.dart';
import 'settings_widgets.dart';

/// Parsed /api/usage response: {raw, error?}.
class UsageReport {
  const UsageReport({this.raw = '', this.error});
  final String raw;
  final String? error;

  factory UsageReport.fromJson(Object? json) {
    final m = json is Map<String, dynamic> ? json : const <String, dynamic>{};
    return UsageReport(
      raw: m['raw'] is String ? m['raw'] as String : '',
      error: m['error'] is String ? m['error'] as String : null,
    );
  }
}

class UsagePage extends ConsumerStatefulWidget {
  const UsagePage({super.key});

  @override
  ConsumerState<UsagePage> createState() => _UsagePageState();
}

class _UsagePageState extends ConsumerState<UsagePage> {
  UsageReport? _report;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    // The connection notifier may still be settling when the page opens;
    // reload once the active connection appears.
    ref.listenManual(connectionNotifierProvider, (prev, next) {
      if (_report != null || _error != null || _loading) return;
      if (prev?.active == null && next.active != null) _load();
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final active = ref.read(connectionNotifierProvider).active;
    if (active == null || !mounted) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final token = await ref.read(tokenStoreProvider).read(active.id);
    if (!mounted) return;
    final client =
        ref.read(gatewayClientFactoryProvider)(active.url, token ?? '');
    try {
      final json = await client.usage();
      if (!mounted) return;
      setState(() {
        _report = UsageReport.fromJson(json);
        _loading = false;
      });
    } on GatewayClientError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not reach the gateway.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final report = _report;

    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(
        title: const Text('Usage'),
        backgroundColor: tokens.bg,
        foregroundColor: tokens.ink,
        elevation: 0,
        actions: [
          TextButton(
            key: const ValueKey('usage-refresh'),
            onPressed: _loading ? null : _load,
            child: Text(
              'Refresh',
              style: TextStyle(
                color: _loading ? tokens.ink3 : tokens.accent,
              ),
            ),
          ),
        ],
      ),
      body: SettingsPageBody(
        children: [
          SettingsSection(
            title: 'Usage report',
            hint: 'What each provider reports for your accounts. Fetching it can take a few seconds.',
            child: SettingsLoadState(
              ready: !_loading && _error == null,
              error: _error,
              onRetry: _load,
              child: () {
                if (report == null) {
                  return Text(
                    'The gateway returned no usage data.',
                    style: TextStyle(color: tokens.ink3, fontSize: OmpMetrics.fsSm),
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (report.error != null)
                      Padding(
                        key: const ValueKey('usage-error-note'),
                        padding: const EdgeInsets.only(bottom: OmpMetrics.s2),
                        child: Text(
                          report.error!,
                          style: TextStyle(color: tokens.warn, fontSize: OmpMetrics.fsSm),
                        ),
                      ),
                    if (report.raw.isEmpty && report.error == null)
                      Text(
                        'The gateway returned no usage data.',
                        style: TextStyle(color: tokens.ink3, fontSize: OmpMetrics.fsSm),
                      )
                    else if (report.raw.isNotEmpty)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(OmpMetrics.s3),
                        decoration: BoxDecoration(
                          color: tokens.inset,
                          borderRadius:
                              BorderRadius.circular(OmpMetrics.radiusMd),
                        ),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SelectionArea(
                            child: Text.rich(
                              TextSpan(
                                children: ansiToSpans(
                                  report.raw,
                                  base: TextStyle(
                                    color: tokens.ink,
                                    fontSize: OmpMetrics.fsSm,
                                    fontFamily: 'monospace',
                                    height: 1.5,
                                  ),
                                ),
                              ),
                              key: const ValueKey('usage-report-text'),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              }(),
            ),
          ),
        ],
      ),
    );
  }
}
