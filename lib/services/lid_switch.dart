import 'dart:convert';
import 'dart:io';

import 'package:kanshi_gui/domain/lid_policy.dart';
import 'package:kanshi_gui/services/process_runner.dart';
import 'package:kanshi_gui/services/sway_config_files.dart';

// Flutter-free: the helper binary reads the lid and its memory through this
// file. See lib/domain/lid_policy.dart for what the lid means.

/// The two sway bindings that tell the helper the lid moved.
///
/// `--reload` runs the binding for the current state again after a sway
/// reload, which resets every output; `--locked` keeps it working behind a
/// lock screen, which is where a lid is most often closed.
class LidSwitchBinding {
  LidSwitchBinding._();

  /// The helper, as sway's `exec` runs it. Plain words only: sway hands the
  /// rest of the line to /bin/sh.
  static const helper = 'kanshi-gui-workspaced';

  static const _flags = '--reload --locked';

  static const lines = [
    'bindswitch $_flags lid:on exec $helper --lid closed',
    'bindswitch $_flags lid:off exec $helper --lid open',
  ];

  /// The comment above [lines], so a reader of their config knows where they
  /// came from and that the app takes them out again.
  static const marker = '# Added by kanshi_gui: switch the built-in screen '
      'off while the lid is closed. Turn it off in the app to remove.';

  static final _lidBinding =
      RegExp(r'^\s*bindswitch\s+(?:--\S+\s+)*lid:(?:on|off|toggle)\b');

  /// Reads the `bindswitch lid:…` lines of a sway config (includes already
  /// followed).
  static LidSwitchScan scan(List<SwayConfigLine> config) {
    final ours = <SwayConfigLine>[];
    final foreign = <SwayConfigLine>[];
    for (final line in config) {
      final text = SwayConfigFiles.stripInlineComment(line.text).trim();
      if (!_lidBinding.hasMatch(text)) continue;
      (lines.contains(text) ? ours : foreign).add(line);
    }
    return LidSwitchScan(ours: ours, foreign: foreign);
  }

  /// Adds [lines] to the sway config at [path] unless they are there, and
  /// binds them in the running sway so they work without a reload.
  ///
  /// Returns null on success and a sentence for the user otherwise.
  static Future<String?> install(
    String path, {
    ProcessRunner runner = const DefaultProcessRunner(),
  }) async {
    final LidSwitchScan now;
    try {
      now = scan(await SwayConfigFiles.readLines(path));
    } catch (_) {
      return 'Could not read $path, so nothing was added.';
    }
    if (!now.installed) {
      final err = await SwayConfigFiles.appendBlock(path, marker, lines);
      if (err != null) return err;
    }
    for (final l in lines) {
      await _swaymsg(runner, l);
    }
    return null;
  }

  /// Takes [lines] out of the sway config at [path] and out of the running
  /// sway. A binding of the user's own is never touched.
  static Future<String?> uninstall(
    String path, {
    ProcessRunner runner = const DefaultProcessRunner(),
  }) async {
    final LidSwitchScan now;
    try {
      now = scan(await SwayConfigFiles.readLines(path));
    } catch (_) {
      return 'Could not read $path, so nothing was removed.';
    }
    if (now.ours.isNotEmpty) {
      final err = await SwayConfigFiles.removeBlock(marker, now.ours);
      if (err != null) return err;
    }
    for (final state in const ['on', 'off']) {
      await _swaymsg(runner, 'unbindswitch $_flags lid:$state');
    }
    return null;
  }

  /// Best effort: without a running sway the config lines take effect at the
  /// next login, which is all there is to do.
  static Future<void> _swaymsg(ProcessRunner runner, String command) async {
    try {
      await runner.run('swaymsg', [command],
          timeout: const Duration(seconds: 2));
    } catch (_) {/* no sway to tell */}
  }
}

/// What [LidSwitchBinding.scan] found.
class LidSwitchScan {
  /// Our two lines, where they are.
  final List<SwayConfigLine> ours;

  /// Lid bindings the user wrote. Ours are appended after them and sway keeps
  /// the last binding for a switch state, so theirs stop firing.
  final List<SwayConfigLine> foreign;

  const LidSwitchScan({this.ours = const [], this.foreign = const []});

  bool get installed => ours.length >= LidSwitchBinding.lines.length;
}

/// What the lid dialog decides from.
class LidSwitchFacts {
  /// The sway config the running sway loaded, or null when there is none.
  final String? swayConfigPath;

  /// Whether this user can change [swayConfigPath].
  final bool writable;

  /// Null when [swayConfigPath] could not be read.
  final LidSwitchScan? scan;

  const LidSwitchFacts({this.swayConfigPath, this.writable = false, this.scan});

  /// Whether the switch can be flipped from the app.
  bool get canChange => swayConfigPath != null && writable && scan != null;
}

/// What the helper remembers between two runs, per sway session.
///
/// Kept in the runtime directory with the sway socket's path, so a new
/// session — a new socket — starts with nothing remembered: a panel switched
/// off in the last session is not one to switch on in this one.
class LidMemory {
  LidMemory(this.socket, {String? directory})
      : _dir = directory ??
            Platform.environment['XDG_RUNTIME_DIR'] ??
            '/tmp/kanshi-gui-${Platform.environment['USER'] ?? 'user'}';

  final String socket;
  final String _dir;

  File get _file => File('$_dir/kanshi-gui-lid.json');

  /// The panels the lid switched off.
  Set<String> switchedOff = {};

  /// The last state sway's binding reported. The fallback for hardware
  /// without `/proc/acpi/button/lid`.
  LidState lid = LidState.unknown;

  LidMemory read() {
    try {
      final json = jsonDecode(_file.readAsStringSync());
      if (json is! Map || json['socket'] != socket) return this;
      switchedOff = {
        for (final o in (json['off'] as List? ?? const [])) o.toString(),
      };
      lid = LidState.fromArgument(json['lid']?.toString()) ?? LidState.unknown;
    } catch (_) {/* nothing remembered */}
    return this;
  }

  void write() {
    try {
      Directory(_dir).createSync(recursive: true);
      // Renamed into place: a binding and kanshi's exec can run at once.
      final tmp = File('${_file.path}.$pid');
      tmp.writeAsStringSync(jsonEncode({
        'socket': socket,
        'lid': lid == LidState.unknown ? null : lid.name,
        'off': switchedOff.toList()..sort(),
      }));
      tmp.renameSync(_file.path);
    } catch (_) {/* not remembered: the next lid opening restores nothing */}
  }
}

/// The lid, from ACPI when the kernel reports one, else from [remembered].
///
/// ACPI first: it is right at boot and after a resume, before sway's binding
/// has said anything. Hardware without an ACPI lid (most ARM laptops) reports
/// it as an input switch only, and there the binding's last word is all
/// there is.
LidState readLidState({
  LidState remembered = LidState.unknown,
  String acpiDirectory = '/proc/acpi/button/lid',
}) {
  try {
    final dir = Directory(acpiDirectory);
    if (dir.existsSync()) {
      final lids = dir.listSync().whereType<Directory>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final d in lids) {
        final state = File('${d.path}/state');
        if (!state.existsSync()) continue;
        final s = LidState.fromAcpi(state.readAsStringSync());
        if (s != LidState.unknown) return s;
      }
    }
  } catch (_) {/* unreadable: fall back */}
  return remembered;
}
