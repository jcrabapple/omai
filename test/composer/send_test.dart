// Ports of web/src/lib/composer/__tests__/send.test.ts.
import 'package:flutter_test/flutter_test.dart';
import 'package:ohmypi/transcript/send.dart';

void main() {
  group('send plan', () {
    test('idle: Send is the only action', () {
      final p = sendPlan(false);
      expect(p.primary.mode, 'prompt');
      expect(p.primary.label, 'Send');
      expect(p.secondary, isNull);
    });
    test('streaming: Steer primary, Queue secondary', () {
      final p = sendPlan(true);
      expect(p.primary.mode, 'steer');
      expect(p.primary.label, 'Steer');
      expect(p.secondary!.mode, 'follow_up');
      expect(p.secondary!.label, 'Queue');
    });
    test('Ctrl/Cmd+Enter queues only while streaming', () {
      expect(modeForKey(true, false), 'steer');
      expect(modeForKey(true, true), 'follow_up');
      expect(modeForKey(false, true), 'prompt');
      expect(modeForKey(false, false), 'prompt');
    });
    test('notes the lifecycle: steer stays pending until its echo, queued, plain',
        () {
      expect(sendNote('steer'), 'steer-pending');
      expect(sendNote('follow_up'), 'queued');
      expect(sendNote('prompt'), isNull);
    });
  });
}
