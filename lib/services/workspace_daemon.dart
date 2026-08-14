import 'dart:io';

import 'package:kanshi_gui/services/process_runner.dart';

/// Whether the helper service that places workspaces without the app is
/// installed, and whether the user has asked for it.
enum WorkspaceDaemonState {
  /// The unit is not on this machine — running from source, or installed by
  /// something other than the .deb. The switch is hidden rather than shown
  /// broken.
  unavailable,
  disabled,
  enabled,
}

/// The opt-in for `kanshi-gui-workspaces.service`.
///
/// The .deb ships the unit but deliberately does not enable it: a package
/// that starts moving a stranger's workspaces the moment it is installed is
/// exactly the thing that got this app uninstalled once already. So the file
/// is put in place for anyone who wants it, and nothing happens until someone
/// flips the switch in the Workspaces sheet — per user, never system-wide.
///
/// `systemctl --user enable --now` rather than an autostart .desktop entry:
/// this is a service with a lifetime tied to the session, it must come back
/// if it dies, and `systemctl --user status` is where a Linux user will look
/// for it when they wonder what is moving their workspaces.
class WorkspaceDaemon {
  static const String unit = 'kanshi-gui-workspaces.service';

  /// Where a package may have dropped the unit. The user-local path is
  /// included so someone who installed by hand still gets the switch.
  static List<String> defaultSearchPaths() => [
        '/usr/lib/systemd/user/$unit',
        '/lib/systemd/user/$unit',
        '/usr/local/lib/systemd/user/$unit',
        '${Platform.environment['HOME'] ?? ''}/.config/systemd/user/$unit',
      ];

  final ProcessRunner runner;
  final List<String>? searchPaths;

  const WorkspaceDaemon({
    this.runner = const DefaultProcessRunner(),
    this.searchPaths,
  });

  bool get isInstalled => (searchPaths ?? defaultSearchPaths())
      .any((p) => p.isNotEmpty && File(p).existsSync());

  Future<WorkspaceDaemonState> state() async {
    if (!isInstalled) return WorkspaceDaemonState.unavailable;
    if (!await runner.exists('systemctl')) {
      return WorkspaceDaemonState.unavailable;
    }
    // `is-enabled` exits non-zero for every not-enabled state (disabled,
    // static, masked), so the exit code says nothing useful and the word on
    // stdout is what has to be read.
    final r = await runner.run('systemctl', ['--user', 'is-enabled', unit]);
    final answer = '${r.stdout}'.trim();
    return answer == 'enabled' || answer == 'enabled-runtime'
        ? WorkspaceDaemonState.enabled
        : WorkspaceDaemonState.disabled;
  }

  /// Turns the service on or off for this user, now and at every future
  /// login. Throws with systemd's own words on failure — the switch must not
  /// come back showing a state the system does not agree with.
  Future<void> setEnabled(bool on) async {
    // An upgrade rewrites the unit file under a systemd that has already read
    // the old one. Without this, the first flip after an upgrade starts the
    // previous version and no message says so.
    await runner.run('systemctl', ['--user', 'daemon-reload']);
    final r = await runner.run(
      'systemctl',
      ['--user', on ? 'enable' : 'disable', '--now', unit],
      timeout: const Duration(seconds: 15),
    );
    if (r.exitCode != 0) {
      final why = '${r.stderr}'.trim();
      throw WorkspaceDaemonException(
        why.isEmpty ? 'systemctl exited ${r.exitCode}' : why,
      );
    }
  }
}

class WorkspaceDaemonException implements Exception {
  final String message;
  const WorkspaceDaemonException(this.message);
  @override
  String toString() => message;
}
