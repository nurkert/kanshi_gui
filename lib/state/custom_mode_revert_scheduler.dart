import 'dart:async';

/// Manages per-output revert timers for the "Custom Mode" advanced flow.
/// Each timer fires after [defaultDelay] unless the caller cancels it
/// (typically via the snackbar's "Keep" action) or schedules a new one.
class CustomModeRevertScheduler {
  final Duration defaultDelay;
  final Map<String, Timer> _timers = {};

  CustomModeRevertScheduler(
      {this.defaultDelay = const Duration(seconds: 10)});

  void schedule(String outputId, void Function() onRevert,
      {Duration? delay}) {
    cancel(outputId);
    _timers[outputId] = Timer(delay ?? defaultDelay, () {
      _timers.remove(outputId);
      onRevert();
    });
  }

  void cancel(String outputId) {
    _timers.remove(outputId)?.cancel();
  }

  void cancelAll() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
  }

  bool isActive(String outputId) => _timers.containsKey(outputId);
}
