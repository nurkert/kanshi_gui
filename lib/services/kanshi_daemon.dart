import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:kanshi_gui/services/process_runner.dart';

/// Talks to the kanshi daemon — the thing that actually applies profiles,
/// with or without this GUI running.
///
/// Extracted because the reload chain was duplicated verbatim in
/// `SwayBackend` and `WlrRandrBackend`, so a fix to one silently left the
/// other behind. It has nothing to do with a compositor backend anyway:
/// kanshi is the same daemon whichever compositor is underneath.
class KanshiDaemon {
  final ProcessRunner _runner;

  /// Config path passed to the last-resort restart. Defaults to kanshi's own
  /// default so the fallback keeps working for a stock setup.
  final String configPath;

  KanshiDaemon(this._runner, {String? configPath})
      : configPath = configPath ?? r'$HOME/.config/kanshi/config';

  /// Whether a kanshi process is running. Null when it cannot be determined
  /// (no `pgrep`), which is deliberately different from "no".
  Future<bool?> isRunning() async {
    try {
      final r = await _runner.run('pgrep', ['-x', 'kanshi']);
      return r.exitCode == 0;
    } catch (_) {
      return null;
    }
  }

  /// Asks kanshi to re-read its config and re-apply the matching profile.
  ///
  /// Three rungs, cheapest and least disruptive first:
  ///
  ///  1. `kanshictl reload` — no process restart, so no screen flicker. Only
  ///     works when kanshi was started with an IPC socket; a kanshi launched
  ///     straight from the sway config (`exec_always … kanshi -c …`, which is
  ///     the documented way) has none, and the call fails.
  ///  2. the systemd user unit, when one is active.
  ///  3. kill and restart, with a short settle loop.
  ///
  /// Every rung is individually guarded: a machine without systemd throws
  /// ProcessException from the probe, which used to escape and make rung 3
  /// unreachable — the fallback existed but could not be got to.
  Future<ProcessResult> reload() async {
    try {
      if (await _runner.exists('kanshictl')) {
        if (await isRunning() == true) {
          final r = await _runner.run('kanshictl', ['reload']);
          if (r.exitCode == 0) return r;
          // Fall through: a socket-less kanshi answers with a failure here.
        }
      }
    } catch (e) {
      debugPrint('kanshictl reload unavailable: $e');
    }

    try {
      final check = await _runner.run(
        'systemctl',
        ['--user', 'is-active', '--quiet', 'kanshi.service'],
      );
      if (check.exitCode == 0) {
        return await _runner
            .run('systemctl', ['--user', 'restart', 'kanshi.service']);
      }
    } catch (e) {
      // No systemd, or no user bus. Not an error — just not this rung.
      debugPrint('systemd user unit unavailable: $e');
    }

    return _runner.run('bash', [
      '-c',
      'pkill -x kanshi; for i in 1 2 3 4 5; do '
          'pgrep -x kanshi >/dev/null || break; sleep 0.1; done; '
          'setsid kanshi -c $configPath '
          '>/tmp/kanshi_gui.log 2>&1 &'
    ]);
  }
}
