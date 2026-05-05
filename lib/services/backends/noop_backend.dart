import 'dart:io';

import 'package:kanshi_gui/models/monitor_mode.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/services/monitor_service.dart';
import 'package:kanshi_gui/services/process_runner.dart';

/// Fallback backend used when no Wayland output tool is detected. The UI
/// remains usable as an offline profile editor, but live-apply actions
/// surface as a friendly "no-op" result so callers can show a clear notice.
class NoopBackend implements MonitorService {
  const NoopBackend();

  @override
  bool get isLive => false;

  @override
  String get name => 'noop';

  @override
  bool get supportsMirror => false;

  @override
  KanshiWriteOptions get writeOptions => KanshiWriteOptions.neutral;

  ProcessResult _unsupported() => ProcessResult(
        0,
        1,
        '',
        'No Wayland output tool detected (install swaymsg or wlr-randr).',
      );

  @override
  Future<List<MonitorTileData>> getOutputs() async => const [];

  @override
  Future<ProcessResult> enable(String outputId) async => _unsupported();

  @override
  Future<ProcessResult> disable(String outputId) async => _unsupported();

  @override
  Future<ProcessResult> setMode(String outputId, MonitorMode mode) async =>
      _unsupported();

  @override
  Future<ProcessResult> apply(MonitorTileData target) async => _unsupported();

  @override
  Future<ProcessResult> applyCustomMode(
    String outputId,
    double width,
    double height,
    double refresh,
  ) async =>
      _unsupported();

  @override
  Future<ProcessResult> restartCompositorProfileApply() async => _unsupported();

  @override
  Stream<List<MonitorTileData>> watchOutputs() => const Stream.empty();

  @override
  ProcessStream? spawnIdentifyBanner(String output, String label) => null;
}
