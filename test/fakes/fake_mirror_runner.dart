import 'package:flutter/foundation.dart';
import 'package:kanshi_gui/services/mirror_runner.dart';

/// Test double for [MirrorRunner] that records start/stop calls without
/// actually spawning wl-mirror. Lets controller tests assert the desired
/// reconcile-diff behaviour without forking real processes.
class FakeMirrorRunner extends ChangeNotifier implements MirrorRunner {
  bool available = true;
  final List<String> calls = [];
  final Map<String, String> _active = {}; // dst -> src
  final Set<String> _failed = {};

  @override
  Future<bool> isAvailable() async => available;

  @override
  Set<String> get activeDestinations => _active.keys.toSet();

  @override
  String? mirrorSourceFor(String dstId) => _active[dstId];

  @override
  Set<String> get failedDestinations => Set.unmodifiable(_failed);

  @override
  void clearFailure(String dstId) {
    if (_failed.remove(dstId)) notifyListeners();
  }

  @override
  Future<void> start(String srcId, String dstId) async {
    calls.add('start $srcId -> $dstId');
    _active[dstId] = srcId;
    _failed.remove(dstId);
    notifyListeners();
  }

  @override
  Future<void> stop(String dstId) async {
    if (_active.remove(dstId) != null) {
      calls.add('stop $dstId');
      notifyListeners();
    }
  }

  @override
  Future<void> stopAll() async {
    final dsts = _active.keys.toList(growable: false);
    for (final d in dsts) {
      await stop(d);
    }
  }
}
