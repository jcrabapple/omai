// Release builds merge only src/main (+ src/release) manifests. Debug builds
// also get src/debug, which declares INTERNET for the Flutter tool, so a
// missing INTERNET in src/main is invisible in every debug build and fatal in
// release: the app cannot reach any gateway.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final main = File('android/app/src/main/AndroidManifest.xml')
      .readAsStringSync();

  test('the main manifest declares INTERNET (release builds need it)', () {
    expect(
      main,
      contains('<uses-permission android:name="android.permission.INTERNET"'),
    );
  });

  test('the main manifest never enables cleartext traffic', () {
    expect(main, isNot(contains('usesCleartextTraffic="true"')));
    expect(main, isNot(contains('networkSecurityConfig')));
  });

  test(
    'the launcher label comes from app_name: Omai, and Omai Debug in debug',
    () {
      expect(main, contains('android:label="@string/app_name"'));
      expect(
        File('android/app/src/main/res/values/strings.xml').readAsStringSync(),
        contains('<string name="app_name">Omai</string>'),
      );
      expect(
        File('android/app/src/debug/res/values/strings.xml').readAsStringSync(),
        contains('<string name="app_name">Omai Debug</string>'),
      );
    },
  );

  test(
    'debug shortcuts are the main shortcuts retargeted to the .debug package',
    () {
      String body(String s) => s.substring(s.indexOf('<shortcuts'));
      final m = File('android/app/src/main/res/xml/shortcuts.xml')
          .readAsStringSync();
      final d = File('android/app/src/debug/res/xml/shortcuts.xml')
          .readAsStringSync();
      expect(m, contains('android:targetPackage="us.snakepit.omai"'));
      expect(
        body(d),
        body(m).replaceAll(
          'android:targetPackage="us.snakepit.omai"',
          'android:targetPackage="us.snakepit.omai.debug"',
        ),
      );
    },
  );
}
