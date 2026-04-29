// Headless smoketest: instantiates each MonitorService backend against the
// running compositor and prints the parsed outputs. Useful when bringing up
// the app on a new host (or compositor) without opening the GUI.
//
// Run with:  dart run tool/probe_outputs.dart

import 'dart:io';

import 'package:kanshi_gui/services/backends/sway_backend.dart';
import 'package:kanshi_gui/services/backends/wlr_randr_backend.dart';
import 'package:kanshi_gui/services/monitor_service.dart';
import 'package:kanshi_gui/services/process_runner.dart';

Future<void> main() async {
  final runner = const DefaultProcessRunner();

  stdout.writeln('═══ MonitorService.detect() ═══');
  final detected = await MonitorService.detect(runner: runner);
  stdout.writeln('Selected backend: ${detected.name} '
      '(isLive=${detected.isLive}, '
      'injectSwayWorkspaceExec=${detected.writeOptions.injectSwayWorkspaceExec})');

  await _probe('SwayBackend', SwayBackend(runner: runner));
  await _probe('WlrRandrBackend', WlrRandrBackend(runner: runner));
}

Future<void> _probe(String label, MonitorService backend) async {
  stdout.writeln('');
  stdout.writeln('═══ $label ═══');
  try {
    final outputs = await backend.getOutputs();
    stdout.writeln('Got ${outputs.length} output(s):');
    for (final m in outputs) {
      stdout.writeln('  - id=${m.id}');
      stdout.writeln('    manufacturer=${m.manufacturer}');
      stdout.writeln('    pos=(${m.x.toInt()},${m.y.toInt()}) '
          'size=${m.width.toInt()}x${m.height.toInt()} '
          'scale=${m.scale.toStringAsFixed(2)} '
          'rot=${m.rotation}° refresh=${m.refresh}Hz '
          'enabled=${m.enabled} modes=${m.modes.length}');
    }
  } catch (e, st) {
    stdout.writeln('ERROR: $e');
    stdout.writeln(st.toString().split('\n').take(5).join('\n'));
  }
}
