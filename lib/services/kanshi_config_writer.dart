import 'package:kanshi_gui/models/monitor_mode.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';

/// Knobs that influence what the [KanshiConfigWriter] emits in addition to
/// the bare per-output lines. These reflect the historically Sway-specific
/// behaviours of the app — they default to *off* so the writer is
/// compositor-neutral by default and only enables the Sway extras when the
/// caller (typically the SwayBackend) explicitly asks for them.
class KanshiWriteOptions {
  final bool injectSwayWorkspaceExec;
  final bool writeCurrentProfileMarker;
  /// Emit `exec wl-mirror …` lines for outputs whose `mirrorOf` is set.
  /// Sway-only — wl-mirror runs on any wlroots compositor in principle
  /// but the rest of the GUI's mirror UX (capability flag, toggle menu)
  /// is gated on the Sway backend, so the writer follows suit. Off in
  /// neutral mode so wlr-randr-style profiles stay portable.
  final bool injectMirrorExec;

  const KanshiWriteOptions({
    this.injectSwayWorkspaceExec = false,
    this.writeCurrentProfileMarker = false,
    this.injectMirrorExec = false,
  });

  static const swayDefaults = KanshiWriteOptions(
    injectSwayWorkspaceExec: true,
    writeCurrentProfileMarker: true,
    injectMirrorExec: true,
  );

  static const neutral = KanshiWriteOptions();
}

class KanshiConfigWriter {
  KanshiConfigWriter._();

  static String render(
    List<Profile> profiles, {
    KanshiWriteOptions options = KanshiWriteOptions.neutral,
  }) {
    final buffer = StringBuffer();
    for (final profile in profiles) {
      if (profile.monitors.isEmpty) continue;
      _renderProfile(buffer, profile, options);
    }
    return buffer.toString();
  }

