import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kanshi_gui/models/monitor_mode.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/services/monitor_service.dart';
import 'package:kanshi_gui/services/process_runner.dart';

/// Compositor-agnostic backend that talks to the wlroots-based session via
/// `wlr-randr --json`. Suitable for Hyprland, Wayfire and other wlroots
/// compositors, including Sway when `swaymsg` is unavailable.
///
/// Workspace-exec injection is *not* used here — the kanshi config stays
/// compositor-neutral.
class WlrRandrBackend implements MonitorService {
  final ProcessRunner _runner;

  WlrRandrBackend({ProcessRunner? runner})
      : _runner = runner ?? const DefaultProcessRunner();

  @override
  bool get isLive => true;

  @override
  String get name => 'wlr-randr';

  @override
  bool get supportsMirror => false;

  @override
  KanshiWriteOptions get writeOptions => KanshiWriteOptions.neutral;

  @override
  Future<List<MonitorTileData>> getOutputs() async {
    final result = await _runner.run('wlr-randr', ['--json']);
    if (result.exitCode != 0) {
      throw Exception('wlr-randr failed: ${result.stderr}');
    }
    final raw = jsonDecode(result.stdout as String);
    final outputs = (raw is List) ? raw : <dynamic>[];
    return outputs
        .map((o) => _parseOutput(o as Map<String, dynamic>))
        .toList();
  }

  MonitorTileData _parseOutput(Map<String, dynamic> output) {
    final name = (output['name'] ?? '').toString().trim();
    final make = (output['make'] ?? '').toString().trim();
    final model = (output['model'] ?? '').toString().trim();
    final serial = (output['serial'] ?? '').toString().trim();
    final fullName =
        '$make $model $serial'.replaceAll(RegExp(r'\s+'), ' ').trim();
    final enabled = output['enabled'] == true;

    final modesRaw = (output['modes'] as List?)?.cast<Map<String, dynamic>>()
        ?? const <Map<String, dynamic>>[];
    final modes = modesRaw
        .map((m) => MonitorMode(
              width: (m['width'] as num).toDouble(),
              height: (m['height'] as num).toDouble(),
              refresh: (m['refresh'] as num).toDouble(),
            ))
        .toList();

    final current = modesRaw.firstWhere(
      (m) => m['current'] == true,
      orElse: () =>
          modesRaw.isNotEmpty ? modesRaw.first : <String, dynamic>{},
    );
    final baseW = (current['width'] as num?)?.toDouble() ?? 1920.0;
    final baseH = (current['height'] as num?)?.toDouble() ?? 1080.0;
    final refresh = (current['refresh'] as num?)?.toDouble() ?? 60.0;

    final position = (output['position'] as Map<String, dynamic>?) ??
        const {'x': 0, 'y': 0};
    final transform = (output['transform'] ?? 'normal').toString();
    final rotation = switch (transform) {
      '90' || 'flipped-90' => 90,
      '180' || 'flipped-180' => 180,
      '270' || 'flipped-270' => 270,
      _ => 0,
    };
    final scale = (output['scale'] as num?)?.toDouble() ?? 1.0;

    // wlr-randr reports the mode in its native (unrotated) orientation;
    // the rest of the app stores width/height already rotated to match
    // the visible rect.
    final width = (rotation % 180 == 0) ? baseW : baseH;
    final height = (rotation % 180 == 0) ? baseH : baseW;
    final orientation = (rotation % 180 == 0) ? 'landscape' : 'portrait';

    return MonitorTileData(
      id: name.isNotEmpty ? name : fullName,
      manufacturer: fullName.isNotEmpty ? fullName : name,
      x: (position['x'] as num).toDouble(),
      y: (position['y'] as num).toDouble(),
      width: width,
      height: height,
      scale: scale,
      rotation: rotation,
      refresh: refresh,
      resolution: '${baseW.toInt()}x${baseH.toInt()}',
      orientation: orientation,
      modes: modes,
      enabled: enabled,
    );
  }

  @override
  Future<ProcessResult> enable(String outputId) {
    return _runner.run('wlr-randr', ['--output', outputId, '--on']);
  }

  @override
  Future<ProcessResult> disable(String outputId) {
    return _runner.run('wlr-randr', ['--output', outputId, '--off']);
  }

  @override
  Future<ProcessResult> setMode(String outputId, MonitorMode mode) {
    return _runner.run('wlr-randr', [
      '--output',
      outputId,
      '--mode',
      '${mode.width.toInt()}x${mode.height.toInt()}'
          '@${KanshiConfigWriter.formatHz(mode.refresh)}Hz',
    ]);
  }

