import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/domain/output_transform.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/backends/sway_backend.dart';
import 'package:kanshi_gui/services/config_service.dart';
import 'package:kanshi_gui/services/kanshi_config_parser.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';

import 'fakes/fake_process_runner.dart';

/// A portrait panel as sway reports it when it stands the way its owner
/// wants: `transform 270` over IPC, 1080x1920 on the desk.
const _portraitJson = '''
[
  {
    "name": "HDMI-A-2",
    "make": "Philips Consumer Electronics Company",
    "model": "PHL 223V5",
    "serial": "ZVC1437002369",
    "active": true,
    "scale": 1.0,
    "transform": "270",
    "rect": {"x": 0, "y": 0, "width": 1080, "height": 1920},
    "current_mode": {"width": 1920, "height": 1080, "refresh": 60000},
    "modes": [{"width": 1920, "height": 1080, "refresh": 60000}]
  }
]
''';

MonitorTileData _portrait({int rotation = 90}) => MonitorTileData(
      id: 'HDMI-A-2',
      manufacturer: 'Philips Consumer Electronics Company PHL 223V5 ZVC1437002369',
      edidDescriptor:
          'Philips Consumer Electronics Company PHL 223V5 ZVC1437002369',
      x: 0,
      y: 0,
      width: 1080,
      height: 1920,
      scale: 1.0,
      rotation: rotation,
      refresh: 60,
      resolution: '1080x1920',
      orientation: 'portrait',
      modes: const [],
      enabled: true,
    );

Future<Directory> _tempConfigDir() =>
    Directory.systemTemp.createTemp('kanshi_rotation_');

ConfigService _serviceIn(Directory dir) => ConfigService(
      configPath: '${dir.path}/config',
      backupPrefix: '${dir.path}/backups/config.bak',
    );

