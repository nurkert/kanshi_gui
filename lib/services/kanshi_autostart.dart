import 'dart:io';

import 'package:kanshi_gui/services/process_runner.dart';
import 'package:kanshi_gui/services/sway_config_files.dart';

/// What starts kanshi when the user logs in.
enum KanshiStartedBy { swayConfig, systemdUnit }

/// Everything the "kanshi isn't running" dialog decides from.
class KanshiSetupFacts {
  /// Whether `kanshi` is on PATH at all.
  final bool installed;

  /// Whether the kanshi config exists. kanshi refuses to start without one.
  final bool configExists;

  final KanshiAutostart autostart;

  /// The lines that would start kanshi with sway, or null when there is no
  /// sway to add them to or the config path cannot go into one safely.
  final List<String>? swayLines;

  /// Whether this user can append to [KanshiAutostart.swayConfigPath]. A sway
  /// running from `/etc/sway/config` is not something to edit from here.
  final bool swayConfigWritable;

  const KanshiSetupFacts({
    required this.installed,
    required this.configExists,
    required this.autostart,
    this.swayLines,
    this.swayConfigWritable = false,
  });
}

/// One thing that starts kanshi.
class KanshiStarter {
  final KanshiStartedBy by;

  /// For [KanshiStartedBy.swayConfig]: the file and 1-based line.
  final String? path;
  final int? line;

  /// For [KanshiStartedBy.swayConfig]: the line as written.
  final String? text;

  const KanshiStarter(this.by, {this.path, this.line, this.text});
}

/// Whether anything will bring kanshi up at the next login, and where.
///
/// Neither kanshi(1), its README nor the Debian package say how kanshi gets
/// started; every sway user wires it up by hand, usually with an `exec` line
/// in the sway config and sometimes with a systemd user unit. "kanshi is
/// running right now" says nothing about either, which is why the app asks
/// this separately before it offers to set anything up.
class KanshiAutostart {
  final List<KanshiStarter> starters;

  /// Whether the sway config makes kanshi re-apply after `swaymsg reload`,
  /// which resets every output to sway's own idea of it while kanshi — whose
  /// profile still matches — would otherwise do nothing.
  final bool reappliesOnSwayReload;

  /// The sway config that was read, when there is one.
  final String? swayConfigPath;

  /// False when the sway config should have been read and could not be, so
  /// "nothing found" is not an answer.
  final bool complete;

  const KanshiAutostart({
    this.starters = const [],
    this.reappliesOnSwayReload = false,
    this.swayConfigPath,
    this.complete = true,
  });

  bool get found => starters.isNotEmpty;

  /// Started from the sway config AND by a systemd unit: two kanshi daemons
  /// applying profiles over each other.
  bool get startedTwice =>
      starters.any((s) => s.by == KanshiStartedBy.swayConfig) &&
      starters.any((s) => s.by == KanshiStartedBy.systemdUnit);

  /// The systemd unit the Arch wiki suggests, and the only name probed.
  static const systemdUnit = 'kanshi.service';

  /// Looks in the sway config (when [sway] is true) and at the systemd user
  /// unit.
  static Future<KanshiAutostart> detect({
    ProcessRunner runner = const DefaultProcessRunner(),
    bool sway = true,
    String? swayConfigPath,
    Map<String, String>? environment,
  }) async {
    final starters = <KanshiStarter>[];
    var reapplies = false;
    var complete = true;
    String? path;
    if (sway) {
      path = swayConfigPath ??
          await SwayConfigFiles.locate(
              runner: runner, environment: environment);
      if (path == null) {
        complete = false;
      } else {
        try {
          final scan = scanSwayConfig(await SwayConfigFiles.readLines(path));
          starters.addAll(scan.starters);
          reapplies = scan.reappliesOnSwayReload;
        } catch (_) {
          complete = false;
        }
      }
    }
    try {
      if (await runner.exists('systemctl')) {
        final r =
            await runner.run('systemctl', ['--user', 'is-enabled', systemdUnit]);
        // `is-enabled` exits non-zero for every state that is not enabled, so
        // the word on stdout is what has to be read.
        final answer = '${r.stdout}'.trim();
        if (answer == 'enabled' || answer == 'enabled-runtime') {
          starters.add(const KanshiStarter(KanshiStartedBy.systemdUnit));
        }
      }
    } catch (_) {/* no systemd: nothing to find there */}
    return KanshiAutostart(
      starters: starters,
      reappliesOnSwayReload: reapplies,
      swayConfigPath: path,
      complete: complete,
    );
  }

  static final _exec =
      RegExp(r'^\s*(exec|exec_always)\s+(?:--no-startup-id\s+)?(.*)$');