  static void _renderProfile(
    StringBuffer buffer,
    Profile profile,
    KanshiWriteOptions options,
  ) {
    final referenceMonitors =
        profile.monitors.where((m) => m.enabled).toList();
    final baseForOffsets =
        referenceMonitors.isNotEmpty ? referenceMonitors : profile.monitors;

    final minX =
        baseForOffsets.map((m) => m.x).reduce((a, b) => a < b ? a : b);
    final minY =
        baseForOffsets.map((m) => m.y).reduce((a, b) => a < b ? a : b);
    final offsetX = (minX < 0) ? -minX : 0.0;
    final offsetY = (minY < 0) ? -minY : 0.0;

    final mons = profile.monitors
        .map((m) => _sanitizeMonitor(m, offsetX, offsetY))
        .toList()
      ..sort((a, b) {
        final byX = a.x.compareTo(b.x);
        if (byX != 0) return byX;
        return a.id.compareTo(b.id);
      });

    buffer.writeln("profile '${profile.name}' {");

    for (final m in mons) {
      if (!m.enabled) {
        buffer.writeln("    output '${m.id}' disable");
        continue;
      }
      // mode line is always landscape-oriented, transform handles rotation.
      final baseW = (m.rotation % 180 == 0) ? m.width : m.height;
      final baseH = (m.rotation % 180 == 0) ? m.height : m.width;
      final refresh = m.refresh > 0 ? m.refresh : 60.0;

      final posX = m.x < 0 ? 0 : m.x.toInt();
      final posY = m.y < 0 ? 0 : m.y.toInt();
      final transform = m.rotation == 0 ? 'normal' : m.rotation.toString();

      buffer.writeln(
        "    output '${m.id}' enable scale ${m.scale.toStringAsFixed(2)} "
        "mode ${baseW.toInt()}x${baseH.toInt()}@${formatHz(refresh)}Hz "
        "transform $transform position $posX,$posY",
      );
    }

    // Persist EDID-derived manufacturer info as a comment annotation so
    // profile matching survives a restart even when the user plugs the
    // same physical monitor into a different port (port id changes,
    // manufacturer/model/serial does not). Without this, the parser
    // would fall back to "manufacturer = port id" and the rehydrate +
    // match logic could only ever match on port id.
    //
    // We only emit when the manufacturer string carries information
    // beyond the port id itself (the parser's default for hand-edited
    // configs is `manufacturer == id` — round-tripping that would just
    // be noise) and we always emit irrespective of writer options
    // because the cost is one comment line per monitor and the
    // robustness payoff is meaningful for the auto-switch path.
    for (final m in mons) {
      if (m.manufacturer.isEmpty) continue;
      if (m.manufacturer == m.id) continue;
      // Manufacturer comes from EDID and is otherwise free-form. Strip
      // single quotes so the comment never produces malformed syntax
      // (the regex on the parser side uses single-quoted values). EDID
      // strings I've ever seen are alphanumeric + spaces, so this is a
      // belt-and-braces guard rather than a real lossy transform.
      final safeManuf = m.manufacturer.replaceAll("'", '');
      buffer.writeln(
        "    # kanshi_gui:edid '${m.id}'='$safeManuf'",
      );
    }

    if (options.injectMirrorExec) {
      // Persist mirror relationships as `# kanshi_gui:mirror …` comment
      // annotations rather than as `exec wl-mirror …` hooks. The exec
      // hook approach made kanshi the *second* lifecycle owner of every
      // wl-mirror process: every `kanshictl reload` re-ran the line and
      // spawned an additional wl-mirror, which produced duplicate
      // fullscreen windows on the destination, a cycle into
      // picture-in-picture recursion when two mirrors targeted each
      // other, and orphaned processes that survived the GUI's
      // `setMirror(null)` because the GUI's MirrorRunner only owned its
      // own children. The annotation pattern keeps kanshi blissfully
      // ignorant of mirroring; the GUI's MirrorRunner is the sole
      // owner. The mirror is restored on the next GUI launch via the
      // parser reading these annotations back into `mirrorOf`.
      for (final m in mons.where((m) => m.enabled && m.mirrorOf != null)) {
        buffer.writeln(
          "    # kanshi_gui:mirror '${m.id}'='${m.mirrorOf}'",
        );
      }
    }

    if (options.injectSwayWorkspaceExec) {
      // Workspaces are distributed **interleaved** by left-to-right
      // position. With N enabled outputs ranked 0..N-1 from left to right,
      // workspace `w` (1-indexed) lands on the monitor whose rank equals
      // `(w - 1) mod N`. So two screens give the left one workspaces
      // 1/3/5/7/9 and the right one 2/4/6/8; three screens give
      // 1/4/7, 2/5/8, 3/6/9. The number-keys 1..9 thus walk left-to-right
      // across the displays, looping back as you press higher numbers.
      //
      // Each monitor's rank defaults to its X-sorted index but can be
      // overridden via `MonitorTileData.workspaceRank` — useful when the
      // physical arrangement of identical monitors doesn't match what the
      // user perceives as "screen 1 / 2 / 3". Overrides are persisted as
      // `# kanshi_gui:rank '<id>'=<n>` comments below so they survive an
      // app restart.
      const maxWorkspaces = 9;
      // Mirror destinations are physically present but their pixels
      // are owned by wl-mirror's fullscreen surface. Including them
      // in the rank list would assign workspaces to a screen the user
      // can never see (the mirror occludes anything sway draws
      // beneath it). The on-canvas display path
      // (`LayoutMath.computeDisplay`) already filters destinations
      // out of `displayMonitors` for the same reason.
      final enabledMons =
          mons.where((m) => m.enabled && m.mirrorOf == null).toList();
      final ranked = resolveWorkspaceRanks(enabledMons);
      final n = ranked.length;
      if (n > 0) {
        for (final entry in ranked) {
          if (entry.explicit) {
            buffer.writeln(
              "    # kanshi_gui:rank '${entry.id}'=${entry.rank}",
            );
          }
        }
        // Build ONE chained swaymsg invocation rather than emitting N
        // separate `exec swaymsg "..."` lines. Two reasons:
        //
        //  1. Race elimination — kanshi spawns each `exec` in its own
        //     fork/exec. Multiple parallel invocations land in sway
        //     out-of-order; workspace 5 could be processed before
        //     workspace 2 and leak windows onto the wrong output.
        //     A single compound command is processed in declared order
        //     by sway's IPC.
        //
        //  2. Sway's `workspace N output X` is *passive* — it only
        //     specifies where workspace N is created at runtime; it
        //     does NOT move existing workspaces. To relocate
        //     workspaces that already exist with windows (e.g. ws 1
        //     opened before docking), we focus each in turn and run
        //     `move workspace to output X`. This forces the move for
        //     existing workspaces and is a no-op for empty ones.
        //
        // The pass first declares every output target up front
        // (so the later `workspace N` focus picks the right home)
        // then walks the workspaces and moves each one into place.
        // We end the chain with `workspace 1` so focus lands on the
        // leftmost-rank monitor — typically the user's primary
        // attention area after docking, and stable across runs.
        final parts = <String>[];
        // Pre-anchor each output's destination — declares "workspace
        // owned by this output if/when it's created or moved here".
        // Use `workspace number N` (not `workspace N`) so we target the
        // *numeric slot* regardless of any human-readable name the user
        // may have assigned (e.g. `1: code`). Without `number`, sway
        // interprets `workspace 1` as the workspace literally named
        // "1" and would create a fresh empty one alongside the user's
        // named "1: code", silently fragmenting their setup.
        for (var ws = 1; ws <= maxWorkspaces; ws++) {
          final rank = (ws - 1) % n;
          parts.add("workspace number $ws output '${ranked[rank].id}'");
        }
        // Now actively move each workspace into place. `workspace
        // number N` matches the numeric slot (creating it if absent
        // and focusing it); `move workspace to output X` relocates the
        // focused workspace to the desired output.
        for (var ws = 1; ws <= maxWorkspaces; ws++) {
          final rank = (ws - 1) % n;
          parts.add("workspace number $ws");
          parts.add("move workspace to output '${ranked[rank].id}'");
        }
        // Land focus on workspace number 1 — leftmost rank, usually the
        // user's primary screen post-docking. Without this final focus,
        // we'd leave the user on workspace 9.
        parts.add('workspace number 1');
        buffer.writeln(
          "    exec swaymsg \"${parts.join('; ')}\"",
        );
      }
    }

    if (options.writeCurrentProfileMarker) {
      buffer.writeln(
        "    exec echo \"${profile.name}\" > ~/.current_kanshi_profile",
      );
    }

    buffer.writeln("}\n");
  }

