import 'dart:async';
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
  bool get supportsMirror => true;

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

    final baseW = (currentMode?['width'] as num?)?.toDouble() ?? 1920.0;
    final baseH = (currentMode?['height'] as num?)?.toDouble() ?? 1080.0;
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
    // Sway IPC reports current_mode in the panel's native (unrotated)
    // orientation, but the rest of the app stores width/height already
    // rotated to match the visible rect. Swap on portrait transforms so
    // the layout renders the tile vertically.
    final width = (rotation % 180 == 0) ? baseW : baseH;
    final height = (rotation % 180 == 0) ? baseH : baseW;
    final orientation = (rotation % 180 == 0) ? 'landscape' : 'portrait';

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
      resolution: '${baseW.toInt()}x${baseH.toInt()}',
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
    final mode = _modeMatchingTarget(target) ?? _bestMode(target);
    // NB: swaymsg's `output … position` IPC takes two separate arguments
    // (X Y), unlike the kanshi config syntax which is comma-joined ("X,Y").
    // Leading `--` stops swaymsg's getopt from parsing negative coordinates
    // (e.g. a monitor stacked above origin yields position "-1440") as flags.
    return _runner.run(bin, [
      '--',
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
      '${target.x.toInt()}',
      '${target.y.toInt()}',
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
  ProcessStream? spawnIdentifyBanner(String output, String label) {
    // swaynag is part of sway: a colored, dismissable notification bar on
    // a chosen output. We crank the font way up so a single digit
    // dominates the bar and is unmistakable from across the room.
    return _runner.stream('swaynag', [
      '-o', output,
      '-m', label,
      '-f', 'Sans Bold 200',
      '-t', 'warning',
    ]);
  }

  @override
  Future<Map<int, String>> getWorkspaceOutputs() async {
    final bin = await _binary();
    final result = await _runner.run(bin, ['-t', 'get_workspaces']);
    if (result.exitCode != 0) {
      throw Exception('swaymsg get_workspaces failed: ${result.stderr}');
    }
    final list = jsonDecode(result.stdout as String) as List;
    final out = <int, String>{};
    for (final raw in list) {
      final ws = raw as Map<String, dynamic>;
      // `num` is -1 for workspaces with non-numeric names; only the
      // numeric slots are addressable via `workspace number N`, so the
      // verify-and-fix path only cares about those.
      final num = ws['num'];
      if (num is! int || num < 1) continue;
      final output = (ws['output'] ?? '').toString();
      if (output.isEmpty) continue;
      out[num] = output;
    }
    return out;
  }

  @override
  Future<ProcessResult?> applyWorkspaceChain(String chain) async {
    final bin = await _binary();
    // Pass the chain as a single argument — swaymsg joins arguments
    // with a space anyway, but a single-arg call keeps the literal
    // semicolon separators intact and skips any shell quoting subtlety.
    return _runner.run(bin, [chain]);
  }

  @override
  Stream<List<MonitorTileData>> watchOutputs() {
    final controller = StreamController<List<MonitorTileData>>.broadcast();
    ProcessStream? sub;
    () async {
      final bin = await _binary();
      sub = _runner.stream(bin, ['-t', 'subscribe', '-m', '["output"]']);
      // Emit the current state immediately so subscribers don't have to
      // wait for the first event.
      try {
        controller.add(await getOutputs());
      } catch (_) {/* ignore — initial state may not be available yet */}
      sub!.lines.listen(
        (_) async {
          try {
            controller.add(await getOutputs());
          } catch (_) {/* swallow refresh errors */}
        },
        onDone: () => controller.close(),
      );
    }();
    controller.onCancel = () async {
      await sub?.kill();
    };
    return controller.stream;
  }

  @override
  Future<ProcessResult> restartCompositorProfileApply() async {
    // Prefer kanshictl if available — it asks the running kanshi to reload
    // its config without a full process restart, avoiding screen flicker.
    if (await _runner.exists('kanshictl')) {
      final pgrep = await _runner.run('pgrep', ['-x', 'kanshi']);
      if (pgrep.exitCode == 0) {
        final r = await _runner.run('kanshictl', ['reload']);
        if (r.exitCode == 0) return r;
        // Fall through to systemd / pkill on failure.
      }
    }
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

  /// Returns the mode in [m.modes] that matches the tile's nominal
  /// (unrotated) width/height/refresh — or null if none match. Prefer this
  /// over [_bestMode] when applying state we already know about, otherwise
  /// the user gets a surprise mode bump.
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
}
