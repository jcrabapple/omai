// Connect screen: URL + token entry, paste helpers, a three-legged test
// (healthz, me, WebSocket probe) and sign in.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app.dart';
import '../../state/connection_notifier.dart';
import '../../theme/tokens.dart';

class ConnectScreen extends ConsumerStatefulWidget {
  const ConnectScreen({super.key});

  @override
  ConsumerState<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends ConsumerState<ConnectScreen> {
  final _url = TextEditingController();
  final _token = TextEditingController();

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _paste(TextEditingController controller) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) controller.text = text.trim();
  }

  Future<void> _test() async {
    await ref.read(connectionNotifierProvider.notifier).testConnection(
          _url.text,
          _token.text,
        );
  }

  Future<void> _signIn() async {
    await ref.read(connectionNotifierProvider.notifier).signIn(
          url: _url.text,
          label: Uri.tryParse(_url.text.trim())?.host ?? '',
          token: _token.text,
        );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    final state = ref.watch(connectionNotifierProvider);
    final outcome = state.testOutcome;

    return OmpPage(
      title: 'Connect to ohmypi',
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(OmpMetrics.s5),
            children: [
              Text(
                'Point the app at your gateway. The token is stored in the '
                'Android keystore, never in plain prefs.',
                style: TextStyle(color: tokens.ink2, fontSize: OmpMetrics.fsSm),
              ),
              const SizedBox(height: OmpMetrics.s5),
              _field(
                context,
                controller: _url,
                label: 'Gateway URL',
                hint: 'https://your-gateway.example.com',
                onPaste: () => _paste(_url),
              ),
              const SizedBox(height: OmpMetrics.s4),
              _field(
                context,
                controller: _token,
                label: 'Gateway token',
                hint: 'The token from the gateway host',
                obscure: true,
                onPaste: () => _paste(_token),
              ),
              const SizedBox(height: OmpMetrics.s5),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: state.busy ? null : _test,
                      child: const Text('Test connection'),
                    ),
                  ),
                  const SizedBox(width: OmpMetrics.s3),
                  Expanded(
                    child: FilledButton(
                      onPressed: state.busy ? null : _signIn,
                      child: const Text('Sign in'),
                    ),
                  ),
                ],
              ),
              if (state.busy) ...[
                const SizedBox(height: OmpMetrics.s4),
                const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
              if (outcome != null) ...[
                const SizedBox(height: OmpMetrics.s4),
                Text(outcome,
                    style: TextStyle(
                        color: outcome.contains('OK')
                            ? tokens.ok
                            : tokens.err,
                        fontSize: OmpMetrics.fsSm)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(
    BuildContext context, {
    required TextEditingController controller,
    required String label,
    required String hint,
    bool obscure = false,
    required VoidCallback onPaste,
  }) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                color: tokens.ink2,
                fontSize: OmpMetrics.fsSm,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: OmpMetrics.s1),
        TextField(
          controller: controller,
          obscureText: obscure,
          autocorrect: false,
          enableSuggestions: !obscure,
          keyboardType: TextInputType.url,
          style: TextStyle(
              color: tokens.ink,
              fontSize: OmpMetrics.fsBase,
              fontFamily: obscure ? 'monospace' : null),
          decoration: InputDecoration(
            hintText: hint,
            suffixIcon: IconButton(
              tooltip: 'Paste',
              onPressed: onPaste,
              icon: const Icon(Icons.content_paste),
            ),
          ),
        ),
      ],
    );
  }
}
