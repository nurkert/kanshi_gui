import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';

/// Notices when the screens are not where the saved setup says they should be.
///
/// The condition it exists for: kanshi re-matches a profile on hotplug and,
/// on a bad day, the compositor never receives one of the `position X,Y`
/// directives. The app's expectation is right, the hardware disagrees, and
/// nothing else would ever say so.
class DriftMonitor {
  /// Positional tolerance in logical pixels. Absorbs scale rounding — a
  /// fractional scale rarely divides a mode into whole numbers.
  static const double tolerance = 2.0;

  /// The cached comparison.
  ///
  /// Deliberately cached rather than computed on read: during a drag the
  /// profile's coordinates change on every pointer update while the live
  /// snapshot only catches up once the compositor emits an output event, so a
  /// live computation reports drift for every dragged pixel. This must only
  /// surface real, settled disagreement — not the user's own edit in
  /// progress.
  List<String> _issues = const [];

  bool _dismissed = false;

  /// Differences between the active setup and the applied layout, as of the
  /// last time [recompute] ran.
  List<String> get issues => List.unmodifiable(_issues);

  /// Whether the user should currently be told. Distinct from [issues] being
  /// non-empty: a dismissal hides the current round without pretending the
  /// difference went away.
  bool get shouldSurface => !_dismissed && _issues.isNotEmpty;

  /// Hides the current round. The next [resetDismissal] — driven by a fresh
  /// hotplug — lets a new difference through again.
  void dismiss() => _dismissed = true;

  void resetDismissal() => _dismissed = false;

  /// Recomputes against the current state. Returns true when the result
  /// changed, so the caller can decide whether a repaint is warranted.
  bool recompute({
    required bool isLive,
    required Profile? activeProfile,
    required List<MonitorTileData> liveOutputs,
  }) {
    final next = _compute(
      isLive: isLive,
      activeProfile: activeProfile,
      liveOutputs: liveOutputs,
    );
    if (_sameIssues(next, _issues)) return false;
    _issues = next;
    return true;
  }

  static List<String> _compute({
    required bool isLive,
    required Profile? activeProfile,
    required List<MonitorTileData> liveOutputs,
  }) {
    if (!isLive) return const [];
    if (activeProfile == null) return const [];
    if (liveOutputs.isEmpty) return const [];

    final liveById = {for (final m in liveOutputs) m.id: m};
    final issues = <String>[];
    for (final pe in activeProfile.monitors) {
      // Disabled outputs have no position, and a mirror destination inherits
      // its geometry from the source, so its stored coordinates are advisory
      // and would report drift permanently.
      if (!pe.enabled || pe.mirrorOf != null) continue;
      final live = liveById[pe.id];
      if (live == null) continue;
      final dx = (pe.x - live.x).abs();
      final dy = (pe.y - live.y).abs();
      if (dx > tolerance || dy > tolerance) {
        issues.add(
          '${pe.id}: expected '
          '(${pe.x.toStringAsFixed(0)}, ${pe.y.toStringAsFixed(0)})'
          ' but is at '
          '(${live.x.toStringAsFixed(0)}, ${live.y.toStringAsFixed(0)})',
        );
      }
    }
    return issues;
  }

  static bool _sameIssues(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
