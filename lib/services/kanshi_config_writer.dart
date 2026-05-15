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

      // Mirror destinations keep their OWN position — earlier releases
      // (1.5.7) tried to stack them onto the source's Sway-coordinate
      // rectangle so the cursor wouldn't get "lost" on the dead output.
      // Empirically that backfires the moment wl-mirror is actually
      // running: wl-mirror's layer-shell surface lands on the dest
      // output's geometry, but because dest and source share the
      // exact rect, sway also paints that surface onto the source
      // output. wl-mirror then captures the source (now containing
      // its own surface), projects that onto the dest (which already
      // has it), and you get a 1980s-VCR infinity-mirror cascade.
      // Lesson: mirror destination MUST occupy a different rectangle
      // from the source. The cursor-routing concern is solved at the
      // GUI / placement layer (drop the dest next to the source by
      // default), not by overlapping rects in the kanshi config.
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
      // Mirror persistence has two parts that must agree:
      //   1) a `# kanshi_gui:mirror` annotation so the parser can
      //      hydrate `mirrorOf` back into the model on GUI launch,
      //   2) a `pgrep`-guarded `exec wl-mirror …` so the mirror is
      //      actually live whether or not the GUI is running — the
      //      destination output is otherwise just stacked on the source
      //      with no content-mirroring, which is the broken-after-boot
      //      state users hit when kanshi applies the profile alone.
      //
      // The guard is the load-bearing detail: a bare `exec wl-mirror`
      // re-ran on every `kanshictl reload` and stacked duplicate
      // processes; pgrep-checking the live `--fullscreen-output <dst>`
      // argv makes the spawn idempotent across reloads. The GUI's
      // MirrorRunner still takes ownership at runtime by killing the
      // kanshi-spawned process via `_killExternalForDst` and replacing
      // it with a managed one, so a single owner exists when the GUI
      // is up (managed retries, crash handling) and a "best-effort"
      // owner (kanshi's exec) covers the boot window.
      for (final m in mons.where((m) => m.enabled && m.mirrorOf != null)) {
        buffer.writeln(
          "    # kanshi_gui:mirror '${m.id}'='${m.mirrorOf}'",
        );
        // Pgrep guard. Two pitfalls avoided here:
        //   * `pgrep -f` matches against the FULL argv of every
        //     process — including the very shell running this guard,
        //     whose argv literally contains our pattern. That shell
        //     self-match meant the guard ALWAYS reported "running" and
        //     wl-mirror was never spawned at boot.
        //   * `pgrep -fF` doesn't exist; we want a literal substring
        //     check, not a regex one (output names don't have regex
        //     metachars today, but the `-` in `eDP-1` is a footgun if
        //     anyone ever puts ranges in `[...]`).
        // Solution: `pgrep -x wl-mirror -a` filters by *process name*
        // (so the shell can't match), then `grep -qF` does a literal
        // substring check against the cmdline. Trailing space pins the
        // destination so e.g. `eDP-1` doesn't accidentally match a
        // hypothetical `eDP-10`.
        buffer.writeln(
          "    exec sh -c 'pgrep -x wl-mirror -a | "
          "grep -qF -- \"--fullscreen-output ${m.id} \" || "
          "wl-mirror --fullscreen-output \"${m.id}\" \"${m.mirrorOf}\" &'",
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
/// `workspace N` focus picks the right home AND so any *future*
/// workspace creation during the session lands on the assigned
/// monitor without help from kanshi_gui), then walks the workspaces
/// and moves each one into place, and ends on `workspace number 1`
/// so focus lands on the leftmost-rank monitor — typically the
/// user's primary attention area after docking, and stable across
/// runs.
///
/// Phase-1 (the output binding) deliberately uses `workspace N output X`
/// rather than `workspace number N output X`. Sway stores the binding
/// in its `workspace_outputs` list keyed by workspace name; the
/// `number` variant produces a `success:true` IPC reply but the stored
/// key does not match what sway looks up when a workspace is later
/// created with `workspace number N`, so the binding never takes
/// effect on workspace destruction + recreation. Without the binding,
/// a $mod+5 from a different output creates ws 5 on the focused
/// output instead of its assigned home — the long-standing complaint
/// that workspaces above 3 (or above N for N monitors) "open wherever
/// the cursor is". This binding persists for the whole sway session.
///
/// Phase-2 keeps `workspace number N` for the focus + force-move
/// because the rename concern (`1: code`) is real: a user who renamed
/// their numeric workspaces needs the numeric-slot selector here,
/// otherwise the unsuffixed form would create an empty "1" alongside
/// the live "1: code" and silently fragment their setup.
String? buildSwayWorkspaceChain(
  List<WorkspaceRankEntry> ranked, {
  int maxWorkspaces = 9,
}) {
  final n = ranked.length;
  if (n == 0) return null;
  final parts = <String>[];
  for (var ws = 1; ws <= maxWorkspaces; ws++) {
    final rank = (ws - 1) % n;
    // Phase 1: persistent output binding. NO `number` keyword — see
    // the docstring above for why.
    parts.add("workspace $ws output '${ranked[rank].id}'");
  }
  for (var ws = 1; ws <= maxWorkspaces; ws++) {
    final rank = (ws - 1) % n;
    // Phase 2: focus the numeric slot (renamed-workspace safe) and
    // force-move any pre-existing workspace to its new home output.
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
