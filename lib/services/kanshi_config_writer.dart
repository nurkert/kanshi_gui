import 'package:kanshi_gui/domain/output_identity.dart';
import 'package:kanshi_gui/domain/workspace_layout.dart';
import 'package:kanshi_gui/domain/workspace_plan.dart';
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
  /// Whether a setup's observed [Profile.workspaceMap] overlays the
  /// distribution rule ("keep them where I put them") or is ignored in favour
  /// of the rule alone. Off by default: a user who picked a distribution
  /// asked for that distribution, and an observation that contradicts it is
  /// as likely to be an accident as a preference. Ignored when
  /// [injectSwayWorkspaceExec] is false.
  final bool followProfileWorkspaceMap;
  /// `--scaling` mode for the boot-fallback `exec wl-mirror …` lines.
  /// Ignored when [injectMirrorExec] is false. Mirrors the live
  /// MirrorRunner setting so the config and the GUI agree.
  final String mirrorScaling;

  const KanshiWriteOptions({
    this.injectSwayWorkspaceExec = false,
    this.writeCurrentProfileMarker = false,
    this.injectMirrorExec = false,
    this.workspaceDistribution = WorkspaceDistribution.interleaved,
    this.followProfileWorkspaceMap = false,
    this.mirrorScaling = 'fit',
  });

  KanshiWriteOptions copyWith({
    bool? injectSwayWorkspaceExec,
    bool? writeCurrentProfileMarker,
    bool? injectMirrorExec,
    WorkspaceDistribution? workspaceDistribution,
    bool? followProfileWorkspaceMap,
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
      followProfileWorkspaceMap:
          followProfileWorkspaceMap ?? this.followProfileWorkspaceMap,
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
  /// Sanitises a value going into a `# kanshi_gui:…` annotation.
  ///
  /// These are comments — kanshi never executes them — but they are still
  /// *lines*. A newline inside one ends the comment and whatever follows
  /// becomes a config directive in its own right, which is a way to smuggle
  /// an `exec` into the file from an EDID string or a hand-edited value.
  /// Control characters out, apostrophes escaped for the parser that reads
  /// these back.
  static String _annotationValue(String value) => value
      .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
      .replaceAll("'", r"\'");

  /// Control characters go first: a newline in a name would end the
  /// `profile '…' {` line and turn the rest into config directives.
  static String escapeProfileName(String name) => name
      .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
      .replaceAll('\\', r'\\')
      .replaceAll("'", r"\'");

  static String render(
    List<Profile> profiles, {
    KanshiWriteOptions options = KanshiWriteOptions.neutral,
  }) {
    final buffer = StringBuffer();
    // Worked out once, from ALL the setups, and written identically into
    // every one of them. A `workspace N output X` binding outlives the desk it
    // was written for — sway keeps the first one it was given and ignores
    // every later one — so a per-profile answer is a trap the moment you
    // dock. See [workspaceHomes].
    final homes = options.injectSwayWorkspaceExec
        ? workspaceHomes(
            profiles: profiles,
            distribution: options.workspaceDistribution,
            followProfileMap: options.followProfileWorkspaceMap,
          )
        : const <int, List<OutputCriteria>>{};
    for (final profile in profiles) {
      if (profile.monitors.isEmpty) continue;
      _renderProfile(buffer, profile, options, homes);
    }
    return buffer.toString();
  }

  static void _renderProfile(
    StringBuffer buffer,
    Profile profile,
    KanshiWriteOptions options,
    Map<int, List<OutputCriteria>> homes,
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
    String? descriptorOf(String connector) {
      final m = mons.firstWhere((e) => e.id == connector);
      return m.edidDescriptor.isEmpty ? null : m.edidDescriptor;
    }

    final criteria = chooseOutputCriteria(mons.map((m) => m.id), descriptorOf);
    // The `exec` lines get a second, narrower answer, and it is not computed
    // here: the `output` directive above is read by kanshi itself and must
    // keep the stable description whatever it contains, while an `exec` line
    // goes to a shell where the same description can be a syntax error. That
    // answer now spans every setup at once — see [workspaceHomes] — so it is
    // worked out in [render] and handed down.

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
        "    # kanshi_gui:port '${_annotationValue(crit.value)}'"
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
      final safeManuf = _annotationValue(m.manufacturer);
      buffer.writeln(
        "    # kanshi_gui:edid '${_annotationValue(m.id)}'='$safeManuf'",
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
          "    # kanshi_gui:mirror '${_annotationValue(m.id)}'"
          "='${_annotationValue(m.mirrorOf!)}'",
        );
        // The annotation above is a comment and harmless. The command below
        // is not: both names land inside a single-quoted `sh -c '…'`, where
        // one apostrophe ends the quoting and the rest of the string becomes
        // shell code. Connector names come from the kernel and never contain
        // one — but this config is a text file the user can edit, and a
        // mirror that silently does not start is a far better outcome than a
        // config that runs something.
        if (!isShellSafeCriteria(m.id) ||
            !isShellSafeCriteria(m.mirrorOf!)) {
          continue;
        }
        // No shell. This was `exec sh -c 'pgrep … | grep -qF … || wl-mirror … &'`
        // — a pipeline guarding against spawning a second wl-mirror for the
        // same destination. It never ran: kanshi hands exec lines to /bin/sh
        // after escaping only whitespace and quotes, so the `|`, `||` and `&`
        // stayed bare at the OUTER level and the shell tried to run the words
        // after them as commands. `grep -qF -- …: not found`, every time, and
        // wl-mirror was never started by kanshi at all.
        //
        // A guard cannot be expressed without shell operators, so it is gone
        // and the invocation is direct. Duplicates are handled where they can
        // actually be seen: MirrorRunner kills any externally-spawned mirror
        // for a destination before taking ownership of it.
        buffer.writeln(
          '    exec wl-mirror --scaling ${options.mirrorScaling} '
          '--fullscreen-output "${m.id}" "${m.mirrorOf}"',
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
      // An observed map only ever OVERLAYS the rule — it never replaces it.
      // Replacing it is what left workspaces 4..9 with no `workspace N
      // output X` line at all on a three-screen desk, because sway can only
      // report the workspaces that happen to exist. See [resolveWorkspaceMap].
      // Re-keyed onto this profile's own output ids before use. An observation
      // is recorded against the LIVE connector sway reported, while a profile
      // monitor may be keyed by its EDID descriptor — and an entry whose
      // target does not match a monitor here is dropped as unknown, which
      // would silently discard the very preference the mode exists to keep.
      final saved = rekeyWorkspaceMap(profile.workspaceMap, mons);
      if (saved != null && saved.isNotEmpty) {
        // Written whatever mode is active, because the annotation is STORAGE
        // and the mode is POLICY. It used to be written only while a map was
        // being followed, which meant switching to a pattern erased a
        // hand-made arrangement from the file — nine deliberate choices gone
        // for choosing "left to right" once, with no warning and no undo.
        // Now the pattern simply takes precedence while it is selected, and
        // "my own" still has something to come back to.
        //
        // Round-trip the RECORDED map, not the resolved one: writing the
        // resolved one back would make every setup look edited, and a rule
        // would be indistinguishable from a choice.
        for (final entry in (saved.keys.toList()..sort())) {
          buffer.writeln("    # kanshi_gui:ws '$entry'='${saved[entry]}'");
        }
      }
      // One `exec` per binding, and criteria chosen for a shell rather than
      // for kanshi's own parser. Both of those are corrections.
      //
      // This used to be a single `exec swaymsg "…"` holding all nine bindings
      // joined with `; `, plus a focus-and-move pass. kanshi 1.9 hands that
      // line to `/bin/sh` after re-escaping only whitespace and quotes, so the
      // semicolons separated shell commands: workspace 1 was bound and the
      // other eight were looked up as programs. And where a display's EDID
      // carried a bracket, the shell refused the whole line with a syntax
      // error and NOTHING was bound at all. Four releases of this feature
      // never did anything on a machine with kanshi 1.9.
      //
      // The focus-and-move half is gone from the config with it: it cannot be
      // expressed without a separator, it is the visible half, and both the
      // app and the helper service already do it properly over the IPC socket
      // where no shell is involved. What belongs in the file is the quiet half
      // — where each workspace lives — and that is what survives a cold boot.
      //
      // And every binding names every screen the workspace could live on
      // rather than the one this setup uses, because sway keeps only the
      // first binding it is given in a session: written per-setup, docking a
      // laptop left all nine workspaces pinned to the built-in panel for the
      // rest of the session, whatever the file said. See [workspaceHomes].
      final execs = buildWorkspaceConfigExecs(homes);
      for (final line in execs) {
        buffer.writeln('    exec $line');
      }
    }

    if (options.writeCurrentProfileMarker) {
      // The name went in raw between double quotes, and kanshi runs this line
      // through a shell — so a setup called `home $(rm -rf ~) office` executed
      // on every activation. Quoting cannot fix it: scfg eats our quotes
      // before the shell ever sees them. See [shellSafeText].
      //
      // The marker is a convenience for status bars and for the helper
      // service's tie-break, so a name reduced to its printable part is a
      // perfectly good marker; a name with nothing printable left gets no
      // line at all.
      final marker = shellSafeText(profile.name);
      if (marker.isNotEmpty) {
        buffer.writeln(
          '    exec echo "$marker" > ~/.current_kanshi_profile',
        );
      }
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

