import 'dart:async';

/// Severity of the one status message the app shows at a time.
///
/// Strict priority order, highest first. A naive implementation that let
/// "Applying…" cover "your config is unwritable" is the failure mode this
/// ordering exists to prevent.
enum StatusLevel {
  /// A question the user must answer — the safety-net countdown. Leaves the
  /// status line entirely and takes the centre of the window, because the
  /// user may be looking at a screen that just went black.
  decision,

  /// Something is wrong and stays wrong until it is dealt with. Never
  /// auto-dismisses, never covers the canvas, always carries exactly one
  /// action.
  attention,

  /// Work in progress. Suppressed below [AppStatus.workingThreshold] so a
  /// routine drag never flickers a spinner.
  working,

  /// The resting state, which is 99% of the app's life.
  settled,
}

/// How much of the promise "these screens will come back exactly like this"
/// the app has actually earned.
///
/// This is the ethical core of the status line: the green check is a render
/// of a comparison that ran, never a decoration. If a gate could not be
/// checked the sentence gets weaker and truer — it never gets quieter, and it
/// is never omitted.
enum AssuranceLevel {
  /// Written, read back identical, the live layout matches, and the daemon
  /// that will re-apply it is running.
  verified,

  /// Written and read back, but there is no live compositor to compare
  /// against — the offline editor. We can promise the file, nothing more.
  writtenOnly,

  /// Written, but something that has to be true for it to come back is not:
  /// kanshi is not running, or the live layout does not match what was saved.
  written,

  /// Nothing has been saved yet in this session.
  unknown,
}

/// One status message. Immutable; the owner replaces it wholesale.
class AppStatus {
  final StatusLevel level;

  /// The sentence shown to the user. Never empty.
  final String message;

  /// Label of the single action, or null when there is nothing to do.
  final String? actionLabel;

  /// Invoked when the action is used.
  final FutureOr<void> Function()? onAction;

  /// Only meaningful at [StatusLevel.settled]: how much was verified.
  final AssuranceLevel assurance;

  /// Set for transient messages that decay back to the resting state.
  final Duration? life;

  const AppStatus({
    required this.level,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.assurance = AssuranceLevel.unknown,
    this.life,
  });

  /// Below this, a "working" state is not rendered at all. Routine saves and
  /// applies finish well inside it, so the line stays still.
  static const Duration workingThreshold = Duration(milliseconds: 400);

  /// How long a transient confirmation stays before decaying.
  static const Duration undoLife = Duration(seconds: 8);

  /// How long the "everything came back where it should" note stays. This is
  /// the app cashing the cheque it wrote last time, and the moment trust is
  /// actually built.
  static const Duration verifiedFlashLife = Duration(seconds: 6);

  bool get hasAction => actionLabel != null && onAction != null;

  AppStatus copyWith({
    StatusLevel? level,
    String? message,
    String? actionLabel,
    FutureOr<void> Function()? onAction,
    AssuranceLevel? assurance,
    Duration? life,
  }) =>
      AppStatus(
        level: level ?? this.level,
        message: message ?? this.message,
        actionLabel: actionLabel ?? this.actionLabel,
        onAction: onAction ?? this.onAction,
        assurance: assurance ?? this.assurance,
        life: life ?? this.life,
      );

  /// The resting sentence, graded to what was actually verified.
  factory AppStatus.settled(AssuranceLevel assurance, {int screenCount = 0}) {
    final screens = switch (screenCount) {
      0 => 'These screens',
      1 => 'This screen',
      _ => 'These $screenCount screens',
    };
    final verb = screenCount == 1 ? 'comes' : 'come';
    return AppStatus(
      level: StatusLevel.settled,
      assurance: assurance,
      message: switch (assurance) {
        AssuranceLevel.verified =>
          'Saved. $screens $verb back exactly like this.',
        AssuranceLevel.writtenOnly =>
          "Saved to your config. I can't see your screens from here, so "
              "that's all I can promise.",
        AssuranceLevel.written =>
          'Saved, but I could not confirm it will come back.',
        AssuranceLevel.unknown => 'Nothing to save yet.',
      },
    );
  }
}

/// Owns the single status message and the transient-decay timer.
///
/// Replaces four surfaces that could stack: the health banner, the drift
/// banner, the safety-net bar and the SnackBar sites. Only one of them was
/// ever positioned relative to the others — with a hardcoded 96px offset —
/// which is what "not thought through" looks like from outside.
class StatusCenter {
  AppStatus _status = AppStatus.settled(AssuranceLevel.unknown);
  Timer? _decay;
  final List<void Function()> _listeners = [];

  AppStatus get status => _status;

  void addListener(void Function() cb) => _listeners.add(cb);
  void removeListener(void Function() cb) => _listeners.remove(cb);

  /// The resting state this decays back to. Owners keep it current.
  AppStatus resting = AppStatus.settled(AssuranceLevel.unknown);

  void show(AppStatus next) {
    _decay?.cancel();
    _status = next;
    final life = next.life;
    if (life != null) {
      _decay = Timer(life, () {
        // Only decay if nothing more important arrived in the meantime.
        if (identical(_status, next)) {
          _status = resting;
          _notify();
        }
      });
    }
    _notify();
  }

  /// Updates the resting state, and the visible status too when the line is
  /// currently at rest.
  void setResting(AppStatus next) {
    resting = next;
    if (_status.level == StatusLevel.settled) {
      _decay?.cancel();
      _status = next;
      _notify();
    }
  }

  /// Clears a transient or attention state back to rest.
  void clear() {
    _decay?.cancel();
    _status = resting;
    _notify();
  }

  void dispose() {
    _decay?.cancel();
    _listeners.clear();
  }

  void _notify() {
    for (final l in List.of(_listeners)) {
      l();
    }
  }
}
