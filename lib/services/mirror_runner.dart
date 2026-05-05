import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:kanshi_gui/services/process_runner.dart';

/// Manages a fleet of `wl-mirror` background processes — one per
/// destination output that mirrors another. The runner keeps each spawn
/// alive across crashes / accidental window-closures by auto-respawning
/// up to [_maxRetries] times within [_retryWindow]. Beyond that budget
/// the destination is marked failed and the controller is expected to
/// surface that to the user (and either retry from a clean state or drop
/// the mirror from the profile).
///
/// Lifecycle ownership: this runner owns the wl-mirror processes for as
/// long as the host app is alive. The `exec wl-mirror …` lines that
/// kanshi_config_writer emits give kanshi the same job when the GUI is
/// closed, so there is always exactly one owner of any given mirror.
class MirrorRunner extends ChangeNotifier {
  final ProcessRunner _runner;
  final DateTime Function() _now;
  bool? _availabilityCache;
  final Map<String, _MirrorEntry> _entries = {};
  final Set<String> _failed = {};

  MirrorRunner({
    ProcessRunner? runner,
    DateTime Function()? now,
  })  : _runner = runner ?? const DefaultProcessRunner(),
        _now = now ?? DateTime.now;

  /// Burst budget: at most [_maxRetries] restarts within [_retryWindow].
  /// Tuned conservatively — wl-mirror tends to die for one of two reasons:
  /// the source output disappeared (will recur on every retry until the
  /// hardware comes back, no point hammering) or a real crash (rare). The
  /// 30-second sliding window resets the counter once a mirror has run
  /// stably for that long, so a healthy long-running mirror never trips
  /// the budget even if it dies once a day.
  static const int _maxRetries = 3;
  static const Duration _retryWindow = Duration(seconds: 30);

  /// True when `wl-mirror` is in `$PATH`. Cached after the first call —
  /// the binary is not going to appear/disappear during a single app
  /// session, and if it does we will surface the error from `start()`.
  Future<bool> isAvailable() async {
    return _availabilityCache ??= await _runner.exists('wl-mirror');
  }

  /// Set of destination output ids that currently have a wl-mirror running
  /// (or that the runner is trying to keep alive).
  Set<String> get activeDestinations =>
      _entries.keys.toSet();

  /// Source output id for an active mirror, or null if [dstId] is not
  /// currently mirrored.
  String? mirrorSourceFor(String dstId) => _entries[dstId]?.srcId;

  /// Destination ids whose retry budget was exhausted. Cleared by a
  /// successful [start] or explicit [clearFailure].
  Set<String> get failedDestinations => Set.unmodifiable(_failed);

  void clearFailure(String dstId) {
    if (_failed.remove(dstId)) notifyListeners();
  }

  /// Begin (or rebind) a mirror so that [dstId] shows what [srcId] is
  /// rendering. Idempotent for an existing same-(src, dst) pair. When the
  /// destination is already mirroring a different source the old process
  /// is killed first.
  Future<void> start(String srcId, String dstId) async {
    final existing = _entries[dstId];
    if (existing != null) {
      if (existing.srcId == srcId) return; // already what we want
      await stop(dstId);
    }
    _failed.remove(dstId);
    final entry = _MirrorEntry(srcId: srcId, dstId: dstId);
    _entries[dstId] = entry;
    _spawn(entry);
    notifyListeners();
  }

  /// Stop the wl-mirror running for [dstId]. No-op if none is running.
  Future<void> stop(String dstId) async {
    final entry = _entries.remove(dstId);
    if (entry == null) return;
    entry.intentionallyStopped = true;
    await entry.subscription?.cancel();
    entry.subscription = null;
    final stream = entry.stream;
    entry.stream = null;
    if (stream != null) await stream.kill();
    notifyListeners();
  }

  /// Stop every active mirror. Used by `KanshiController.dispose` and on
  /// profile switches.
  Future<void> stopAll() async {
    final ids = _entries.keys.toList(growable: false);
    await Future.wait(ids.map(stop));
  }

  void _spawn(_MirrorEntry entry) {
    // wl-mirror's CLI parser is strict about positional ordering: the
    // source output name MUST be the last argument; any flag after it
    // is rejected with "unexpected trailing arguments after output name"
    // and the process bails out before opening a Wayland connection.
    // `--fullscreen-output` already implies `--fullscreen`, so we drop
    // the redundant explicit flag and put the source last.
    final ps = _runner.stream('wl-mirror', [
      '--fullscreen-output',
      entry.dstId,
      entry.srcId,
    ]);
    entry.stream = ps;
    entry.subscription = ps.lines.listen(
      (_) {}, // we do not consume wl-mirror's stdout
      onDone: () => _handleExit(entry),
      onError: (_) => _handleExit(entry),
      cancelOnError: false,
    );
  }

  void _handleExit(_MirrorEntry entry) {
    // Clean up the subscription regardless of cause.
    entry.subscription?.cancel();
    entry.subscription = null;
    entry.stream = null;
    if (entry.intentionallyStopped) return;
    // The user did not stop us — wl-mirror crashed or its window was
    // closed. Apply the retry budget.
    final current = _entries[entry.dstId];
    if (current != entry) return; // entry was replaced by a newer start()
    final now = _now();
    if (entry.lastRetryAt == null ||
        now.difference(entry.lastRetryAt!) > _retryWindow) {
      entry.retryCount = 0;
    }
    if (entry.retryCount >= _maxRetries) {
      _entries.remove(entry.dstId);
      _failed.add(entry.dstId);
      notifyListeners();
      return;
    }
    entry.retryCount += 1;
    entry.lastRetryAt = now;
    _spawn(entry);
    notifyListeners();
  }

  @override
  void dispose() {
    // Fire-and-forget — dispose is sync but our cleanup is async. Best
    // effort: kill all stream subscriptions immediately so dart-side
    // listeners stop firing; the underlying processes are also killed
    // via the awaited stopAll call (callers should `await stopAll()`
    // before disposing if they need a hard sync point).
    for (final entry in _entries.values) {
      entry.intentionallyStopped = true;
      entry.subscription?.cancel();
      // ignore: discarded_futures
      entry.stream?.kill();
    }
    _entries.clear();
    super.dispose();
  }
}

class _MirrorEntry {
  final String srcId;
  final String dstId;
  ProcessStream? stream;
  StreamSubscription<String>? subscription;
  int retryCount = 0;
  DateTime? lastRetryAt;
  bool intentionallyStopped = false;

  _MirrorEntry({required this.srcId, required this.dstId});
}
