import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kanshi_gui/domain/output_identity.dart';
import 'package:kanshi_gui/models/monitor_mode.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/services/monitor_service.dart';
import 'package:kanshi_gui/services/kanshi_daemon.dart';
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
    // The criteria kanshi matches on, built from the RAW fields — `clean`
    // above strips "Unknown" for the display label, but kanshi(5) requires
    // the missing field to be present as the literal string "Unknown".
    final descriptor = composeKanshiDescriptor(
      make: (output['make'] ?? '').toString(),
      model: (output['model'] ?? '').toString(),
      serial: (output['serial'] ?? '').toString(),
    );

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
      edidDescriptor: descriptor ?? '',
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
  ProcessStream? spawnSafetyPrompt(String output, String message) {
    // Normal reading size, unlike the identify banner's 200pt digit: this one
    // is meant to be read, not spotted from across the room.
    return _runner.stream('swaynag', [
      '-o', output,
      '-m', message,
      '-f', 'Sans Bold 16',
      '-t', 'warning',
    ]);
  }

  @override
  Future<int?> focusedWorkspace() async {
    try {
      final bin = await _binary();
      final r = await _runner.run(bin, ['-t', 'get_workspaces']);
      if (r.exitCode != 0) return null;
      for (final raw in jsonDecode(r.stdout as String) as List) {
        final ws = raw as Map<String, dynamic>;
        if (ws['focused'] == true) {
          final n = ws['num'];
          return n is int && n > 0 ? n : null;
        }
      }
    } catch (_) {/* never guess where the user is */}
    return null;
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
  Future<void> evacuateOutputWorkspaces(
    String dstId,
    List<String> targets,
  ) async {
    if (targets.isEmpty) return;
    final bin = await _binary();
    final result = await _runner.run(bin, ['-t', 'get_workspaces']);
    if (result.exitCode != 0) return;
    final list = jsonDecode(result.stdout as String) as List;
    final parts = <String>[];
    var i = 0;
    String? refocus;
    for (final raw in list) {
      final ws = raw as Map<String, dynamic>;
      final output = (ws['output'] ?? '').toString();
      final num = ws['num'];
      final name = (ws['name'] ?? '').toString();
      // Remember whatever the user is currently looking at so we can
      // restore focus once the moves are done — without this the chain
      // would leave focus on whichever ws got moved last.
      if (ws['focused'] == true) {
        refocus = (num is int && num >= 1)
            ? 'workspace number $num'
            : (name.isNotEmpty ? 'workspace ${_quoteWsName(name)}' : null);
      }
      if (output != dstId) continue;
      if (name.isEmpty && (num is! int || num < 1)) continue;
      final target = targets[i % targets.length];
      i++;
      // Prefer `workspace number N` for numeric slots so we hit the
      // canonical slot regardless of any free-form name (`1: code`).
      parts.add((num is int && num >= 1)
          ? 'workspace number $num'
          : 'workspace ${_quoteWsName(name)}');
      parts.add("move workspace to output '$target'");
    }
    if (parts.isEmpty) return;
    if (refocus != null) parts.add(refocus);
    await _runner.run(bin, [parts.join('; ')]);
  }

  @override
  Future<bool> waitForOutputClear(
    String dstId, {
    Duration timeout = const Duration(milliseconds: 400),
  }) async {
    final bin = await _binary();
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final r = await _runner.run(bin, ['-t', 'get_workspaces']);
        if (r.exitCode == 0) {
          final list = jsonDecode(r.stdout as String) as List;
          final any = list.any((raw) {
            final ws = raw as Map<String, dynamic>;
            return (ws['output'] ?? '').toString() == dstId;
          });
          if (!any) return true;
        }
      } catch (_) {/* swallow and retry */}
      await Future.delayed(const Duration(milliseconds: 50));
    }
    return false;
  }

  /// Wraps a workspace name in double quotes for swaymsg, escaping
  /// embedded `"` and `\` so a free-form name survives the IPC parser
  /// (e.g. `1: code "main"`).
  static String _quoteWsName(String name) {
    final escaped = name.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    return '"$escaped"';
  }

  /// Every long-lived subprocess this backend has started and not yet reaped.
  final Set<ProcessStream> _watchers = {};

  @override
  Future<void> shutdown() async {
    // Killing on the way out is the only thing that reliably reaps these:
    // `onCancel` below fires when a listener goes away, and closing the
    // window is not that — the process just ends. See [MonitorService.shutdown].
    final open = _watchers.toList();
    _watchers.clear();
    for (final w in open) {
      try {
        await w.kill();
      } catch (_) {/* already gone */}
    }
  }

  @override
  Stream<List<MonitorTileData>> watchOutputs() {
    final controller = StreamController<List<MonitorTileData>>.broadcast();
    ProcessStream? sub;
    () async {
      final bin = await _binary();
      sub = _runner.stream(bin, ['-t', 'subscribe', '-m', '["output"]']);
      _watchers.add(sub!);
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
      final s = sub;
      if (s == null) return;
      _watchers.remove(s);
      await s.kill();
    };
    return controller.stream;
  }

  @override
  /// Delegates to [KanshiDaemon]: reloading kanshi has nothing to do with
  /// which compositor is underneath, and this chain used to be duplicated
  /// verbatim across two backends.
  Future<ProcessResult> restartCompositorProfileApply() =>
      KanshiDaemon(_runner).reload();

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