  /// A `pkill`/`pgrep`/`killall` invocation up to the next shell separator.
  /// Naming kanshi there stops or looks for it; it does not start it.
  static final _processTool =
      RegExp(r'(?<![\w-])(?:pkill|pgrep|killall)(?![\w-])[^;&|]*');

  /// kanshi as a program. Not `kanshictl`, not `kanshi-gui-…`, and not the
  /// `kanshi` directory in `~/.config/kanshi/config`.
  static final _kanshi = RegExp(r'(?<![\w.-])kanshi(?![\w/-])');

  static final _kanshictlReload = RegExp(r'(?<![\w-])kanshictl\s+reload\b');

  /// Reads the `exec` and `exec_always` lines of a sway config (includes
  /// already followed). Key bindings that exec kanshi are not autostart and
  /// are not lines of this shape.
  static KanshiAutostart scanSwayConfig(List<SwayConfigLine> lines) {
    final starters = <KanshiStarter>[];
    var reapplies = false;
    for (final line in lines) {
      final m = _exec.firstMatch(line.text);
      if (m == null) continue;
      final always = m.group(1) == 'exec_always';
      var hangUp = false;
      final cleaned = m.group(2)!.replaceAllMapped(_processTool, (t) {
        final call = t.group(0)!;
        if (RegExp(r'HUP\b|-1\b').hasMatch(call) &&
            RegExp(r'(?<![\w.-])kanshi(?![\w/-])').hasMatch(call)) {
          hangUp = true;
        }
        return ' ';
      });
      final starts = _kanshi.hasMatch(cleaned);
      if (starts) {
        starters.add(KanshiStarter(KanshiStartedBy.swayConfig,
            path: line.path, line: line.number, text: line.text.trim()));
      }
      if (always &&
          (starts || hangUp || _kanshictlReload.hasMatch(cleaned))) {
        reapplies = true;
      }
    }
    return KanshiAutostart(starters: starters, reappliesOnSwayReload: reapplies);
  }

  /// The comment written above the lines [addToSwayConfig] appends, so a
  /// reader of their config knows where they came from.
  static const marker =
      '# Added by kanshi_gui: start kanshi with sway, and re-apply the '
      'screens after a sway reload.';

  /// The lines that start kanshi with sway, or null when [kanshiConfigPath]
  /// cannot be written into a sway config line safely.
  ///
  /// With kanshictl, kanshi is started once and asked to reload whenever sway
  /// reloads: `exec` runs at startup only, `exec_always` on every reload too.
  /// At the very first start the reload races kanshi coming up and fails
  /// harmlessly — kanshi applies its profile on start anyway.
  ///
  /// Without kanshictl there is nothing to ask, and a hang-up would end a
  /// kanshi older than 1.3, so kanshi is restarted on every sway reload
  /// instead. That is the line this app's maintainer has run for months.
  ///
  /// [kanshiConfigPath] is null for kanshi's default config. A custom path
  /// goes into a sway line that sway expands `$variables` in and hands to a
  /// shell, so only plain path characters are accepted.
  static List<String>? swayLines({
    required bool kanshictl,
    String? kanshiConfigPath,
  }) {
    if (kanshiConfigPath != null &&
        !RegExp(r'^[A-Za-z0-9._/+-]+$').hasMatch(kanshiConfigPath)) {
      return null;
    }
    final arg = kanshiConfigPath == null ? '' : ' -c $kanshiConfigPath';
    return kanshictl
        ? ['exec kanshi$arg', 'exec_always kanshictl reload']
        : ["exec_always sh -c 'pkill -x kanshi; sleep 0.2; exec kanshi$arg'"];
  }

  /// Appends [lines] under [marker] to the sway config at [path].
  ///
  /// Appended, not rewritten: through a symlink (dotfile managers link the
  /// config into place) and with its permissions untouched, and nothing the
  /// user wrote is moved. Returns null on success and a sentence for the user
  /// otherwise.
  ///
  /// Not validated with `sway --validate`: in sway 1.12 that initialises a
  /// compositor backend before it reads the file, which is not something to
  /// start behind someone's back. The lines are fixed and use nothing but
  /// `exec` and `exec_always`.
  static Future<String?> addToSwayConfig(
      String path, List<String> lines) async {
    try {
      final target = File(await File(path).resolveSymbolicLinks());
      final before = await target.readAsString();
      final block = StringBuffer();
      if (before.isNotEmpty && !before.endsWith('\n')) block.write('\n');
      block.write('\n$marker\n');
      for (final l in lines) {
        block.write('$l\n');
      }
      await target.writeAsString(block.toString(),
          mode: FileMode.append, flush: true);
      return null;
    } on FileSystemException catch (e) {
      return 'Could not write $path: ${e.osError?.message ?? e.message}.';
    }
  }
}
