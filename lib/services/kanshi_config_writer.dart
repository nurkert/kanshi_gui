import 'package:kanshi_gui/domain/output_identity.dart';
import 'package:kanshi_gui/domain/workspace_layout.dart';
import 'package:kanshi_gui/models/monitor_mode.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/layout_math.dart';

// Workspace distribution moved to lib/domain/workspace_layout.dart — it is
// pure geometry over ranked outputs and has nothing to do with rendering a
// config file. Re-exported so the existing importers are untouched.
export 'package:kanshi_gui/domain/workspace_layout.dart';

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
  /// Which [WorkspaceDistribution] the injected workspace chain uses.
  /// Ignored when [injectSwayWorkspaceExec] is false.
  final WorkspaceDistribution workspaceDistribution;
  /// `--scaling` mode for the boot-fallback `exec wl-mirror …` lines.
  /// Ignored when [injectMirrorExec] is false. Mirrors the live
  /// MirrorRunner setting so the config and the GUI agree.
  final String mirrorScaling;

  const KanshiWriteOptions({
    this.injectSwayWorkspaceExec = false,
    this.writeCurrentProfileMarker = false,
    this.injectMirrorExec = false,
    this.workspaceDistribution = WorkspaceDistribution.interleaved,
    this.mirrorScaling = 'fit',
  });

  KanshiWriteOptions copyWith({
    bool? injectSwayWorkspaceExec,
    bool? writeCurrentProfileMarker,
    bool? injectMirrorExec,
    WorkspaceDistribution? workspaceDistribution,
    String? mirrorScaling,
  }) {
    return KanshiWriteOptions(
      injectSwayWorkspaceExec:
          injectSwayWorkspaceExec ?? this.injectSwayWorkspaceExec,
      writeCurrentProfileMarker:
          writeCurrentProfileMarker ?? this.writeCurrentProfileMarker,
      injectMirrorExec: injectMirrorExec ?? this.injectMirrorExec,
      workspaceDistribution:
          workspaceDistribution ?? this.workspaceDistribution,
      mirrorScaling: mirrorScaling ?? this.mirrorScaling,
    );
  }

  static const swayDefaults = KanshiWriteOptions(
    injectSwayWorkspaceExec: true,
    writeCurrentProfileMarker: true,
    injectMirrorExec: true,
  );

  static const neutral = KanshiWriteOptions();
}

class KanshiConfigWriter {
  KanshiConfigWriter._();

  /// Escapes a profile name for the single-quoted `profile '<name>' {` form.
  ///
  /// Before this, the name went in raw: a profile called "Nico's Desk"
  /// produced `profile 'Nico's Desk' {`, which kanshi refuses to parse. The
  /// daemon then stops managing displays altogether and the GUI can no
  /// longer read its own profiles back — from one apostrophe in a rename
  /// box. [KanshiConfigParser] performs the inverse.
  static String escapeProfileName(String name) =>
      name.replaceAll('\\', r'\\').replaceAll("'", r"\'");

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

    final sanitized = profile.monitors
        .map((m) => _sanitizeMonitor(m, offsetX, offsetY))
        .toList()
      ..sort((a, b) {
        final byX = a.x.compareTo(b.x);
        if (byX != 0) return byX;
        return a.id.compareTo(b.id);
      });
    // Hard guarantee: never emit an overlapping layout. Sway stacks outputs
    // that share logical coordinates, which is the "a screen landed on top
    // of the GUI" disaster. `resolveOverlaps` is idempotent, so a clean
    // layout passes through untouched.
    final mons = LayoutMath.resolveOverlaps(sanitized);

    // How kanshi should address each output. Descriptions win wherever the
    // display supplied one and it is unique inside this profile; see
    // [chooseOutputCriteria]. Outputs whose EDID we have never observed keep
    // the connector name — the descriptor is never guessed, only recorded.
    final criteria = chooseOutputCriteria(
      mons.map((m) => m.id),
      (connector) {
        final m = mons.firstWhere((e) => e.id == connector);
        return m.edidDescriptor.isEmpty ? null : m.edidDescriptor;
      },
    );

    buffer.writeln("profile '${escapeProfileName(profile.name)}' {");

    for (final m in mons) {
      final crit = criteria[m.id] ?? OutputCriteria.connector(m.id);
      if (!m.enabled) {
        buffer.writeln("    output ${crit.configForm} disable");
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
        "    output ${crit.configForm} enable "
        "scale ${m.scale.toStringAsFixed(2)} "
        "mode ${baseW.toInt()}x${baseH.toInt()}@${formatHz(refresh)}Hz "
        "transform $transform position $posX,$posY",
      );
    }

    // Record which connector each stable criteria resolved to when the file
    // was written. Purely informational for the GUI (it shows the port and
    // can re-key its annotations); kanshi ignores it, and a stale entry is
    // harmless because the live output set is what actually resolves names.
    for (final m in mons) {
      final crit = criteria[m.id];
      if (crit == null || !crit.isDescription) continue;
      buffer.writeln(
        "    # kanshi_gui:port '${crit.value.replaceAll("'", r"\'")}'"
        "='${m.id}'",
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
          "wl-mirror --scaling ${options.mirrorScaling} --fullscreen-output "
          "\"${m.id}\" \"${m.mirrorOf}\" &'",
        );
      }
    }

    if (options.injectSwayWorkspaceExec) {
      // A setup that has been observed carries its own map; the distribution
      // rule only seeds one that never has. See [Profile.workspaceMap].
      final learned = profile.workspaceMap;
      if (learned != null && learned.isNotEmpty) {
        for (final entry in (learned.keys.toList()..sort())) {
          buffer.writeln(
              "    # kanshi_gui:ws '$entry'='${learned[entry]}'");
        }
        final chain = buildLearnedWorkspaceChain(learned, criteria: criteria);
        if (chain != null) {
          buffer.writeln('    exec swaymsg "$chain"');
        }
      } else {
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
      final chain = buildSwayWorkspaceChain(
        ranked,
        distribution: options.workspaceDistribution,
        criteria: criteria,
      );
      if (chain != null) {
        // Earlier (1.5.12) we tried to claim a named workspace per
        // mirror destination so sway wouldn't auto-create an
        // unreachable numbered one (typically 10 on a 1..9 setup).
        // The name "mirror (X)" then showed up in the user's
        // swaybar, which is just a different flavour of the same
        // annoyance ("a workspace label I can't $mod-jump to").
        // The orphan-displacement is now handled in the controller's
        // verify step via the regular chain — the chain visits every
        // workspace 1..N which displaces any visible orphan, and
        // sway garbage-collects empty non-visible workspaces.
        buffer.writeln("    exec swaymsg \"$chain\"");
      }
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
      // MonitorTileData.width/height carry the ROTATED extent — both the
      // parser (kanshi_config_parser.dart) and the backends swap them for a
      // 90/270 transform. A MonitorMode is a PHYSICAL panel mode, so the
      // fallback has to swap back.
      //
      // Without this, a rotated output whose modes list is empty — which is
      // every output loaded from the config file, since the config carries
      // no mode list — had its rotated extent returned as if it were a
      // physical mode. _sanitizeMonitor then transposed it once and the
      // render line transposed it a second time, so `transform 270` with
      // `mode 1920x1080` was written back as `mode 1080x1920`, and the save
      // after that flipped it again. The mode oscillated on every save and
      // every second save asked the panel for a resolution it does not have.
      final landscape = monitor.rotation % 180 == 0;
      return MonitorMode(
        width: landscape ? monitor.width : monitor.height,
        height: landscape ? monitor.height : monitor.width,
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

