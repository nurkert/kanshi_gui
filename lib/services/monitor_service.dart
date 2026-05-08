import 'dart:io';

import 'package:kanshi_gui/models/monitor_mode.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/services/backends/noop_backend.dart';
import 'package:kanshi_gui/services/backends/sway_backend.dart';
import 'package:kanshi_gui/services/backends/wlr_randr_backend.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/services/process_runner.dart';

/// Compositor-agnostic interface for talking to the running Wayland session.
/// Each implementation knows how to query the current outputs, toggle them,
/// switch modes and trigger a kanshi reload.
abstract class MonitorService {
  /// True when this backend can read live output state from the compositor.
  /// The [NoopBackend] returns false; the UI should disable apply actions.
  bool get isLive;

  /// Default write options for the kanshi config file when this backend is
  /// active. Sway-specific backends opt in to extras (workspace exec lines,
  /// `current_kanshi_profile` marker); compositor-neutral backends do not.
  KanshiWriteOptions get writeOptions;

  /// Human-readable label for the active backend (used in logs and UI).
  String get name;

  /// Whether this backend supports the "mirror onto another output"
  /// feature. Default: `false`. Sway-style backends override to `true`
  /// because mirroring on Sway 1.x is implemented via the external
  /// `wl-mirror` tool (see [MirrorRunner]); native `output mirror` IPC
  /// is not available on Sway 1.11. wlr-randr-based compositors and the
  /// noop backend leave this at `false` because there is no
  /// general-purpose mirror primitive on the wlroots CLI surface.
  bool get supportsMirror => false;

  Future<List<MonitorTileData>> getOutputs();

  Future<ProcessResult> enable(String outputId);
  Future<ProcessResult> disable(String outputId);
  Future<ProcessResult> setMode(String outputId, MonitorMode mode);

  /// Apply the full state of [target] (scale + mode + transform + position).
  Future<ProcessResult> apply(MonitorTileData target);

  /// Apply an arbitrary mode (used by the "Custom Mode" advanced flow).
  Future<ProcessResult> applyCustomMode(
    String outputId,
    double width,
    double height,
    double refresh,
  );

  /// Restart the compositor's kanshi profile-applier so a freshly-written
  /// config takes effect. Implementations may use systemd if available.
  Future<ProcessResult> restartCompositorProfileApply();

  /// Live stream of output state changes. Emits a fresh full output list
  /// each time the compositor reports a hotplug, a transform/mode change,
  /// or any other relevant output event. Backends that can't subscribe
  /// natively may fall back to polling; the [NoopBackend] returns
  /// [Stream.empty]. The returned [Stream] is broadcast — multiple
  /// listeners are safe.
  Stream<List<MonitorTileData>> watchOutputs();

  /// Spawn an on-screen banner that displays [label] (typically a single
  /// digit) on the physical [output]. Used by "Identify Displays" so the
  /// user can map a tile in the GUI to the actual screen in front of
  /// them. Returns a [ProcessStream] handle the caller kills when the
  /// banner should disappear, or `null` when this backend cannot target
  /// a specific output (e.g. wlr-randr — there is no portable on-screen
  /// notification primitive across compositors).
  ProcessStream? spawnIdentifyBanner(String output, String label) => null;

  /// Returns the live `workspace_number → output_name` mapping. Used by
  /// the controller's verify-and-fix path to compare the actual sway
  /// state against the desired ranks computed from the active profile.
  /// Backends that don't have a workspace concept return an empty map.
  Future<Map<int, String>> getWorkspaceOutputs() async => const {};

  /// Sends a pre-built compound swaymsg command (workspace
  /// declarations + move-to-output + final focus) to the compositor.
  /// Returns null when the backend can't speak swaymsg. The chain is
  /// the same one [KanshiConfigWriter.render] embeds via the kanshi
  /// `exec` line, but invoking it directly from the GUI lets us
  /// recover from cold-boot races where kanshi's exec ran against a
  /// not-yet-settled output set.
  Future<ProcessResult?> applyWorkspaceChain(String chain) async => null;

  /// Auto-detects the most appropriate backend for the current session.
  /// Order: Sway → wlr-randr → noop.
  ///
  /// Sway requires a *running* sway IPC socket (`SWAYSOCK` env var
  /// pointing at an existing path). Earlier releases also accepted
  /// "swaymsg is in PATH" as a Sway signal, but that misfires on
  /// non-sway compositors where users keep `swaymsg` installed for
  /// tooling/config-interop reasons (e.g. niri, river). Without a
  /// running sway, every IPC call would fail and the GUI would be
  /// effectively broken — the wlr-randr fallback at least gives them
  /// basic monitor management, since most non-sway wlroots-style
  /// compositors (and niri via Smithay) speak the wlr-output-management
  /// protocol that wlr-randr uses.
  ///
  /// [environment] and [socketExists] are injection points for tests
  /// — defaults read the live process environment and check the real
  /// filesystem.
  static Future<MonitorService> detect({
    ProcessRunner? runner,
    Map<String, String>? environment,
    Future<bool> Function(String path)? socketExists,
  }) async {
    final r = runner ?? const DefaultProcessRunner();
    final env = environment ?? Platform.environment;
    final swaysock = env['SWAYSOCK'];
    final exists = socketExists ?? (p) => File(p).exists();
    final hasLiveSway = swaysock != null &&
        swaysock.isNotEmpty &&
        await exists(swaysock);
    if (hasLiveSway && await r.exists('swaymsg')) {
      return SwayBackend(runner: r);
    }
    if (await r.exists('wlr-randr')) {
      return WlrRandrBackend(runner: r);
    }
    return const NoopBackend();
  }
}
