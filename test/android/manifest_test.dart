// Release builds merge only src/main (+ src/release) manifests. Debug builds
// also get src/debug, which declares INTERNET for the Flutter tool, so a
// missing INTERNET in src/main is invisible in every debug build and fatal in
// release: the app cannot reach any gateway.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final main = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

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
}
