import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/domain/output_identity.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/kanshi_config_parser.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';

import 'support/kanshi_exec.dart';

/// Does the config actually do anything?
///
/// For four releases the answer on kanshi 1.9 was no, and nothing noticed,
/// because every test asserted on the string the app produced rather than on
/// what happened to it afterwards. kanshi hands `exec` lines to `/bin/sh`
/// after re-escaping only whitespace and the two quotes, so the `; `-joined
/// chain this app wrote was split into shell commands — one binding applied,
/// eight `not found` — and on a machine whose display reports a bracket in its
/// EDID, the shell refused the entire line and none applied at all.
///
/// These tests run the writer's real output through kanshi's real algorithm
/// and a real `/bin/sh`, and look at what swaymsg received. See
/// support/kanshi_exec.dart.
MonitorTileData _mon(
  String id,
  String descriptor, {
  double x = 0,
  String? mirrorOf,
}) =>
    MonitorTileData(
      id: id,
      manufacturer: descriptor,
      edidDescriptor: descriptor,
      x: x,
      y: 0,
      width: 2560,
      height: 1440,
      scale: 1.0,
      rotation: 0,
      refresh: 60,
      resolution: '2560x1440',
      orientation: 'landscape',
      enabled: true,
      mirrorOf: mirrorOf,
    );

