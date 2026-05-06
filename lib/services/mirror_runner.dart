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
  /// is killed first. Also kills any *external* wl-mirror process
  /// targeting [dstId] — they can show up when an older release left an
  /// orphan or when a hand-edited kanshi config still has an
  /// `exec wl-mirror …` line — so the runner is the single source of
  /// truth for the destination's mirror state.
  Future<void> start(String srcId, String dstId) async {
    final existing = _entries[dstId];
    if (existing != null) {
      if (existing.srcId == srcId) {
        // Even when the entry matches, sweep externals: a duplicate
        // process would race with ours for the same destination.
        await _killExternalForDst(dstId);
        return;
      }
      await stop(dstId);
    }
    await _killExternalForDst(dstId);
    _failed.remove(dstId);
    final entry = _MirrorEntry(srcId: srcId, dstId: dstId);
    _entries[dstId] = entry;
    _spawn(entry);
    notifyListeners();
  }

  /// Stop the wl-mirror running for [dstId]. Kills both the runner-owned
  /// process and any external wl-mirror that happens to target the same
  /// destination, so the user's "Stop mirror" action is final regardless
  /// of who originally spawned the process.
  Future<void> stop(String dstId) async {
    final entry = _entries.remove(dstId);
    if (entry != null) {
      entry.intentionallyStopped = true;
      await entry.subscription?.cancel();
      entry.subscription = null;
      final stream = entry.stream;
      entry.stream = null;
      if (stream != null) await stream.kill();
    }
    await _killExternalForDst(dstId);
    if (entry != null) notifyListeners();
  }

  /// Stop every active mirror. Used by `KanshiController.dispose` and on
  /// profile switches.
  Future<void> stopAll() async {
    final ids = _entries.keys.toList(growable: false);
    await Future.wait(ids.map(stop));
  }

  /// Scans the live `wl-mirror` process table and kills every instance
  /// whose destination is NOT a key in [desiredDstToSrc] OR whose source
  /// disagrees with the desired source for that destination. Called from
  /// `KanshiController._reconcileMirrors` so cold-start cleanup catches
  /// any orphan a previous GUI / kanshi-exec hook session left behind.
  Future<void> purgeExternalNotMatching(
    Map<String, String> desiredDstToSrc,
  ) async {
    final running = await _scanRunning();
    for (final p in running) {
      final desiredSrc = desiredDstToSrc[p.dst];
      // Keep the process iff the runner already owns it (managed entry
      // matching same src) AND it matches desired. Anything else is
      // either an orphan or a duplicate.
      final managed = _entries[p.dst];
      final ownedAndCorrect =
          managed != null && managed.srcId == p.src && desiredSrc == p.src;
      if (ownedAndCorrect) continue;
      // Don't kill our own managed processes — start() already replaced
      // them when they need replacing. Only target externals.
      if (managed != null) continue;
      await _killPid(p.pid);
    }
  }

  /// Kill any wl-mirror process whose `--fullscreen-output <DST>` argv
  /// points at [dstId] except the runner-owned process for that
  /// destination (which is killed via its [ProcessStream] handle).
  Future<void> _killExternalForDst(String dstId) async {
    final running = await _scanRunning();
    final managed = _entries[dstId];
    for (final p in running) {
      if (p.dst != dstId) continue;
      if (managed != null && managed.pid != null && p.pid == managed.pid) {
        continue;
      }
      await _killPid(p.pid);
    }
  }

  Future<List<_RunningMirror>> _scanRunning() async {
    try {
      final r = await _runner.run('pgrep', ['-fa', 'wl-mirror']);
      if (r.exitCode != 0) return const [];
      return _parsePgrepOutput(r.stdout?.toString() ?? '');
    } catch (_) {
      return const [];
    }
  }

  /// Parse `pgrep -fa wl-mirror` output into a list of (dst, src)
  /// records keyed by pid. Public-ish (visible-for-testing) so tests
  /// can validate the parsing without spawning a real process tree.
  @visibleForTesting
  static List<({int pid, String dst, String src})> parsePgrepForTest(
    String stdout,
  ) =>
      _parsePgrepOutput(stdout)
          .map((p) => (pid: p.pid, dst: p.dst, src: p.src))
          .toList();

  static List<_RunningMirror> _parsePgrepOutput(String stdout) {
    final out = <_RunningMirror>[];
    for (final raw in stdout.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final parts = line.split(RegExp(r'\s+'));
      if (parts.length < 2) continue;
      final pid = int.tryParse(parts[0]);
      if (pid == null) continue;
      final argv = parts.sublist(1);
      // The argv may also begin with the path-shell wrapper (e.g. `bash
      // -c "wl-mirror …"`); we need the wl-mirror invocation specifically
      // and bail if it isn't a direct one.
      if (!argv.first.endsWith('wl-mirror')) continue;
      String? dst;
      String? src;
      const takesArg = {
        '--fullscreen-output',
        '-F',
        '--scaling',
        '-s',
        '--backend',
        '-b',
        '--transform',
        '-t',
        '--region',
        '-r',
        '--title',
      };
      final flagValueIdx = <int>{};
      for (var i = 1; i < argv.length; i++) {
        final t = argv[i];
        if (takesArg.contains(t) && i + 1 < argv.length) {
          flagValueIdx.add(i + 1);
          if (t == '--fullscreen-output' || t == '-F') dst = argv[i + 1];
        }
      }
      // wl-mirror's source positional is the last non-flag, non-flag-value
      // argument; iterate backwards.
      for (var i = argv.length - 1; i >= 1; i--) {
        if (flagValueIdx.contains(i)) continue;
        if (argv[i].startsWith('-')) continue;
        src = argv[i];
        break;
      }
      if (dst == null || src == null) continue;
      out.add(_RunningMirror(pid: pid, dst: dst, src: src));
    }
    return out;
  }

  Future<void> _killPid(int pid) async {
    try {
      await _runner.run('kill', ['-TERM', '$pid']);
    } catch (_) {/* best effort */}
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
    // Resolve the pid asynchronously; we don't await because spawn
    // continues regardless. _killExternalForDst handles the brief
    // window where pid is null by skipping our managed entry only when
    // its src/dst exactly matches the candidate.
    // ignore: discarded_futures
    ps.pid.then((p) => entry.pid = p);
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
  int? pid;
  int retryCount = 0;
  DateTime? lastRetryAt;
  bool intentionallyStopped = false;

  _MirrorEntry({required this.srcId, required this.dstId});
}

class _RunningMirror {
  final int pid;
  final String dst;
  final String src;
  const _RunningMirror({
    required this.pid,
    required this.dst,
    required this.src,
  });
}
