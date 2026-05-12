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

    // Lookup so mirror destinations can borrow the source's position
    // when computing their own `position` line — see the loop below
    // for why.
    final byId = {for (final m in mons) m.id: m};

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

      // Mirror destinations overlay the source's Sway-coordinate
      // rectangle. Without this, Sway treats the destination output
      // as its own interactive area: the user can move the cursor
      // onto it and lose focus on the dead output, even though
      // wl-mirror only renders the source's content there. Stacking
      // the rectangles eliminates that dead zone — input at the
      // shared coords stays with the source, and wl-mirror keeps
      // painting the destination's pixels because it targets by
      // output name, not by position.
      final src = m.mirrorOf != null ? byId[m.mirrorOf] : null;
      final posSourceX = src != null ? src.x : m.x;
      final posSourceY = src != null ? src.y : m.y;
      final posX = posSourceX < 0 ? 0 : posSourceX.toInt();
      final posY = posSourceY < 0 ? 0 : posSourceY.toInt();
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
      // Manufacturer comes from EDID and is otherwise free-form. We
      // wrap the value in single quotes so the parser regex can rely
      // on a stable terminator, but a `'` inside the value would
      // close the quote prematurely. Escape literal apostrophes as
      // `\'`; the parser unescapes them on read. Real-world EDID
      // strings rarely contain apostrophes, but stripping them
      // (the pre-1.5.1 behaviour) was lossy: downstream
      // manufacturer-fallback matching byte-compares against the
      // unstripped live data, so a manufacturer like `L'Hôtel`
      // would silently drop out of matching after a save+load.
      final safeManuf = m.manufacturer.replaceAll("'", r"\'");
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
      final ranked = resolveWorkspaceRanks(
        mons.where((m) => m.enabled && m.mirrorOf == null).toList(),
      );
      for (final entry in ranked) {
        if (entry.explicit) {
          buffer.writeln(
            "    # kanshi_gui:rank '${entry.id}'=${entry.rank}",
          );
        }
      }
      final chain = buildSwayWorkspaceChain(ranked);
      if (chain != null) {
        buffer.writeln("    exec swaymsg \"$chain\"");
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

/// Builds the semicolon-joined `swaymsg` command that distributes the
/// numeric workspaces 1..[maxWorkspaces] across the ranked outputs.
///
/// Workspaces are distributed **interleaved** by left-to-right
/// position. With N ranked outputs (0..N-1 left-to-right), workspace
/// `w` (1-indexed) lands on the rank `(w - 1) mod N`. Two screens give
/// the left one workspaces 1/3/5/7/9 and the right one 2/4/6/8;
/// three screens give 1/4/7, 2/5/8, 3/6/9 — the number-keys 1..9
/// walk left-to-right across the displays, looping back as you press
/// higher numbers.
///
/// Caller supplies a pre-computed ranked list (typically via
/// [resolveWorkspaceRanks]) so the controller-side verify-and-fix path
/// (which also wants to know the desired ws→output mapping for
/// comparison) doesn't have to re-derive it.
///
/// Returns `null` when [ranked] is empty — there's no workspace
/// distribution to express.
///
/// Why a single chained invocation instead of N separate `exec swaymsg`
/// lines:
///
///  1. Race elimination — kanshi spawns each `exec` in its own
///     fork/exec. Multiple parallel invocations land in sway
///     out-of-order; workspace 5 could be processed before workspace 2
///     and leak windows onto the wrong output. A single compound
///     command is processed in declared order by sway's IPC.
///
///  2. Sway's `workspace N output X` is *passive* — it only specifies
///     where workspace N is created at runtime; it does NOT move
///     existing workspaces. To relocate workspaces that already exist
///     with windows (e.g. ws 1 opened before docking), we focus each
///     in turn and run `move workspace to output X`. This forces the
///     move for existing workspaces and is a no-op for empty ones.
///
/// The chain first declares every output target up front (so the later
/// `workspace N` focus picks the right home), then walks the workspaces
/// and moves each one into place, and ends on `workspace number 1` so
/// focus lands on the leftmost-rank monitor — typically the user's
/// primary attention area after docking, and stable across runs.
///
/// Uses `workspace number N` (not `workspace N`) so we target the
/// *numeric slot* regardless of any human-readable name the user may
/// have assigned (e.g. `1: code`). Without `number`, sway interprets
/// `workspace 1` as the workspace literally named "1" and would create
/// a fresh empty one alongside the user's named "1: code", silently
/// fragmenting their setup.
String? buildSwayWorkspaceChain(
  List<WorkspaceRankEntry> ranked, {
  int maxWorkspaces = 9,
}) {
  final n = ranked.length;
  if (n == 0) return null;
  final parts = <String>[];
  for (var ws = 1; ws <= maxWorkspaces; ws++) {
    final rank = (ws - 1) % n;
    parts.add("workspace number $ws output '${ranked[rank].id}'");
  }
  for (var ws = 1; ws <= maxWorkspaces; ws++) {
    final rank = (ws - 1) % n;
    parts.add("workspace number $ws");
    parts.add("move workspace to output '${ranked[rank].id}'");
  }
  parts.add('workspace number 1');
  return parts.join('; ');
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
