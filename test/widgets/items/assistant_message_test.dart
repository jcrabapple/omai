// Widget tests for AssistantMessage (markdown, code, links, errors).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:ohmypi/transcript/items.dart';
import 'package:ohmypi/widgets/items/assistant_message.dart';
import 'package:ohmypi/widgets/items/message_actions.dart';

import '../pump_omp.dart';
import 'package:ohmypi/theme/presets.dart';

AssistantItem item({
  String text = '',
  bool streaming = false,
  String? error,
  String? stopReason,
}) =>
    AssistantItem(
      id: 'a1',
      text: text,
      streaming: streaming,
      error: error,
      stopReason: stopReason,
    );

void main() {
  testWidgets('renders markdown: bold, list, code block', (tester) async {
    await pumpOmp(
      tester,
      AssistantMessage(
        item: item(text: '# Title\n\n**bold** and `code`\n\n```dart\nvoid main() {}\n```\n'),
      ),
    );
    expect(find.text('Title'), findsOneWidget);
    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(find.textContaining('void main()'), findsOneWidget);
  });

  testWidgets('text is selectable', (tester) async {
    await pumpOmp(tester, AssistantMessage(item: item(text: 'select me')));
    expect(find.byType(SelectionArea), findsOneWidget);
  });

  testWidgets('tapping a link does not crash and reaches the callback',
      (tester) async {
    String? tapped;
    await pumpOmp(
      tester,
      AssistantMessage(
        item: item(text: '[docs](https://example.com)'),
        onLinkTap: (href) => tapped = href,
      ),
    );
    await tester.tap(find.text('docs'));
    await tester.pump();
    expect(tapped, 'https://example.com');
  });

  testWidgets('stopped and error notes', (tester) async {
    await pumpOmp(
      tester,
      AssistantMessage(
          item: item(text: 'partial', stopReason: 'aborted', error: 'boom')),
    );
    expect(find.text('Stopped'), findsOneWidget);
    final err = tester.widget<Text>(find.text('boom'));
    final t = tokensOf(tester, OmpPreset.terminal);
    expect(err.style?.color, t.err);
  });

  testWidgets('hidden while empty and not streaming', (tester) async {
    await pumpOmp(tester, AssistantMessage(item: item(text: '   ')));
    expect(find.byType(MarkdownBody), findsNothing);
    expect(find.byType(MessageActions), findsNothing);
  });

  testWidgets('smoke under all four theme presets', (tester) async {
    for (final preset in OmpPreset.values) {
      await pumpOmp(tester,
          AssistantMessage(item: item(text: '## Heading\n\nplain text')),
          preset: preset);
      expect(find.text('Heading'), findsOneWidget,
          reason: 'preset ${preset.name}');
    }
  });

  testWidgets('streaming deltas re-render markdown at most once per 100ms',
      (tester) async {
    var now = DateTime(2026);
    final seen = <String>{};
    String rendered() =>
        tester.widget<MarkdownBody>(find.byType(MarkdownBody).first).data;

    await pumpOmp(
        tester, AssistantMessage(item: item(text: 'chunk 0', streaming: true), clockNow: () => now));
    seen.add(rendered());

    // 50 rapid updates inside one throttle window: the markdown subtree
    // must not rebuild for each.
    for (var i = 1; i <= 50; i++) {
      await pumpOmp(
          tester,
          AssistantMessage(
              item: item(text: 'chunk $i', streaming: true),
              clockNow: () => now));
      seen.add(rendered());
    }
    expect(seen.length, lessThanOrEqualTo(2),
        reason: '50 updates within 100ms are throttled');
    expect(seen.contains('chunk 50'), isFalse);

    // When the window passes, the deferred render shows the latest text.
    now = now.add(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));
    expect(rendered(), 'chunk 50');

    // Streaming ends: the final text always renders.
    await pumpOmp(
        tester,
        AssistantMessage(item: item(text: 'final text'), clockNow: () => now));
    expect(rendered(), 'final text');
  });
}
