import 'dart:async';

/// A countdown-revert primitive for risky display operations.
///
/// The pattern: caller wraps a risky compositor mutation (mode change,
/// disable, …) with [guard]. The mutation runs immediately, but a timer
/// starts that — when it fires — runs the supplied inverse to undo. The
/// caller can [confirm] within the window to keep the change, or
/// [revertNow] to undo immediately.
///
/// Same key (e.g. "mode-change") within an active window: the timer is
/// reset and the *original* inverse stays — so the user can chain several
/// experimental mode switches and a single "Keep" cements the final one.
class SafetyNet {
  /// Mutable so the settings UI can retune it live; only affects guards
  /// armed *after* the change (an in-flight countdown keeps its window).
  Duration window;

  SafetyNet({this.window = const Duration(seconds: 15)});

  final Map<String, _Guard> _guards = {};
  void Function(SafetyNetPrompt? prompt)? _listener;

  /// Reverts whose inverse threw. The user is by definition sitting in the
  /// state the revert was supposed to undo — possibly looking at a black
  /// screen — so a failure here must never be swallowed.
  final List<_Guard> _failedReverts = [];

  /// Invoked when a revert throws. Wired to the UI so the failure is
  /// surfaced instead of vanishing into an unhandled async error inside a
  /// [Timer] callback.
  void Function(String key, String label, Object error)? onRevertFailed;

  /// True when at least one revert failed and can still be retried.
  bool get hasFailedRevert => _failedReverts.isNotEmpty;

  /// Labels of the reverts that failed, oldest first.
  List<String> get failedRevertLabels =>
      List.unmodifiable(_failedReverts.map((g) => g.label));

  SafetyNetPrompt? get activePrompt {
    if (_guards.isEmpty) return null;
    final g = _guards.values.first;
    return SafetyNetPrompt(
      key: g.key,
      label: g.label,
      remaining: () => g.remaining,
    );
  }

  /// UI subscribes here to react to lifecycle changes.
  void onChange(void Function(SafetyNetPrompt? prompt) cb) {
    _listener = cb;
  }

  /// Runs [doIt], then arms a [window] timer that calls [revert] unless
  /// [confirm] is invoked.
  ///
  /// If a guard with the same [key] is already active, the *new* doIt runs
  /// immediately, but the existing timer is reset and the *original*
  /// revert stays in place — so chains of experimental ops collapse into
  /// a single revert that restores the pre-chain state.
  Future<void> guard<T>({
    required String key,
    required String label,
    required Future<T> Function() doIt,
    required Future<void> Function() revert,
  }) async {
    // A zero (or negative) window means the user switched the safety net
    // off in Settings, where the slider is labelled "Off" and the subtitle
    // reads "0 disables the safety net". Arming `Timer(Duration.zero, …)`
    // instead made every guarded operation — every mode change, every
    // disable — undo itself within a frame, silently. Run the operation and
    // do not arm anything.
    //
    // An already-armed guard is deliberately left alone: [window] is
    // documented to affect only guards armed after the change, and
    // cancelling one here would silently behave like [confirm].
    if (window <= Duration.zero) {
      await doIt();
      return;
    }

    final existing = _guards[key];
    final keptRevert = existing?.revert ?? revert;
    existing?.timer.cancel();

    await doIt();

    final g = _Guard(
      key: key,
      label: label,
      revert: keptRevert,
      armedAt: DateTime.now(),
      window: window,
      timer: Timer(window, () => _autoRevert(key)),
    );
    _guards[key] = g;
    _notify();
  }

  Future<void> _autoRevert(String key) async {
    final g = _guards.remove(key);
    if (g == null) return;
    g.timer.cancel();
    try {
      await g.revert();
      _failedReverts.removeWhere((f) => f.key == key);
    } catch (e) {
      // Keep the guard so [retryFailedReverts] can run it again, and tell
      // whoever is listening. Previously this threw out of a Timer callback
      // and became an unhandled async error nobody ever saw.
      if (!_failedReverts.any((f) => f.key == key)) {
        _failedReverts.add(g);
      }
      onRevertFailed?.call(g.key, g.label, e);
    } finally {
      _notify();
    }
  }

  /// Re-runs every revert that previously threw. Returns the labels that
  /// failed again, so the caller can keep the user informed rather than
  /// pretending the retry worked.
  Future<List<String>> retryFailedReverts() async {
    final pending = List<_Guard>.from(_failedReverts);
    _failedReverts.clear();
    final stillFailing = <String>[];
    for (final g in pending) {
      try {
        await g.revert();
      } catch (e) {
        _failedReverts.add(g);
        stillFailing.add(g.label);
        onRevertFailed?.call(g.key, g.label, e);
      }
    }
    _notify();
    return stillFailing;
  }

  void confirm(String key) {
    final g = _guards.remove(key);
    g?.timer.cancel();
    _notify();
  }

  Future<void> revertNow(String key) async {
    await _autoRevert(key);
  }

  void cancelAll() {
    for (final g in _guards.values) {
      g.timer.cancel();
    }
    _guards.clear();
    _failedReverts.clear();
    _notify();
  }

  void _notify() {
    _listener?.call(activePrompt);
  }
}

class SafetyNetPrompt {
  final String key;
  final String label;
  final Duration Function() remaining;
  const SafetyNetPrompt({
    required this.key,
    required this.label,
    required this.remaining,
  });
}

class _Guard {
  final String key;
  final String label;
  final Future<void> Function() revert;
  final DateTime armedAt;
  final Duration window;
  final Timer timer;
  _Guard({
    required this.key,
    required this.label,
    required this.revert,
    required this.armedAt,
    required this.window,
    required this.timer,
  });
  Duration get remaining {
    final elapsed = DateTime.now().difference(armedAt);
    final left = window - elapsed;
    return left.isNegative ? Duration.zero : left;
  }
}
