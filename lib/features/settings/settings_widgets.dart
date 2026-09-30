// Shared settings widgets, ported from web/src/components/settings/Section.svelte
// and LoadState.svelte. A Section is a titled group with a one-line hint;
// LoadState covers the three data states: a small progress indicator while a
// fetch runs (never the word Loading), the error with a Retry button, and the
// content itself.

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// Titled group with an optional one-line hint, ported from Section.svelte.
class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.title,
    this.hint,
    required this.child,
  });

  final String title;
  final String? hint;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        OmpMetrics.s4,
        OmpMetrics.s5,
        OmpMetrics.s4,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: tokens.ink,
              fontSize: OmpMetrics.fsBase,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (hint != null)
            Padding(
              padding: const EdgeInsets.only(top: OmpMetrics.s1),
              child: Text(
                hint!,
                style: TextStyle(
                  color: tokens.ink3,
                  fontSize: OmpMetrics.fsSm,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: OmpMetrics.s3),
            child: child,
          ),
        ],
      ),
    );
  }
}

/// One label / value row of an info grid, ported from ConnectionPage's dl.
class SettingsRow extends StatelessWidget {
  const SettingsRow({super.key, required this.label, required this.value, this.mono = false});

  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: OmpMetrics.s1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 168,
            child: Text(
              label,
              style: TextStyle(color: tokens.ink3, fontSize: OmpMetrics.fsSm),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: tokens.ink,
                fontSize: OmpMetrics.fsSm,
                fontFamily: mono ? 'monospace' : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _LoadPhase { loading, error, ready }

/// Fetch states for a settings section: progress indicator, error + Retry,
/// or the content. Ported from LoadState.svelte.
class SettingsLoadState extends StatelessWidget {
  const SettingsLoadState({
    super.key,
    required this.ready,
    this.error,
    required this.onRetry,
    required this.child,
  });

  final bool ready;
  final String? error;
  final VoidCallback onRetry;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final phase =
        ready ? _LoadPhase.ready : (error != null ? _LoadPhase.error : _LoadPhase.loading);
    return switch (phase) {
      _LoadPhase.ready => child,
      _LoadPhase.error => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            error!,
            style: TextStyle(color: tokens.err, fontSize: OmpMetrics.fsSm),
          ),
          const SizedBox(height: OmpMetrics.s2),
          OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
      _LoadPhase.loading => const Center(
        child: Padding(
          padding: EdgeInsets.all(OmpMetrics.s4),
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
    };
  }
}

/// A settings page body with the standard scroll padding.
class SettingsPageBody extends StatelessWidget {
  const SettingsPageBody({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...children,
          const SizedBox(height: OmpMetrics.s6),
        ],
      ),
    );
  }
}