  static MonitorTileData _sanitizeMonitor(
      MonitorTileData m, double offsetX, double offsetY) {
    final posX = (m.x + offsetX) < 0 ? 0 : (m.x + offsetX).toInt();
    final posY = (m.y + offsetY) < 0 ? 0 : (m.y + offsetY).toInt();

    final bestMode = _pickBestMode(m, m.modes);

    final baseW = (m.rotation % 180 == 0) ? bestMode.width : bestMode.height;
    final baseH = (m.rotation % 180 == 0) ? bestMode.height : bestMode.width;
    final refresh = bestMode.refresh > 0 ? bestMode.refresh : 60.0;

    final orientation = (m.rotation % 180 == 0) ? 'landscape' : 'portrait';
    final resolution = '${baseW.toInt()}x${baseH.toInt()}';

    return m.copyWith(
      x: posX.toDouble(),
      y: posY.toDouble(),
      width: baseW,
      height: baseH,
      refresh: refresh,
      resolution: resolution,
      orientation: orientation,
      rotation: m.rotation % 360,
      scale: m.scale == 0 ? 1.0 : m.scale,
      id: m.id.trim(),
      manufacturer: m.manufacturer.trim(),
    );
  }

  static MonitorMode _pickBestMode(
    MonitorTileData monitor,
    List<MonitorMode> modes,
  ) {
    if (modes.isEmpty) {
      return MonitorMode(
        width: monitor.width,
        height: monitor.height,
        refresh: monitor.refresh > 0 ? monitor.refresh : 60,
      );
    }

    final desiredWidth =
        (monitor.rotation % 180 == 0) ? monitor.width : monitor.height;
    final desiredHeight =
        (monitor.rotation % 180 == 0) ? monitor.height : monitor.width;
    final desiredRefresh = monitor.refresh;

    var best = modes.first;
    var bestScore = 1e12;
    for (final m in modes) {
      final dw = (m.width - desiredWidth).abs().round();
      final dh = (m.height - desiredHeight).abs().round();
      final dr = (m.refresh - desiredRefresh).abs();
      final score = dw * 2000 + dh * 2000 + dr * 10;
      if (score < bestScore) {
        bestScore = score;
        best = m;
      }
      if (dw == 0 && dh == 0 && dr < 0.01) {
        best = m;
        break;
      }
    }
    return best;
  }

  static String formatHz(double hz) {
    final isInt = (hz - hz.round()).abs() < 0.01;
    return isInt ? hz.round().toString() : hz.toStringAsFixed(3);
  }
}

class WorkspaceRankEntry {
  final String id;
  final int rank;
  final bool explicit;
  const WorkspaceRankEntry(this.id, this.rank, this.explicit);
}

/// Resolves each enabled monitor to a unique 0..N-1 rank used for the
/// interleaved workspace distribution. Explicit `workspaceRank` overrides
/// win first (in X-ascending order on collision); remaining slots are
/// filled by the still-unranked monitors in X-ascending order.
///
/// Returned list is ordered **by effective rank** — element at index `i`
/// owns workspace `i+1`, `i+1+N`, `i+1+2N`, …
List<WorkspaceRankEntry> resolveWorkspaceRanks(List<MonitorTileData> mons) {
  if (mons.isEmpty) return const [];
  final n = mons.length;
  final byX = mons.toList()
    ..sort((a, b) {
      final byXCmp = a.x.compareTo(b.x);
      if (byXCmp != 0) return byXCmp;
      return a.id.compareTo(b.id);
    });

  final byRank = <int, MonitorTileData>{};
  final explicit = <String>{};
  // Pass 1: claim explicit ranks in X-order so collisions are resolved
  // deterministically (leftmost wins).
  final unranked = <MonitorTileData>[];
  for (final m in byX) {
    final r = m.workspaceRank;
    if (r == null) {
      unranked.add(m);
      continue;
    }
    final clamped = r < 0 ? 0 : (r >= n ? n - 1 : r);
    if (byRank.containsKey(clamped)) {
      unranked.add(m);
      continue;
    }
    byRank[clamped] = m;
    explicit.add(m.id);
  }
  // Pass 2: fill the remaining ranks with the still-unranked monitors,
  // taking the lowest free rank for the leftmost monitor.
  var nextRank = 0;
  for (final m in unranked) {
    while (byRank.containsKey(nextRank)) {
      nextRank++;
    }
    byRank[nextRank] = m;
    nextRank++;
  }
  return [
    for (var i = 0; i < n; i++)
      WorkspaceRankEntry(byRank[i]!.id, i, explicit.contains(byRank[i]!.id)),
  ];
}
