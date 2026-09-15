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

  /// How long kanshi gets to handle a hang-up before the process table is
  /// asked whether it survived one. See [reload], rung 3.
  final Duration hangUpSettle;

  KanshiDaemon(
    this._runner, {
    String? configPath,
    this.hangUpSettle = const Duration(milliseconds: 300),
  }) : configPath = configPath ?? r'$HOME/.config/kanshi/config';

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
  /// Four rungs, cheapest and least disruptive first:
  ///
  ///  1. `kanshictl reload` — no process restart, so no screen flicker.
  ///     kanshi opens its socket (`$XDG_RUNTIME_DIR/fr.emersion.kanshi.
  ///     $WAYLAND_DISPLAY`) by itself however it was started, so this works
  ///     for a kanshi launched from the sway config as well. This comment used
  ///     to claim the opposite; measured on kanshi 1.9, `kanshictl status`
  ///     answers a kanshi started by `exec_always`. It fails where kanshictl
  ///     was built without IPC (Debian bookworm ships kanshi without it).
  ///  2. the systemd user unit, when one is active.
  ///  3. SIGHUP. kanshi 1.3 and later reload on it (`event-loop.c`), which is
  ///     the flicker-free reload for a kanshi that has no kanshictl. kanshi
  ///     1.1 and 1.2 have no handler and the default action ends the process,
  ///     so the process table is asked afterwards and a kanshi that did not
  ///     survive falls through to the restart below — the same outcome as
  ///     before this rung existed.
  ///  4. kill and restart, with a short settle loop.
  ///
  /// Every rung is individually guarded: a machine without systemd throws
  /// ProcessException from the probe, which used to escape and make rung 4
  /// unreachable — the fallback existed but could not be got to.
  Future<ProcessResult> reload() async {
    final running = await isRunning();

    try {
      if (running == true && await _runner.exists('kanshictl')) {
        final r = await _runner.run('kanshictl', ['reload']);
        if (r.exitCode == 0) return r;
        // Fall through: an unreachable socket answers with a failure here.
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

    if (running == true) {
      try {
        final hup = await _runner.run('pkill', ['-HUP', '-x', 'kanshi']);
        if (hup.exitCode == 0) {
          await Future<void>.delayed(hangUpSettle);
          // Null ("cannot tell") is not read as "it died": restarting a
          // kanshi that is fine would cost the flicker this rung avoids.
          if (await isRunning() != false) return hup;
          debugPrint('kanshi did not survive SIGHUP; starting it again');
        }
      } catch (e) {
        debugPrint('SIGHUP to kanshi unavailable: $e');
      }
    }

    return _launch(replace: true);
  }

  /// Starts kanshi detached from this app, for a desk where nothing else
  /// does. Does not stop a kanshi that is already running — the caller asks
  /// [isRunning] first.
  Future<ProcessResult> start() => _launch(replace: false);

  Future<ProcessResult> _launch({required bool replace}) async {
    // The path goes inside double quotes in a bash command line, where a
    // leading `$HOME` must still expand and nothing else may. Inside double
    // quotes only `$`, a backtick, `"` and `\` mean anything to bash, so a
    // path carrying one of those (or a control character) is refused rather
    // than quoted: a config path is a setting the user can type, and a
    // started kanshi reading the wrong file is no better than none.
    final literal = configPath.replaceFirst(RegExp(r'^\$HOME(?=/)'), '');
    if (literal.isEmpty ||
        RegExp(r'["$`\\\x00-\x1f\x7f]').hasMatch(literal)) {
      return ProcessResult(0, 1, '',
          'kanshi was not started: the config path cannot be passed safely.');
    }
    return _runner.run('bash', [
      '-c',
      '${replace ? 'pkill -x kanshi; for i in 1 2 3 4 5; do '
          'pgrep -x kanshi >/dev/null || break; sleep 0.1; done; ' : ''}'
          'setsid kanshi -c "$configPath" '
          '>/tmp/kanshi_gui.log 2>&1 &'
    ]);
  }
}
