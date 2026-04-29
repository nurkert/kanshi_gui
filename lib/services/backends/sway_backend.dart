import 'dart:convert';
import 'dart:io';

import 'package:kanshi_gui/models/monitor_mode.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/services/monitor_service.dart';
import 'package:kanshi_gui/services/process_runner.dart';

/// MonitorService implementation backed by `swaymsg` (Sway compositor).
class SwayBackend implements MonitorService {
  final ProcessRunner _runner;
  String? _resolvedBinary;

  SwayBackend({ProcessRunner? runner})
      : _runner = runner ?? const DefaultProcessRunner();

  @override
  bool get isLive => true;

  @override
  String get name => 'sway';

  @override
  KanshiWriteOptions get writeOptions => KanshiWriteOptions.swayDefaults;

  Future<String> _binary() async {
    if (_resolvedBinary != null) return _resolvedBinary!;
    if (await _runner.exists('swaymsg')) {
      _resolvedBinary = 'swaymsg';
    } else if (await _runner.exists('/usr/bin/swaymsg')) {
      _resolvedBinary = '/usr/bin/swaymsg';
    } else if (await _runner.exists('/usr/local/bin/swaymsg')) {
      _resolvedBinary = '/usr/local/bin/swaymsg';
    } else {
      _resolvedBinary = 'swaymsg';
    }
    return _resolvedBinary!;
  }

  @override
  Future<List<MonitorTileData>> getOutputs() async {
    final bin = await _binary();
    final result = await _runner.run(bin, ['-t', 'get_outputs']);
    if (result.exitCode != 0) {
      throw Exception('swaymsg failed: ${result.stderr}');
    }
    final outputs = jsonDecode(result.stdout as String) as List;
    return outputs.map(_parseOutput).toList();
  }

  MonitorTileData _parseOutput(dynamic raw) {
    final output = raw as Map<String, dynamic>;
    final isActive = output['active'] == true;
    // Drop missing or "Unknown" fields entirely instead of stamping them
    // into the manufacturer string — keeps display labels clean for
    // embedded panels (Sway emits the literal string "Unknown" when EDID
    // does not provide a serial).
    String clean(Object? raw) {
      final s = (raw ?? '').toString().trim();
      return s.toLowerCase() == 'unknown' ? '' : s;
    }
    final make = clean(output['make']);
    final model = clean(output['model']);
    final serial = clean(output['serial']);
    final fullName =
        [make, model, serial].where((s) => s.isNotEmpty).join(' ').trim();
    final outputName = (output['name'] ?? fullName).toString().trim();

    final modeMaps = (output['modes'] as List).cast<Map<String, dynamic>>();
    final modes = modeMaps
        .map((m) => MonitorMode(
              width: (m['width'] as num).toDouble(),
              height: (m['height'] as num).toDouble(),
              refresh: ((m['refresh'] as num).toDouble() / 1000.0),
            ))
        .toList();

    Map<String, dynamic>? currentMode =
        output['current_mode'] as Map<String, dynamic>?;
    if (currentMode == null && modeMaps.isNotEmpty) {
      currentMode = modeMaps.reduce((a, b) {
        final aPx = a['width'] * a['height'];
        final bPx = b['width'] * b['height'];
        if (aPx != bPx) return aPx > bPx ? a : b;
        return (a['refresh'] > b['refresh']) ? a : b;
      });
    }

    final width = (currentMode?['width'] as num?)?.toDouble() ?? 1920.0;
    final height = (currentMode?['height'] as num?)?.toDouble() ?? 1080.0;
    final refresh =
        ((currentMode?['refresh'] as num?)?.toDouble() ?? 60000.0) / 1000.0;
    final scale = (output['scale'] as num?)?.toDouble() ?? 1.0;
    final transform = (output['transform'] ?? 'normal').toString();
    final rotation = switch (transform) {
      '90' || 'flipped-90' => 90,
      '180' || 'flipped-180' => 180,
      '270' || 'flipped-270' => 270,
      _ => 0,
    };
    final orientation = (rotation % 180 == 0)
        ? (width >= height ? 'landscape' : 'portrait')
        : (width >= height ? 'portrait' : 'landscape');

    return MonitorTileData(
      id: outputName,
      manufacturer: fullName,
      x: (output['rect']['x'] as num).toDouble(),
      y: (output['rect']['y'] as num).toDouble(),
      width: width,
      height: height,
      scale: scale,
      rotation: rotation,
      refresh: refresh,
      resolution: '${width.toInt()}x${height.toInt()}',
      orientation: orientation,
      modes: modes,
      enabled: isActive,
    );
  }

  @override
  Future<ProcessResult> enable(String outputId) async {
    final bin = await _binary();
    return _runner.run(bin, ['output', outputId, 'enable']);
  }

  @override
  Future<ProcessResult> disable(String outputId) async {
    final bin = await _binary();
    return _runner.run(bin, ['output', outputId, 'disable']);
  }

  @override
  Future<ProcessResult> setMode(String outputId, MonitorMode mode) async {
    final bin = await _binary();
    return _runner.run(bin, [
      'output',
      outputId,
      'mode',
      '${mode.width.toInt()}x${mode.height.toInt()}'
          '@${KanshiConfigWriter.formatHz(mode.refresh)}Hz',
    ]);
  }

  @override
  Future<ProcessResult> apply(MonitorTileData target) async {
    final bin = await _binary();
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
    return _runner.run(bin, [
      'output',
      target.id,
      'scale',
      target.scale.toStringAsFixed(2),
      'mode',
      '${mode.width.toInt()}x${mode.height.toInt()}'
          '@${KanshiConfigWriter.formatHz(mode.refresh)}Hz',
      'transform',
      transform,
      'position',
      '${target.x.toInt()},${target.y.toInt()}',
    ]);
  }

  @override
  Future<ProcessResult> applyCustomMode(
    String outputId,
    double width,
    double height,
    double refresh,
  ) async {
    final bin = await _binary();
    return _runner.run(bin, [
      'output',
      outputId,
      'mode',
      '${width.toInt()}x${height.toInt()}'
          '@${KanshiConfigWriter.formatHz(refresh)}Hz',
    ]);
  }

  @override
  Future<ProcessResult> restartCompositorProfileApply() async {
    // Prefer the systemd user unit if it's active.
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
    // Fallback: kill + setsid restart, with a brief settle delay.
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
