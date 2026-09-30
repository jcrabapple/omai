// Production [KeepaliveSurface]: talks to MainActivity/KeepaliveService
// over the single app MethodChannel. No policy lives here.

import 'package:flutter/services.dart';

import 'keepalive.dart';

class MethodChannelKeepaliveSurface implements KeepaliveSurface {
  const MethodChannelKeepaliveSurface();

  static const MethodChannel channel = MethodChannel('us.snakepit.omai/native');

  @override
  Future<bool> ensureNotificationPermission() async {
    try {
      final r = await channel.invokeMethod('requestNotificationPermission');
      return r == true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      // No native side (tests, or the engine is gone): report refused.
      return false;
    }
  }

  @override
  Future<bool> showRunning({
    required String gwId,
    required String sessionTitle,
    String? tool,
    required int startedAt,
  }) async {
    try {
      final r = await channel.invokeMethod('startKeepalive', <String, Object?>{
        'gwId': gwId,
        'title': runningNotificationTitle(sessionTitle),
        'text': runningNotificationText(tool, startedAt, DateTime.now()),
      });
      return r == true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> updateRunning({
    required String sessionTitle,
    String? tool,
    required int startedAt,
  }) async {
    await channel.invokeMethod('updateKeepalive', <String, Object?>{
      'title': runningNotificationTitle(sessionTitle),
      'text': runningNotificationText(tool, startedAt, DateTime.now()),
    });
  }

  @override
  Future<void> stopRunning() async {
    await channel.invokeMethod('stopKeepalive');
  }

  @override
  Future<void> showApproval({
    required String requestId,
    required String gwId,
    required String title,
    required String body,
    required List<NotificationAction> actions,
  }) {
    return channel.invokeMethod('showApproval', <String, Object?>{
      'requestId': requestId,
      'gwId': gwId,
      'title': title,
      'body': body,
      'actions': [
        for (final a in actions)
          <String, Object?>{'id': a.id, 'label': a.label},
      ],
    });
  }

  @override
  Future<void> cancelApproval(String requestId) {
    return channel.invokeMethod('cancelApproval', <String, Object?>{
      'requestId': requestId,
    });
  }
}

/// The app version from Android's PackageManager, read at runtime via the
/// native channel (no package_info_plus). Null when the channel fails or
/// returns junk; the About page shows 'Unknown'.
Future<({String versionName, int versionCode})?> fetchAppVersion() async {
  try {
    final r = await MethodChannelKeepaliveSurface.channel.invokeMethod<Object?>(
      'getAppVersion',
    );
    if (r is! Map) return null;
    final name = r['versionName'];
    final code = r['versionCode'];
    if (name is String && name.isNotEmpty && code is int) {
      return (versionName: name, versionCode: code);
    }
    return null;
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}
