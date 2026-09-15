import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/services/kanshi_autostart.dart';
import 'package:kanshi_gui/services/sway_config_files.dart';

import 'fakes/fake_process_runner.dart';

KanshiAutostart scan(List<String> lines) => KanshiAutostart.scanSwayConfig([
      for (var i = 0; i < lines.length; i++)
        SwayConfigLine('/cfg', i + 1, lines[i]),
    ]);

void main() {
  group('reading a sway config', () {
    test("the maintainer's own line starts kanshi and restarts it on reload",
        () {
      // Verbatim from the sway config this app is developed on, where kanshi
      // has been started this way for months.
      final r = scan([
        'exec_always ~/.local/bin/sway-autoresize.sh watch',
        "exec_always --no-startup-id sh -c 'pkill -x kanshi; "
            r'[ -f "$HOME/.config/kanshi/config" ] || exit 0; sleep 0.2; '
            r'''exec /usr/bin/kanshi -c "$HOME/.config/kanshi/config"' ''',
      ]);
      expect(r.starters, hasLength(1));
      expect(r.starters.single.by, KanshiStartedBy.swayConfig);
      expect(r.starters.single.line, 2);
      expect(r.reappliesOnSwayReload, isTrue);
    });

    test('exec kanshi with a kanshictl reload on every sway reload', () {
      final r = scan(['exec kanshi', 'exec_always kanshictl reload']);
      expect(r.starters.map((s) => s.line), [1]);
      expect(r.reappliesOnSwayReload, isTrue);
    });

    test('exec alone starts it but does not re-apply after a sway reload', () {
      final r = scan(['exec --no-startup-id /usr/bin/kanshi -c ~/k/work']);
      expect(r.found, isTrue);
      expect(r.reappliesOnSwayReload, isFalse);
    });

    test('a reload or a hang-up on sway reload is not a start', () {
      expect(scan(['exec_always kanshictl reload']).found, isFalse);
      expect(scan(['exec_always kanshictl reload']).reappliesOnSwayReload,
          isTrue);
      final hup = scan(['exec_always pkill -HUP -x kanshi']);
      expect(hup.found, isFalse);
      expect(hup.reappliesOnSwayReload, isTrue);
    });

    test('a unit started from the sway config counts', () {
      expect(scan(['exec systemctl --user start kanshi.service']).found, isTrue);
    });

    test('lines that mention kanshi without starting it', () {
      final r = scan([
        '# exec kanshi',
        r'bindsym $mod+k exec kanshi',
        'exec pkill -x kanshi',
        'exec pgrep kanshi',
        'exec_always kanshictl status',
        'exec kanshi-gui-mirror "DP-1" "eDP-1" fit',
        'exec kanshi_gui',
        'exec cp ~/.config/kanshi/config /tmp/backup',
        'exec_always kanshi-gui-workspaced --from-kanshi',
      ]);
      expect(r.starters, isEmpty);
      expect(r.reappliesOnSwayReload, isFalse);
    });
  });

  group('detect', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('kanshi_autostart_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('follows the includes of the config sway loaded', () async {
      File('${tmp.path}/config.d/50-kanshi')
        ..createSync(recursive: true)
        ..writeAsStringSync('exec kanshi\n');
      final cfg = File('${tmp.path}/config')
        ..writeAsStringSync('include config.d/*\n');
      final r = await KanshiAutostart.detect(
        runner: FakeProcessRunner(),
        swayConfigPath: cfg.path,
      );
      expect(r.found, isTrue);
      expect(r.starters.single.path, endsWith('50-kanshi'));
      expect(r.complete, isTrue);
      expect(r.swayConfigPath, cfg.path);
    });

    test('an enabled systemd unit, and both at once', () async {
      final cfg = File('${tmp.path}/config')..writeAsStringSync('exec kanshi\n');
      final runner = FakeProcessRunner(
        installed: {'systemctl'},
        responses: {
          'systemctl --user is-enabled kanshi.service':
              ProcessResult(0, 0, 'enabled\n', ''),
        },
      );
      final r =
          await KanshiAutostart.detect(runner: runner, swayConfigPath: cfg.path);
      expect(r.starters.map((s) => s.by),
          [KanshiStartedBy.swayConfig, KanshiStartedBy.systemdUnit]);
      expect(r.startedTwice, isTrue);
    });

    test('a disabled unit is not a starter', () async {
      final runner = FakeProcessRunner(
        installed: {'systemctl'},
        responses: {
          'systemctl --user is-enabled kanshi.service':
              ProcessResult(0, 1, 'disabled\n', ''),
        },
      );
      final r = await KanshiAutostart.detect(runner: runner, sway: false);
      expect(r.found, isFalse);
      expect(r.complete, isTrue);
    });

    test('an unreadable sway config is not "nothing found"', () async {
      final r = await KanshiAutostart.detect(
        runner: FakeProcessRunner(),
        swayConfigPath: '${tmp.path}/absent',
      );
      expect(r.found, isFalse);
      expect(r.complete, isFalse);
    });
  });

  group('setting it up', () {
    test('with kanshictl: start once, reload with sway', () {
      expect(KanshiAutostart.swayLines(kanshictl: true),
          ['exec kanshi', 'exec_always kanshictl reload']);
    });

    test('without kanshictl: restart with sway', () {
      expect(KanshiAutostart.swayLines(kanshictl: false),
          ["exec_always sh -c 'pkill -x kanshi; sleep 0.2; exec kanshi'"]);
    });

    test('a custom kanshi config goes along, if it can do so safely', () {
      expect(
          KanshiAutostart.swayLines(
              kanshictl: true, kanshiConfigPath: '/home/u/kanshi.conf'),
          contains('exec kanshi -c /home/u/kanshi.conf'));
      for (final unsafe in [
        '/home/u/my config',
        r'$HOME/kanshi',
        "/home/u/it's",
        '/home/u/a;b',
      ]) {
        expect(
            KanshiAutostart.swayLines(
                kanshictl: false, kanshiConfigPath: unsafe),
            isNull,
            reason: unsafe);
      }
    });

    test('what it writes is what it recognises', () {
      for (final kanshictl in [true, false]) {
        final r = scan(KanshiAutostart.swayLines(
            kanshictl: kanshictl, kanshiConfigPath: '/home/u/k.conf')!);
        expect(r.starters, hasLength(1), reason: 'kanshictl: $kanshictl');
        expect(r.reappliesOnSwayReload, isTrue, reason: 'kanshictl: $kanshictl');
      }
    });

    group('addToSwayConfig', () {
      late Directory tmp;
      setUp(() => tmp = Directory.systemTemp.createTempSync('kanshi_add_'));
      tearDown(() => tmp.deleteSync(recursive: true));

      test('appends under the marker and leaves the rest alone', () async {
        final cfg = File('${tmp.path}/config')
          ..writeAsStringSync('set \$mod Mod4\nbar {\n}');
        final err =
            await KanshiAutostart.addToSwayConfig(cfg.path, ['exec kanshi']);
        expect(err, isNull);
        expect(
          cfg.readAsStringSync(),
          'set \$mod Mod4\nbar {\n}\n\n${KanshiAutostart.marker}\nexec kanshi\n',
        );
      });

      test('writes through a symlink instead of replacing it', () async {
        final real = File('${tmp.path}/dotfiles/sway')
          ..createSync(recursive: true)
          ..writeAsStringSync('x\n');
        final link = Link('${tmp.path}/config')..createSync(real.path);
        expect(
            await KanshiAutostart.addToSwayConfig(link.path, ['exec kanshi']),
            isNull);
        expect(FileSystemEntity.isLinkSync(link.path), isTrue);
        expect(real.readAsStringSync(), endsWith('exec kanshi\n'));
      });

      test('a file it cannot write comes back as a sentence', () async {
        final err = await KanshiAutostart.addToSwayConfig(
            '${tmp.path}/absent/config', ['exec kanshi']);
        expect(err, startsWith('Could not write'));
      });
    });
  });
}
