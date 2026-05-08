import 'dart:async';
import 'dart:io';

import 'package:kanshi_gui/models/monitor_mode.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/services/monitor_service.dart';
import 'package:kanshi_gui/services/process_runner.dart';

/// Test double that records every backend call and returns canned values.
/// Lets us drive [KanshiController] through its scenarios without touching
/// the host's compositor.
class FakeMonitorService implements MonitorService {
  @override
  bool isLive;

  @override
  String get name => 'fake';

  @override
  bool supportsMirror;

  @override
  KanshiWriteOptions writeOptions;

  List<MonitorTileData> outputs;
  ProcessResult enableResult;
  ProcessResult disableResult;
  ProcessResult applyResult;
  ProcessResult setModeResult;
  ProcessResult applyCustomResult;
  ProcessResult restartResult;

  final List<String> calls = [];

  FakeMonitorService({
    this.isLive = true,
    this.supportsMirror = false,
    this.writeOptions = KanshiWriteOptions.neutral,
    List<MonitorTileData>? outputs,
    ProcessResult? enableResult,
    ProcessResult? disableResult,
    ProcessResult? applyResult,
    ProcessResult? setModeResult,
    ProcessResult? applyCustomResult,
    ProcessResult? restartResult,
  })  : outputs = outputs ?? [],
        enableResult = enableResult ?? ProcessResult(0, 0, '', ''),
        disableResult = disableResult ?? ProcessResult(0, 0, '', ''),
        applyResult = applyResult ?? ProcessResult(0, 0, '', ''),
        setModeResult = setModeResult ?? ProcessResult(0, 0, '', ''),
        applyCustomResult =
            applyCustomResult ?? ProcessResult(0, 0, '', ''),
        restartResult = restartResult ?? ProcessResult(0, 0, '', '');

  @override
  Future<List<MonitorTileData>> getOutputs() async {
    calls.add('getOutputs');
    return outputs;
  }

  @override
  Future<ProcessResult> enable(String outputId) async {
    calls.add('enable $outputId');
    if (enableResult.exitCode == 0) _setEnabled(outputId, true);
    return enableResult;
  }

  @override
  Future<ProcessResult> disable(String outputId) async {
    calls.add('disable $outputId');
    if (disableResult.exitCode == 0) _setEnabled(outputId, false);
    return disableResult;
  }

  void _setEnabled(String id, bool enabled) {
    outputs = [
      for (final m in outputs)
        if (m.id == id) m.copyWith(enabled: enabled) else m,
    ];
  }

  @override
  Future<ProcessResult> setMode(String outputId, MonitorMode mode) async {
    calls.add(
        'setMode $outputId ${mode.width.toInt()}x${mode.height.toInt()}@${mode.refresh}');
    return setModeResult;
  }

  @override
  Future<ProcessResult> apply(MonitorTileData target) async {
    calls.add('apply ${target.id}');
    return applyResult;
  }

  @override
  Future<ProcessResult> applyCustomMode(
      String outputId, double width, double height, double refresh) async {
    calls.add(
        'applyCustomMode $outputId ${width.toInt()}x${height.toInt()}@$refresh');
    return applyCustomResult;
  }

  @override
  Future<ProcessResult> restartCompositorProfileApply() async {
    calls.add('restart');
    return restartResult;
  }

  final StreamController<List<MonitorTileData>> _watchController =
      StreamController<List<MonitorTileData>>.broadcast();

  /// Tests push a new outputs list here to simulate hot-plug.
  void emitOutputs(List<MonitorTileData> next) {
    outputs = next;
    _watchController.add(next);
  }

  @override
  Stream<List<MonitorTileData>> watchOutputs() => _watchController.stream;

  /// Per-output identify-banner spawn calls recorded for tests. Set
  /// [identifyBannerSupported] to true to make this fake act like Sway and
  /// return a fake [ProcessStream]; otherwise it returns null so the
  /// controller falls back to the GUI-only overlay path.
  bool identifyBannerSupported = false;
  final List<List<String>> identifyBannerCalls = [];

  @override
  ProcessStream? spawnIdentifyBanner(String output, String label) {
    identifyBannerCalls.add([output, label]);
    if (!identifyBannerSupported) return null;
    final ctl = StreamController<String>.broadcast();
    return ProcessStream(
      lines: ctl.stream,
      kill: () async {
        if (!ctl.isClosed) await ctl.close();
      },
      pid: Future.value(null),
    );
  }

  /// Tests seed this with the live `workspace_num → output_name` mapping
  /// they want [getWorkspaceOutputs] to return; defaults to empty so
  /// existing tests don't break.
  Map<int, String> workspaceOutputs = const {};
  final List<String> workspaceChainCalls = [];

  @override
  Future<Map<int, String>> getWorkspaceOutputs() async {
    calls.add('getWorkspaceOutputs');
    return workspaceOutputs;
  }

  @override
  Future<ProcessResult?> applyWorkspaceChain(String chain) async {
    calls.add('applyWorkspaceChain');
    workspaceChainCalls.add(chain);
    return ProcessResult(0, 0, '', '');
  }
}
