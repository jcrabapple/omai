// About page widget tests: the version comes from a mocked getAppVersion on
// the native channel, a PlatformException or junk response falls back to
// 'Unknown', and the licenses row opens Flutter's LicensePage.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omai/features/settings/about_page.dart';
import 'package:omai/native/method_channel_bridge.dart';
import 'package:omai/theme/presets.dart';

import 'fakes.dart';

Future<void> pump(WidgetTester tester) async {
  final container = FakeGateway(const {}).container;
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: OmpTheme.data(OmpPreset.terminal),
        home: const AboutPage(),
      ),
    ),
  );
  await tester.pump();
}

void mockChannel(
  WidgetTester tester,
  Future<Object?> Function(MethodCall call)? handler,
) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    MethodChannelKeepaliveSurface.channel,
    handler,
  );
  addTearDown(() {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      MethodChannelKeepaliveSurface.channel,
      null,
    );
  });
}

void main() {
  testWidgets('renders the version, build mode and gateway url', (
    tester,
  ) async {
    mockChannel(tester, (call) async {
      expect(call.method, 'getAppVersion');
      return {'versionName': '1.2.3', 'versionCode': 45};
    });
    await pump(tester);
    expect(find.text('Omai'), findsOneWidget);
    expect(find.text('Android client for the ohmypi gateway.'), findsOneWidget);
    expect(find.text('1.2.3 (45)'), findsOneWidget);
    expect(find.text('Debug'), findsOneWidget);
    // The FakeGateway container has an active connection at https://gw.test.
    expect(find.text('https://gw.test'), findsOneWidget);
  });

  testWidgets('a PlatformException shows Unknown instead of throwing', (
    tester,
  ) async {
    mockChannel(tester, (call) async {
      throw PlatformException(code: 'nope', message: 'boom');
    });
    await pump(tester);
    expect(find.text('Unknown'), findsOneWidget);
  });

  testWidgets('a junk channel response shows Unknown', (tester) async {
    mockChannel(
      tester,
      (call) async => {'versionName': 42, 'versionCode': 'x'},
    );
    await pump(tester);
    expect(find.text('Unknown'), findsOneWidget);
  });

  testWidgets('the licenses row opens the LicensePage', (tester) async {
    mockChannel(
      tester,
      (call) async => {'versionName': '1.2.3', 'versionCode': 45},
    );
    await pump(tester);
    await tester.tap(find.text('Open source licenses'));
    await tester.pumpAndSettle();
    expect(find.byType(LicensePage), findsOneWidget);
    expect(find.text('Omai'), findsWidgets);
  });
}
