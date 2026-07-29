import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/services/mirror_runner.dart';
import 'package:kanshi_gui/services/monitor_service.dart';

/// Converges the running wl-mirror processes onto what the active setup asks
/// for.
///
/// Mirroring is the one feature whose state is not in the config: it is a set
/// of live child processes. That makes it the only part of the app where "what
/// we intend" and "what is running" can diverge without anything writing a
/// file, so it needs its own reconcile loop.
class MirrorCoordinator {
  final MonitorService monitors;
  final MirrorRunner runner;

  MirrorCoordinator(this.monitors, this.runner);

  /// Serialises reconciles.
  ///
  /// Without it, a hotplug-driven reconcile racing a profile-switch reconcile
  /// can read each other's half-installed state and kill a process the other
  /// just spawned.
  Future<void> _chain = Future.value();

  /// Queues a reconcile behind any in-flight one.
  ///
  /// [evacuate] is false for callers that already moved workspaces off the
  /// destinations themselves, so the backend is not asked to do it twice.
  Future<void> reconcile({
    required bool supportsMirror,
    required List<MonitorTileData> profileMonitors,
    required List<MonitorTileData> liveOutputs,
    required String Function(String) resolveConnector,
    bool evacuate = true,
  }) {
    final next = _chain.then((_) => _run(
          supportsMirror: supportsMirror,
          profileMonitors: profileMonitors,
          liveOutputs: liveOutputs,
          resolveConnector: resolveConnector,
          evacuate: evacuate,
        ));
    // The chain must not be poisoned by one reconcile's exception — a pgrep
    // IO error or a kill on a vanished pid would otherwise block every later
    // reconcile. _run also catches internally; this is defence in depth for
    // the day a refactor lets something escape.
    _chain = next.catchError((_) {});
    return next;
  }

  /// The destinations that should be mirroring, and from where.
  ///
  /// Both endpoints must be physically present: spinning up wl-mirror for an
  /// absent one just makes it exit, burn the retry budget and mark the
  /// destination failed.
  static Map<String, String> desiredMirrors(
    List<MonitorTileData> profileMonitors,
    Set<String> connectedIds,
  ) {
    final desired = <String, String>{};
    for (final m in profileMonitors) {
      final src = m.mirrorOf;
      if (src == null || !m.enabled) continue;
      if (!connectedIds.contains(m.id)) continue;
      if (!connectedIds.contains(src)) continue;
      desired[m.id] = src;
    }
    return desired;
  }

  /// Where workspaces on [destination] can be sent instead.
  ///
  /// Filtered through the live set so the backend is never asked to move
  /// something to a port name the compositor has never heard of.
  static List<String> evacuationTargets({
    required String destination,
    required List<MonitorTileData> profileMonitors,
    required Set<String> connectedIds,
    required String Function(String) resolveConnector,
  }) =>
      profileMonitors
          .where((m) => m.enabled && m.mirrorOf == null && m.id != destination)
          .map((m) => resolveConnector(m.id))
          .where(connectedIds.contains)
          .toList(growable: false);

  /// Moves the workspaces off [destination] and waits for it to clear.
  ///
  /// Best-effort: the worst case of a failure here is a window stuck under
  /// wl-mirror's fullscreen layer, which the user can recover from by hand.
  /// Far worse would be not spawning the mirror at all because the evacuate
  /// path threw.
  Future<void> evacuate(String destination, List<String> targets) async {
    if (targets.isEmpty) return;
    try {
      await monitors.evacuateOutputWorkspaces(destination, targets);
      await monitors.waitForOutputClear(destination);
    } catch (e) {
      debugPrint('mirror: evacuating $destination failed: $e');
    }
  }

  Future<void> _run({
    required bool supportsMirror,
    required List<MonitorTileData> profileMonitors,
    required List<MonitorTileData> liveOutputs,
    required String Function(String) resolveConnector,
    required bool evacuate,
  }) async {
    try {
      if (!supportsMirror) {
        // The backend cannot mirror — make sure nothing is left running.
        if (runner.activeDestinations.isNotEmpty) {
          await runner.stopAll();
        }
        return;
      }

      final connectedIds = liveOutputs.map((m) => m.id).toSet();
      final desired = desiredMirrors(profileMonitors, connectedIds);

      // Stop mirrors that are no longer wanted, or whose source changed.
      for (final dst in runner.activeDestinations) {
        if (desired[dst] == null) await runner.stop(dst);
      }

      for (final entry in desired.entries) {
        final dst = entry.key;
        final isNew = !runner.activeDestinations.contains(dst);
        if (isNew && evacuate) {
          // Any workspace that lived on the destination before now would end
          // up buried under wl-mirror's fullscreen layer, and the user could
          // not reach those windows. Evacuate, settle, then spawn.
          await this.evacuate(
            resolveConnector(dst),
            evacuationTargets(
              destination: dst,
              profileMonitors: profileMonitors,
              connectedIds: connectedIds,
              resolveConnector: resolveConnector,
            ),
          );
        }
        await runner.start(entry.value, dst);
      }

      // Sweep up wl-mirror processes the OS is running that do not belong to
      // the desired set: orphans from an older `exec wl-mirror` config, or
      // from a previous session that crashed before it could clean up.
      await runner.purgeExternalNotMatching(desired);
    } catch (e, st) {
      // start / purgeExternalNotMatching shell out to pgrep and kill; either
      // can fail when the system is out of fds, the binaries are missing, or
      // a pid races the scan. Logging rather than rethrowing keeps the
      // fire-and-forget call sites safe under any backend weather.
      debugPrint('mirror reconcile failed: $e\n$st');
    }
  }
}
