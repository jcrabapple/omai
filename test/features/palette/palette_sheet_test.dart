// Palette sheet widget tests: typing filters, tapping a session row pops the
// sheet then opens the session, Enter runs the top result, empty state reads
// 'No matches'. Live/saved sessions come from the sessions store, seeded
// directly.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omai/api/models.dart';
import 'package:omai/features/palette/palette_sheet.dart';
import 'package:omai/palette/palette.dart';
import 'package:omai/state/sessions_store.dart';
import 'package:omai/theme/presets.dart';

class _Actions implements PaletteActions {
  final List<String> opened = [];
  final List<SavedSession> resumed = [];
  final List<String> settings = [];
  int newSessions = 0;
  int nextAttentionCalls = 0;
  @override
  void newSession() => newSessions++;
  @override
  void nextAttention() => nextAttentionCalls++;
  @override
  void openSession(String gwId) => opened.add(gwId);
  @override
  void resume(SavedSession s) => resumed.add(s);
  @override
  void openSettings(String page) => settings.add(page);
}

SessionInfo liveSession(String gwId, {String? name}) =>
    SessionInfo.fromJson({
      'gwId': gwId,
      'cwd': '/work/x',
      'ompSessionName': ?name,
      'isStreaming': false,
      'pendingUi': const [],
      'lastEventSeq': 0,
    });

SavedSession savedSession(String file, String title) => SavedSession.fromJson({
      'file': file,
      'mtime': 1700000100.0,
      'sizeBytes': 10,
      'cwdFolder': 'x',
      'cwd': '/work/x',
      'title': title,
      'running': false,
    });

Future<_Actions> _pump(
  WidgetTester tester, {
  List<SessionInfo> live = const [],
  List<SavedSession> saved = const [],
}) async {
  tester.view.physicalSize = const Size(400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final actions = _Actions();
  final container = ProviderContainer();
  addTearDown(container.dispose);
  container.read(sessionsStoreProvider.notifier).state = SessionsState(
    live: live,
    saved: saved,
    loaded: true,
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: OmpTheme.data(OmpPreset.terminal),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () =>
                    showPaletteSheet(context, actions: actions),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return actions;
}

void main() {
  testWidgets('shows the empty-query menu with section headers', (
    tester,
  ) async {
    await _pump(tester, live: [liveSession('a', name: 'Fix login bug')]);
    expect(find.text('Actions'), findsOneWidget);
    expect(find.text('Sessions'), findsOneWidget);
    expect(find.text('New session'), findsOneWidget);
    expect(find.text('Fix login bug'), findsOneWidget);
    expect(find.text('Appearance settings'), findsNothing,
        reason: 'the empty-query menu caps settings to zero');
  });

  testWidgets('typing filters the list', (tester) async {
    await _pump(
      tester,
      live: [liveSession('a', name: 'Fix login bug')],
      saved: [savedSession('/s/b.jsonl', 'Old chat')],
    );
    await tester.enterText(find.byType(TextField), 'old chat');
    await tester.pump();
    expect(find.text('Old chat'), findsOneWidget);
    expect(find.text('Fix login bug'), findsNothing);
  });

  testWidgets('tapping a session row pops the sheet then opens the session',
      (tester) async {
    final actions =
        await _pump(tester, live: [liveSession('abc', name: 'Fix login bug')]);
    await tester.tap(find.text('Fix login bug'));
    await tester.pumpAndSettle();
    expect(find.byType(PaletteSheet), findsNothing,
        reason: 'the sheet closed');
    expect(actions.opened, ['abc'],
        reason: 'the action ran after the pop');
  });

  testWidgets('Enter runs the top result', (tester) async {
    final actions = await _pump(
      tester,
      saved: [
        savedSession('/s/1.jsonl', 'Old chat one'),
        savedSession('/s/2.jsonl', 'Old chat two'),
      ],
    );
    await tester.enterText(find.byType(TextField), 'old chat two');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.byType(PaletteSheet), findsNothing);
    expect(actions.resumed.map((s) => s.file), ['/s/2.jsonl']);
  });

  testWidgets('no results shows No matches', (tester) async {
    await _pump(tester, live: [liveSession('a', name: 'Fix login bug')]);
    await tester.enterText(find.byType(TextField), 'zzzzqqqq');
    await tester.pump();
    expect(find.text('No matches'), findsOneWidget);
  });

  testWidgets('a settings row calls openSettings with the page id',
      (tester) async {
    final actions = await _pump(tester);
    await tester.enterText(find.byType(TextField), '> appearance');
    await tester.pump();
    await tester.tap(find.text('Appearance settings'));
    await tester.pumpAndSettle();
    expect(actions.settings, ['appearance']);
  });

  testWidgets('results stay fully above a keyboard inset', (tester) async {
    // Simulated keyboard: a 300dp bottom inset.
    tester.view.viewInsets = FakeViewPadding(bottom: 300);
    await _pump(tester, live: [liveSession('a', name: 'Fix login bug')]);
    final rowBottom = tester.getBottomRight(find.text('Fix login bug')).dy;
    expect(
      rowBottom,
      lessThanOrEqualTo(900 - 300),
      reason: 'the first result row must be fully above the keyboard',
    );
  });
}
