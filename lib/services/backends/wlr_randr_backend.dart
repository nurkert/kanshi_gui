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
    final width = (current['width'] as num?)?.toDouble() ?? 1920.0;
    final height = (current['height'] as num?)?.toDouble() ?? 1080.0;
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

    final orientation = (rotation % 180 == 0)
        ? (width >= height ? 'landscape' : 'portrait')
        : (width >= height ? 'portrait' : 'landscape');

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
      resolution: '${width.toInt()}x${height.toInt()}',
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
    final mode = target.modes.isNotEmpty
        ? _bestMode(target)
        : MonitorMode(
            width: target.width,
            height: target.height,
            refresh: target.refresh > 0 ? target.refresh : 60.0,
          );
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
  Future<ProcessResult> restartCompositorProfileApply() async {
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

  MonitorMode _bestMode(MonitorTileData m) {
    final sorted = [...m.modes]..sort((a, b) {
        final areaA = a.width * a.height;
        final areaB = b.width * b.height;
        if (areaA != areaB) return areaB.compareTo(areaA);
        return b.refresh.compareTo(a.refresh);
      });
    return sorted.first;
  }
}
