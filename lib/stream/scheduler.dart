// Injectable time for the stream: a clock plus delay/period timers, so tests
// run deterministically with a fake scheduler instead of fake_async.

import 'dart:async';

/// Cancel a previously scheduled timer; safe to call more than once.
typedef CancelTimer = void Function();

/// Time source and timer factory for [SessionStream].
abstract class Scheduler {
  DateTime now();

  /// Run [fn] once after [delay]. Returns a cancel function.
  CancelTimer delay(Duration delay, void Function() fn);

  /// Run [fn] every [period], starting after one full period. Returns cancel.
  CancelTimer period(Duration period, void Function() fn);
}

class SystemScheduler implements Scheduler {
  const SystemScheduler();

  @override
  DateTime now() => DateTime.now();

  @override
  CancelTimer delay(Duration delay, void Function() fn) {
    final t = Timer(delay, fn);
    return () => t.cancel();
  }

  @override
  CancelTimer period(Duration period, void Function() fn) {
    final t = Timer.periodic(period, (_) => fn());
    return () => t.cancel();
  }
}