void main() {
  group('the two rotation conventions', () {
    test('90 and 270 swap, normal and 180 do not', () {
      expect(swayTransformFor(90), equals('270'));
      expect(swayTransformFor(270), equals('90'));
      expect(swayTransformFor(180), equals('180'));
      expect(swayTransformFor(0), equals('normal'));
      expect(swayTransformFor(360), equals('normal'));
    });

    test('the mapping is its own inverse', () {
      for (final r in [0, 90, 180, 270]) {
        expect(
          rotationFromSwayTransform(swayTransformFor(r)),
          equals(r),
          reason: 'round trip through sway naming must return $r',
        );
      }
    });
  });

  group('SwayBackend converts at the IPC boundary', () {
    test('a screen sway calls 270 is stored as 90', () async {
      final fake = FakeProcessRunner(
        installed: {'swaymsg'},
        responses: {
          'swaymsg -t get_outputs': ProcessResult(0, 0, _portraitJson, ''),
        },
      );
      final outputs = await SwayBackend(runner: fake).getOutputs();
      expect(outputs.single.rotation, equals(90));
      // The visible rect stays portrait whatever it is called.
      expect(outputs.single.width, equals(1080));
      expect(outputs.single.height, equals(1920));
      expect(outputs.single.orientation, equals('portrait'));
    });

    test('applying a stored 90 asks sway for 270', () async {
      final fake = FakeProcessRunner(installed: {'swaymsg'});
      await SwayBackend(runner: fake).apply(_portrait());
      final call = fake.calls.single;
      final at = call.indexOf('transform');
      expect(at, greaterThan(0));
      expect(call[at + 1], equals('270'));
    });

    test('what sway reports comes back unchanged after a round trip',
        () async {
      // The regression in one line: read the live orientation, apply it
      // again, and sway must be asked for the orientation it just reported.
      final fake = FakeProcessRunner(
        installed: {'swaymsg'},
        responses: {
          'swaymsg -t get_outputs': ProcessResult(0, 0, _portraitJson, ''),
        },
      );
      final backend = SwayBackend(runner: fake);
      final live = (await backend.getOutputs()).single;
      await backend.apply(live);
      final call = fake.calls.last;
      expect(call[call.indexOf('transform') + 1], equals('270'));
    });
  });

  group('the config file speaks kanshi', () {
    test('a stored 90 is written as transform 90, verbatim', () {
      final rendered = KanshiConfigWriter.render([
        Profile(name: 'desk', monitors: [_portrait()]),
      ]);
      expect(rendered, contains('transform 90'));
      expect(rendered, isNot(contains('transform 270')));
    });

    test('a hand-written transform is read as kanshi means it', () {
      final parsed = KanshiConfigParser.parse('''
profile 'desk' {
    output "HDMI-A-2" enable scale 1.00 mode 1920x1080@60Hz transform 90 position 0,0
}
''');
      expect(parsed.single.monitors.single.rotation, equals(90));
    });

    test('the live orientation survives sway IPC, the model and the file', () {
      // What the user reported: right way up on screen, upside down after a
      // reboot. The value kanshi ends up executing must be the one that
      // reproduces what sway reported.
      const swaySays = '270';
      final stored = rotationFromSwayTransform(swaySays);
      final rendered = KanshiConfigWriter.render([
        Profile(name: 'desk', monitors: [_portrait(rotation: stored)]),
      ]);
      final reparsed = KanshiConfigParser.parse(rendered);
      expect(
        swayTransformFor(reparsed.single.monitors.single.rotation),
        equals(swaySays),
      );
    });
  });

  group('migrating a config an older release wrote', () {
    test('flips 90 and 270 in profiles this app wrote, and stamps the file',
        () async {
      final dir = await _tempConfigDir();
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/config');
      await file.writeAsString('''
profile 'desk' {
    output "Philips PHL 223V5 X1" enable scale 1.00 mode 1920x1080@60Hz transform 270 position 0,0
    output "Eizo CG279X Y2" enable scale 1.00 mode 2560x1440@60Hz transform normal position 1080,0
    # kanshi_gui:port 'Philips PHL 223V5 X1'='HDMI-A-2'
}
''');
      final svc = _serviceIn(dir);
      expect(await svc.migrateTransformConvention(), isTrue);
      final after = await file.readAsString();
      expect(after, startsWith(KanshiConfigWriter.transformConventionMarker));
      expect(after, contains('transform 90 position 0,0'));
      expect(after, contains('transform normal position 1080,0'));
    });

    test('runs once — the marker stops the second pass', () async {
      final dir = await _tempConfigDir();
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/config');
      await file.writeAsString('''
profile 'desk' {
    output "Philips PHL 223V5 X1" enable scale 1.00 mode 1920x1080@60Hz transform 270 position 0,0
    # kanshi_gui:port 'Philips PHL 223V5 X1'='HDMI-A-2'
}
''');
      final svc = _serviceIn(dir);
      expect(await svc.migrateTransformConvention(), isTrue);
      final once = await file.readAsString();
      expect(await svc.migrateTransformConvention(), isFalse);
      expect(await file.readAsString(), equals(once));
    });

    test('leaves a hand-written profile alone', () async {
      // No `# kanshi_gui:` annotation anywhere in the block: the user typed
      // this, so the number already means what kanshi will do with it.
      final dir = await _tempConfigDir();
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/config');
      const hand = '''
profile 'mine' {
    output "HDMI-A-2" enable transform 270 position 0,0
}
''';
      await file.writeAsString(hand);
      final svc = _serviceIn(dir);
      expect(await svc.migrateTransformConvention(), isFalse);
      expect(await file.readAsString(), equals(hand));
    });

    test('touches only the block that carries our annotations', () async {
      final dir = await _tempConfigDir();
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/config');
      await file.writeAsString('''
profile 'mine' {
    output "HDMI-A-1" enable transform 90 position 0,0
}

profile 'ours' {
    output "HDMI-A-2" enable transform 90 position 0,0
    # kanshi_gui:port 'HDMI-A-2'='HDMI-A-2'
}
''');
      final svc = _serviceIn(dir);
      expect(await svc.migrateTransformConvention(), isTrue);
      final after = await file.readAsString();
      expect(after, contains('"HDMI-A-1" enable transform 90'));
      expect(after, contains('"HDMI-A-2" enable transform 270'));
    });

    test('a config with nothing rotated is not written to at all', () async {
      // Opening the app must not touch disk; see kanshi_controller_test.
      final dir = await _tempConfigDir();
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/config');
      const flat = '''
profile 'desk' {
    output "HDMI-A-2" enable transform normal position 0,0
    # kanshi_gui:port 'HDMI-A-2'='HDMI-A-2'
}
''';
      await file.writeAsString(flat);
      final svc = _serviceIn(dir);
      expect(await svc.migrateTransformConvention(), isFalse);
      expect(await file.readAsString(), equals(flat));
      expect(Directory('${dir.path}/backups').existsSync(), isFalse);
    });

    test('an exec line that happens to mention 90 is not rewritten', () async {
      final dir = await _tempConfigDir();
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/config');
      await file.writeAsString('''
profile 'desk' {
    output "HDMI-A-2" enable transform 270 position 0,0
    # kanshi_gui:port 'HDMI-A-2'='HDMI-A-2'
    exec notify-send "transform 90 was the old bug"
}
''');
      final svc = _serviceIn(dir);
      expect(await svc.migrateTransformConvention(), isTrue);
      final after = await file.readAsString();
      expect(after, contains('exec notify-send "transform 90 was the old bug"'));
      expect(after, contains('output "HDMI-A-2" enable transform 90'));
    });

    test('a missing or empty config is a no-op', () async {
      final dir = await _tempConfigDir();
      addTearDown(() => dir.delete(recursive: true));
      final svc = _serviceIn(dir);
      expect(await svc.migrateTransformConvention(), isFalse);
      await File('${dir.path}/config').writeAsString('\n\n');
      expect(await svc.migrateTransformConvention(), isFalse);
    });
  });

  group('the save path stamps the convention', () {
    test('a saved config carries the marker, so it is never flipped again',
        () async {
      final dir = await _tempConfigDir();
      addTearDown(() => dir.delete(recursive: true));
      final svc = _serviceIn(dir);
      await svc.saveProfiles([
        Profile(name: 'desk', monitors: [_portrait()]),
      ]);
      final saved = await File('${dir.path}/config').readAsString();
      expect(saved, startsWith(KanshiConfigWriter.transformConventionMarker));
      expect(saved, contains('transform 90'));
      expect(await svc.migrateTransformConvention(), isFalse);
    });

    test('saving twice does not stack markers', () async {
      final dir = await _tempConfigDir();
      addTearDown(() => dir.delete(recursive: true));
      final svc = _serviceIn(dir);
      final profiles = [Profile(name: 'desk', monitors: [_portrait()])];
      await svc.saveProfiles(profiles);
      await svc.saveProfiles(profiles);
      final saved = await File('${dir.path}/config').readAsString();
      expect(
        KanshiConfigWriter.transformConventionMarker.allMatches(saved).length,
        equals(1),
      );
    });
  });
}