/// The three displays on the desk this was found on. The laptop panel is the
/// interesting one: its EDID carries brackets and a comma.
const _samsungLeft = 'Samsung Electric Company LF27T850 H4LR303241';
const _samsungRight = 'Samsung Electric Company LF27T850 H4LR100370';
const _laptop =
    'InfoVision Optoelectronics (Kunshan) Co.,Ltd China 0x057D Unknown';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('kanshi_exec_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  String render(List<MonitorTileData> mons) => KanshiConfigWriter.render(
        [Profile(name: 'Desk', monitors: mons)],
        options: KanshiWriteOptions.swayDefaults
            .copyWith(injectSwayWorkspaceExec: true),
      );

  List<String> execLines(String config) => [
        for (final l in config.split('\n'))
          if (l.trim().startsWith('exec ')) l.trim(),
      ];

  /// Everything sway ends up being told, across all the exec lines.
  Future<List<String>> swaySees(String config) async {
    final all = <String>[];
    for (final line in execLines(config)) {
      final r = await runAsKanshiWould(line, sandbox: tmp);
      expect(r.stderr, isEmpty,
          reason: 'the shell refused this line, so it did nothing:\n  $line');
      all.addAll(r.swayCommands);
    }
    return all;
  }

  group('the harness itself', () {
    test('reproduces the failure that started this', () async {
      // The old form, verbatim. Kept as a test so the harness is known to be
      // able to SEE the bug — a harness that reports success on the broken
      // input proves nothing about the fixed one.
      const old = 'exec swaymsg "workspace 1 output \'$_laptop\'; '
          'workspace 2 output \'$_samsungLeft\'"';
      final r = await runAsKanshiWould(old, sandbox: tmp);
      expect(r.stderr, contains('('),
          reason: 'the bracket in the EDID should break the shell');
      expect(r.swayCommands, isEmpty,
          reason: 'not one binding reached sway');
    });

    test('a semicolon splits the line even without a bracket', () async {
      const old = 'exec swaymsg "workspace 1 output \'$_samsungLeft\'; '
          'workspace 2 output \'$_samsungRight\'"';
      final r = await runAsKanshiWould(old, sandbox: tmp);
      expect(r.swayCommands.length, 1,
          reason: 'only the first command survives the shell');
      expect(r.stderr, contains('not found'),
          reason: 'the rest were looked up as programs');
    });
  });

  group('what the writer produces now', () {
    test('every workspace reaches sway, on the desk that broke it', () async {
      final commands = await swaySees(render([
        _mon('DP-4', _samsungLeft),
        _mon('DP-5', _samsungRight, x: 2560),
        _mon('eDP-1', _laptop, x: 5120),
      ]));

      for (var ws = 1; ws <= 9; ws++) {
        expect(
          commands.any((c) => c.startsWith('workspace $ws output ')),
          isTrue,
          reason: 'workspace $ws was never bound',
        );
      }
      expect(commands.length, 9);
    });

    test('the display sway is told about is the right one', () async {
      final commands = await swaySees(render([
        _mon('DP-4', _samsungLeft),
        _mon('DP-5', _samsungRight, x: 2560),
        _mon('eDP-1', _laptop, x: 5120),
      ]));
      // Left to right: 1 4 7 · 2 5 8 · 3 6 9. The quotes are sway's to strip.
      expect(commands, contains('workspace 1 output "$_samsungLeft"'));
      expect(commands, contains('workspace 2 output "$_samsungRight"'));
      // The laptop's EDID cannot survive a shell, so it is addressed by port.
      expect(commands, contains('workspace 3 output "eDP-1"'));
      expect(commands, contains('workspace 9 output "eDP-1"'));
    });

    test('a stable description arrives intact, spaces and all', () async {
      // The failure mode this replaces was silent: sway drops an output
      // target it cannot resolve without saying anything, and the workspace
      // just opens wherever the cursor is.
      final commands = await swaySees(render([_mon('DP-4', _samsungLeft)]));
      expect(commands.first, 'workspace 1 output "$_samsungLeft"');
    });

    test('the profile marker writes the name and nothing else', () async {
      final config = KanshiConfigWriter.render(
        [Profile(name: r"Nico's $(id) Desk", monitors: [
          _mon('DP-4', _samsungLeft)
        ])],
        options: KanshiWriteOptions.swayDefaults,
      );
      final marker = execLines(config)
          .firstWhere((l) => l.contains('current_kanshi_profile'));
      final body = marker.replaceFirst(RegExp(r'^exec\s+'), '');
      final cmd = kanshiShellCommand(scfgParams(body));
      await Process.run('/bin/sh', ['-c', cmd],
          environment: {'HOME': tmp.path, 'PATH': '/usr/bin:/bin'});
      // Reduced, not executed. Quoting cannot save this line — scfg eats the
      // quotes before the shell sees them — so the unsafe part is simply not
      // written. The setup keeps its real name everywhere else.
      expect(File('${tmp.path}/.current_kanshi_profile').readAsStringSync(),
          "Nico s id Desk\n",
          reason: 'the name is data, not code');
    });

    test('a display that reports shell syntax executes nothing', () async {
      final config = render([
        _mon('DP-4', 'Acme \$(touch ${tmp.path}/pwned) Corp'),
        _mon('DP-5', _samsungRight, x: 2560),
      ]);
      for (final line in execLines(config)) {
        await runAsKanshiWould(line, sandbox: tmp);
      }
      expect(File('${tmp.path}/pwned').existsSync(), isFalse);
    });
  });

  group('the config still describes the desk', () {
    test('the output directive keeps the full EDID, brackets and all', () {
      // This is the line kanshi matches a profile on. Degrading it to a
      // connector name to please a shell would trade one silent failure for
      // another: the profile would stop being recognised after a redock.
      final config = render([_mon('eDP-1', _laptop)]);
      expect(config, contains('output "$_laptop" enable'));
    });

    test('and the port annotation still records where it was', () {
      final config = render([_mon('eDP-1', _laptop)]);
      expect(config, contains("# kanshi_gui:port '$_laptop'"));
    });
  });

  group('the whole file parses back', () {
    test('what the writer wrote, the parser reads', () {
      final mons = [
        _mon('DP-4', _samsungLeft),
        _mon('DP-5', _samsungRight, x: 2560),
        _mon('eDP-1', _laptop, x: 5120),
      ];
      final back = KanshiConfigParser.parse(render(mons));
      expect(back, hasLength(1));
      // The parser resolves each stable description back to the port it was
      // written on, via the `# kanshi_gui:port` annotations.
      expect(back.single.monitors.map((m) => m.id).toList(),
          ['DP-4', 'DP-5', 'eDP-1']);
      expect(back.single.monitors.map((m) => m.edidDescriptor).toList(),
          [_samsungLeft, _samsungRight, _laptop],
          reason: 'the stable identity has to survive the round trip');
    });
  });

  group('a display that reports shell syntax as its name', () {
    test('backticks execute nothing', () async {
      final config = render([_mon('DP-1', 'Acme `touch ${tmp.path}/p2` Corp')]);
      for (final line in execLines(config)) {
        await runAsKanshiWould(line, sandbox: tmp);
      }
      expect(File('${tmp.path}/p2').existsSync(), isFalse);
    });

    test('a quote cannot break out of the command', () async {
      final config =
          render([_mon('DP-1', 'Acme"; touch ${tmp.path}/p3; echo "')]);
      for (final line in execLines(config)) {
        await runAsKanshiWould(line, sandbox: tmp);
      }
      expect(File('${tmp.path}/p3').existsSync(), isFalse);
    });

    test('a newline cannot forge a config line', () {
      // The `# kanshi_gui:edid` annotation is a comment, but it is still a
      // LINE. A newline ends it and what follows becomes a directive.
      final config = render([
        _mon('DP-1', 'Acme\n    exec touch /tmp/forged\n# x'),
      ]);
      for (final line in config.split('\n')) {
        final t = line.trim();
        if (t.isEmpty) continue;
        expect(
          t.startsWith('#') ||
              t.startsWith('profile ') ||
              t.startsWith('output ') ||
              t.startsWith('exec swaymsg ') ||
              t.startsWith('exec echo ') ||
              t == '}',
          isTrue,
          reason: 'unexpected line in the config: $t',
        );
      }
    });

    test('a mirror whose target carries an apostrophe emits nothing', () {
      final config = KanshiConfigWriter.render([
        Profile(name: 'Mirrored', monitors: [
          _mon('DP-1', 'Honest Panel 1'),
          _mon("DP-2'; touch /tmp/pwned; '", 'Other Panel 2',
              x: 2560, mirrorOf: 'DP-1'),
        ]),
      ], options: KanshiWriteOptions.swayDefaults);
      expect(config, isNot(contains('wl-mirror')));
    });
  });

  group('the gate', () {
    test('real EDID strings pass', () {
      for (final ok in [
        _samsungLeft,
        _samsungRight,
        'DP-4',
        'eDP-1',
        'HDMI-A-2',
        'Dell Inc. U2723QE 1234,5',
      ]) {
        expect(isShellSafeCriteria(ok), isTrue, reason: ok);
      }
    });

    test('anything a shell would act on does not', () {
      for (final bad in [
        _laptop, // brackets — the one that broke this desk
        r'Acme $(id) Corp',
        'Acme `id` Corp',
        'Acme "x" Corp',
        "Acme's Panel",
        'Acme\nCorp',
        r'Acme\Corp',
        'Acme; id',
        'Acme|id',
        'Acme&id',
        'Acme<id',
        '',
      ]) {
        expect(isShellSafeCriteria(bad), isFalse,
            reason: bad.isEmpty ? '<empty>' : bad);
      }
    });

    test('shellSafeText keeps the readable part and drops the rest', () {
      expect(shellSafeText("Nico's Desk"), 'Nico s Desk');
      expect(shellSafeText(r'x$(id)y'), 'x id y');
      expect(shellSafeText('Office - Titan Rain'), 'Office - Titan Rain');
      expect(shellSafeText(r'$`"'), '',
          reason: 'nothing printable left means no line at all');
    });

    test('an unsafe target produces no exec lines at all', () {
      // Fail closed: the user loses their workspace placement, not their
      // session.
      expect(buildWorkspaceConfigExecs({1: r'DP-1$(id)'}), isEmpty);
      expect(buildWorkspaceConfigExecs({1: 'DP-1'}), hasLength(1));
    });

    test('a hash in a display name does not make the screen disappear', () {
      // `#` starts a comment in scfg — but not inside a quoted string, and
      // every stable EDID criteria is written in double quotes. The comment
      // stripper only tracked SINGLE quotes, so `output "Acme #1 24"` lost
      // everything from the hash onwards: the directive lost its arguments
      // and the display vanished from the setup on the next read.
      final config = render([_mon('DP-1', 'Acme #1 24'), _mon('DP-2', 'Other Panel', x: 2560)]);
      final back = KanshiConfigParser.parse(config);
      expect(back.single.monitors, hasLength(2),
          reason: 'a screen was dropped by the comment stripper');
      expect(back.single.monitors.first.edidDescriptor, 'Acme #1 24');
    });

    test('a double quote in an EDID string cannot truncate the output line',
        () {
      // Not a shell question — an scfg one. An unescaped `"` ends the string
      // early and the app can no longer read its own profiles back.
      final config = render([_mon('DP-1', 'Acme "Pro" 24')]);
      expect(KanshiConfigParser.parse(config), hasLength(1));
      expect(config, isNot(contains('output "Acme "Pro" 24"')));
    });
  });
}
