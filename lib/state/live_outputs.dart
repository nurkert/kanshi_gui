import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:kanshi_gui/models/monitor_mode.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/services/monitor_service.dart';

/// What changed between two views of the connected hardware.
class OutputsChanged {
  final List<MonitorTileData> outputs;
  final Set<String> added;
  final Set<String> removed;

  const OutputsChanged({
    required this.outputs,
    required this.added,
    required this.removed,
  });

  bool get setChanged => added.isNotEmpty || removed.isNotEmpty;
}

/// The one place that knows what is physically plugged in.
///
/// Before this, `_currentMonitors` was written from four places in the
/// controller and read from thirty, so "what the compositor is doing" and
/// "what the profile says" could be edited into each other — which is exactly
/// how the auto-created setup ended up aliasing the live snapshot and blinding
/// drift detection.
class LiveOutputs {
  final MonitorService monitors;

  LiveOutputs(this.monitors);

  List<MonitorTileData> _current = const [];

  /// The connected outputs, as last observed. Unmodifiable: callers that want
  /// to change a layout go through the profile, never through this.
  List<MonitorTileData> get current => List.unmodifiable(_current);

  /// How long the output set must hold still before the settled view is
  /// published.
  ///
  /// Docking does not produce one event, it produces a salvo: outputs appear
  /// one at a time as the dock enumerates them, and EDID can settle late.
  /// Handling each one separately runs the whole downstream pipeline against
  /// a half-connected set.
  ///
  /// Leading-edge WITH a trailing re-run: the first event is published at
  /// once so screens appear immediately, further events inside the window are
  /// coalesced, and once the set holds still it is published once more.
  /// Responsiveness is kept; the final state is computed from the whole
  /// picture. Set to [Duration.zero] to disable, which tests do when they
  /// mean two deliberately separate hotplugs.
  Duration settleWindow = const Duration(milliseconds: 400);

  StreamSubscription<List<MonitorTileData>>? _subscription;
  Timer? _settleTimer;
  List<MonitorTileData>? _latest;
  bool _disposed = false;

  /// Re-reads the connected outputs. Returns false when the backend threw,
  /// leaving the previous snapshot in place rather than blanking it.
  Future<bool> refresh() async {
    try {
      _current = await monitors.getOutputs();
      return true;
    } catch (e) {
      debugPrint('getOutputs failed: $e');
      return false;
    }
  }

  /// Starts watching for hotplug events. [onChanged] receives settled views.
  void subscribe(void Function(OutputsChanged) onChanged) {
    if (!monitors.isLive) return;
    _subscription = monitors.watchOutputs().listen((next) {
      if (_disposed) return;
      _latest = next;
      final midBurst = _settleTimer?.isActive ?? false;
      if (!midBurst) _publish(next, onChanged);
      _settleTimer?.cancel();
      if (settleWindow > Duration.zero) {
        _settleTimer = Timer(settleWindow, () {
          final settled = _latest;
          _latest = null;
          if (settled == null || _disposed) return;
          final settledIds = settled.map((m) => m.id).toSet();
          final handledIds = _current.map((m) => m.id).toSet();
          // Nothing moved on from what the leading edge already handled.
          if (settledIds.length == handledIds.length &&
              settledIds.containsAll(handledIds)) {
            return;
          }
          _publish(settled, onChanged);
        });
      }
    });
  }

  void _publish(
    List<MonitorTileData> next,
    void Function(OutputsChanged) onChanged,
  ) {
    final oldIds = _current.map((m) => m.id).toSet();
    final newIds = next.map((m) => m.id).toSet();
    _current = next;
    onChanged(OutputsChanged(
      outputs: next,
      added: newIds.difference(oldIds),
      removed: oldIds.difference(newIds),
    ));
  }

  /// Whether [m] names an output that is currently connected.
  bool isConnected(bool Function(MonitorTileData live) matches) =>
      _current.any(matches);

  /// The mode a connected output is running, or null when it is not there.
  MonitorMode? modeFor(String connector) {
    for (final m in _current) {
      if (m.id != connector) continue;
      return MonitorMode(width: m.width, height: m.height, refresh: m.refresh);
    }
    return null;
  }

  void dispose() {
    _disposed = true;
    _settleTimer?.cancel();
    // ignore: discarded_futures
    _subscription?.cancel();
  }
}
