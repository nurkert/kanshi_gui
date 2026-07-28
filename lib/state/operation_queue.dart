import 'dart:async';

/// Serialises the operations that reach the compositor.
///
/// Applying a layout is not atomic: every one of these is a sequence of
/// subprocess calls with awaits between them, and in those gaps anything can
/// happen — a hotplug can land, the user can hit another button, a safety-net
/// timer can fire. Two such sequences interleaving means the compositor
/// receives half of one and half of another, and the model ends up describing
/// neither.
///
/// One queue, in call order. Not a lock: callers still get their result back,
/// and a failure in one operation cannot stall the ones behind it.
class OperationQueue {
  Future<void> _tail = Future.value();

  /// Whether something is currently queued or running. Useful for disabling
  /// controls rather than letting the user pile up conflicting requests.
  int _pending = 0;
  bool get isBusy => _pending > 0;

  /// Called when [isBusy] changes, so the UI can reflect it.
  void Function()? onBusyChanged;

  /// Runs [operation] after everything already queued.
  ///
  /// The returned future completes with [operation]'s result, or its error —
  /// the queue itself never swallows one, because an operation that failed
  /// silently is exactly what M4 removed from this codebase.
  Future<T> run<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _pending++;
    if (_pending == 1) onBusyChanged?.call();

    _tail = _tail.then((_) async {
      try {
        completer.complete(await operation());
      } catch (e, st) {
        completer.completeError(e, st);
      } finally {
        _pending--;
        if (_pending == 0) onBusyChanged?.call();
      }
    });
    return completer.future;
  }

  /// Waits for the queue to drain. Tests and teardown use this; production
  /// code should await the individual [run] futures it cares about.
  Future<void> get idle => _tail;
}