  @override
  Future<ProcessResult> apply(MonitorTileData target) {
    final transform = switch (target.rotation % 360) {
      90 => '90',
      180 => '180',
      270 => '270',
      _ => 'normal',
    };
    final mode = _modeMatchingTarget(target) ?? _bestMode(target);
    return _runner.run('wlr-randr', [
      '--output',
      target.id,
      '--on',
      '--mode',
      '${mode.width.toInt()}x${mode.height.toInt()}'
          '@${KanshiConfigWriter.formatHz(mode.refresh)}Hz',
      '--scale',
      target.scale.toStringAsFixed(2),
      '--transform',
      transform,
      '--pos',
      '${target.x.toInt()},${target.y.toInt()}',
    ]);
  }

  @override
  Future<ProcessResult> applyCustomMode(
    String outputId,
    double width,
    double height,
    double refresh,
  ) {
    return _runner.run('wlr-randr', [
      '--output',
      outputId,
      '--mode',
      '${width.toInt()}x${height.toInt()}'
          '@${KanshiConfigWriter.formatHz(refresh)}Hz',
    ]);
  }

  @override
  Stream<List<MonitorTileData>> watchOutputs() {
    // wlr-randr has no native subscribe. Poll every 2 s — coarser than the
    // Sway path but good enough for hot-plug awareness on Hyprland/Wayfire.
    final controller = StreamController<List<MonitorTileData>>.broadcast();
    Timer? timer;
    String? lastSig;
    Future<void> tick() async {
      try {
        final outs = await getOutputs();
        final sig = outs
            .map((o) => '${o.id}:${o.enabled}:${o.width}x${o.height}')
            .join('|');
        if (sig != lastSig) {
          lastSig = sig;
          controller.add(outs);
        }
      } catch (_) {/* ignore transient errors */}
    }
    controller.onListen = () {
      tick();
      timer = Timer.periodic(const Duration(seconds: 2), (_) => tick());
    };
    controller.onCancel = () {
      timer?.cancel();
    };
    return controller.stream;
  }

  @override
  Future<ProcessResult> restartCompositorProfileApply() async {
    if (await _runner.exists('kanshictl')) {
      final pgrep = await _runner.run('pgrep', ['-x', 'kanshi']);
      if (pgrep.exitCode == 0) {
        final r = await _runner.run('kanshictl', ['reload']);
        if (r.exitCode == 0) return r;
      }
    }
    final check = await _runner.run('systemctl', [
      '--user',
      'is-active',
      '--quiet',
      'kanshi.service',
    ]);
    if (check.exitCode == 0) {
      return _runner
          .run('systemctl', ['--user', 'restart', 'kanshi.service']);
    }
    return _runner.run('bash', [
      '-c',
      'pkill -x kanshi; for i in 1 2 3 4 5; do '
          'pgrep -x kanshi >/dev/null || break; sleep 0.1; done; '
          'setsid kanshi -c \$HOME/.config/kanshi/config '
          '>/tmp/kanshi_gui.log 2>&1 &'
    ]);
  }

  MonitorMode? _modeMatchingTarget(MonitorTileData m) {
    if (m.modes.isEmpty) {
      return MonitorMode(
        width: m.width,
        height: m.height,
        refresh: m.refresh > 0 ? m.refresh : 60.0,
      );
    }
    final landscapeW = m.rotation % 180 == 0 ? m.width : m.height;
    final landscapeH = m.rotation % 180 == 0 ? m.height : m.width;
    for (final mode in m.modes) {
      if (mode.width.toInt() == landscapeW.toInt() &&
          mode.height.toInt() == landscapeH.toInt() &&
          (mode.refresh - m.refresh).abs() < 0.5) {
        return mode;
      }
    }
    return null;
  }

  MonitorMode _bestMode(MonitorTileData m) {
    final sorted = [...m.modes]..sort((a, b) {
        final areaA = a.width * a.height;
        final areaB = b.width * b.height;
        if (areaA != areaB) return areaB.compareTo(areaA);
        return b.refresh.compareTo(a.refresh);
      });
    return sorted.first;
  }

  @override
  ProcessStream? spawnIdentifyBanner(String output, String label) {
    // No portable on-screen-banner-on-output primitive on the wlr-randr
    // CLI surface — leave the GUI's in-canvas number overlay as the only
    // identify aid for non-Sway compositors.
    return null;
  }

  @override
  Future<Map<int, String>> getWorkspaceOutputs() async => const {};

  @override
  Future<ProcessResult?> applyWorkspaceChain(String chain) async => null;
}
