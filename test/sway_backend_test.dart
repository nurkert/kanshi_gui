import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_mode.dart';
import 'package:kanshi_gui/services/backends/sway_backend.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';

import 'fakes/fake_process_runner.dart';

const _swayOutputJson = '''
[
  {
    "name": "DP-1",
    "make": "Eizo",
    "model": "CG279X",
    "serial": "0",
    "active": true,
    "scale": 1.0,
    "transform": "normal",
    "rect": {"x": 0, "y": 0, "width": 2560, "height": 1440},
    "current_mode": {"width": 2560, "height": 1440, "refresh": 60000},
    "modes": [
      {"width": 2560, "height": 1440, "refresh": 60000},
      {"width": 1920, "height": 1080, "refresh": 60000}
    ]
  }
]
''';

void main() {
  group('SwayBackend.getOutputs', () {
    test('parses swaymsg get_outputs JSON', () async {
      final fake = FakeProcessRunner(
        installed: {'swaymsg'},
        responses: {
          'swaymsg -t get_outputs':
              ProcessResult(0, 0, _swayOutputJson, ''),
        },
      );
      final backend = SwayBackend(runner: fake);
      final outputs = await backend.getOutputs();
      expect(outputs, hasLength(1));
      expect(outputs.first.id, equals('DP-1'));
      expect(outputs.first.width, equals(2560));
      expect(outputs.first.refresh, equals(60));
      expect(outputs.first.modes, hasLength(2));
    });

    test('strips literal "Unknown" from manufacturer string', () async {
      const json = '''
[
  {
    "name": "eDP-1",
    "make": "Lenovo",
    "model": "X1",
    "serial": "Unknown",
    "active": true,
    "scale": 1.0,
    "transform": "normal",
    "rect": {"x": 0, "y": 0, "width": 1920, "height": 1080},
    "current_mode": {"width": 1920, "height": 1080, "refresh": 60000},
    "modes": [{"width": 1920, "height": 1080, "refresh": 60000}]
  }
]
''';
      final fake = FakeProcessRunner(
        installed: {'swaymsg'},
        responses: {
          'swaymsg -t get_outputs': ProcessResult(0, 0, json, ''),
        },
      );
      final backend = SwayBackend(runner: fake);
      final m = (await backend.getOutputs()).single;
      expect(m.manufacturer, equals('Lenovo X1'));
    });
  });

  group('SwayBackend invocations', () {
    late FakeProcessRunner fake;
    late SwayBackend backend;
    setUp(() {
      fake = FakeProcessRunner(installed: {'swaymsg'});
      backend = SwayBackend(runner: fake);
    });

    test('enable() shells out to swaymsg', () async {
      await backend.enable('DP-1');
      expect(fake.calls.last, equals(['swaymsg', 'output', 'DP-1', 'enable']));
    });

    test('disable() shells out to swaymsg', () async {
      await backend.disable('DP-1');
      expect(
          fake.calls.last, equals(['swaymsg', 'output', 'DP-1', 'disable']));
    });

    test('apply() passes position as two separate arguments', () async {
      const json = '''
[{"name":"DP-1","make":"X","model":"Y","serial":"Z","active":true,
  "scale":1.0,"transform":"normal","rect":{"x":0,"y":0,"width":2560,"height":1440},
  "current_mode":{"width":2560,"height":1440,"refresh":60000},
  "modes":[{"width":2560,"height":1440,"refresh":60000}]}]
''';
      fake = FakeProcessRunner(installed: {'swaymsg'}, responses: {
        'swaymsg -t get_outputs': ProcessResult(0, 0, json, ''),
      });
      backend = SwayBackend(runner: fake);
      final outs = await backend.getOutputs();
      final m = outs.first.copyWith(x: 1920, y: 0);
      await backend.apply(m);
      // The position must be two args: "1920" and "0", NOT "1920,0".
      final posIdx = fake.calls.last.indexOf('position');
      expect(posIdx, greaterThanOrEqualTo(0));
      expect(fake.calls.last[posIdx + 1], equals('1920'));
      expect(fake.calls.last[posIdx + 2], equals('0'));
      // And in particular, the "1920,0" form must not appear anywhere.
      expect(fake.calls.last, isNot(contains('1920,0')));
    });

    test('setMode() formats refresh correctly', () async {
      await backend.setMode(
          'DP-1', MonitorMode(width: 2560, height: 1440, refresh: 59.95));
      expect(
        fake.calls.last,
        equals([
          'swaymsg',
          'output',
          'DP-1',
          'mode',
          '2560x1440@${KanshiConfigWriter.formatHz(59.95)}Hz',
        ]),
      );
    });

    test('writeOptions inject Sway-specific extras', () {
      expect(backend.writeOptions, equals(KanshiWriteOptions.swayDefaults));
    });

    test('falls back to bash restart when systemd unit is inactive',
        () async {
      fake = FakeProcessRunner(
        installed: {'swaymsg'},
        responses: {
          'systemctl --user is-active --quiet kanshi.service':
              ProcessResult(0, 3, '', ''),
        },
      );
      backend = SwayBackend(runner: fake);
      await backend.restartCompositorProfileApply();
      expect(fake.calls.last.first, equals('bash'));
      expect(fake.calls.last.last, contains('setsid kanshi'));
    });

    test('uses systemctl when user kanshi.service is active', () async {
      fake = FakeProcessRunner(
        installed: {'swaymsg'},
        responses: {
          'systemctl --user is-active --quiet kanshi.service':
              ProcessResult(0, 0, '', ''),
        },
      );
      backend = SwayBackend(runner: fake);
      await backend.restartCompositorProfileApply();
      expect(
        fake.calls.last,
        equals(['systemctl', '--user', 'restart', 'kanshi.service']),
      );
    });

    test('uses kanshictl reload when available and kanshi is running',
        () async {
      fake = FakeProcessRunner(
        installed: {'swaymsg', 'kanshictl'},
        responses: {
          'pgrep -x kanshi': ProcessResult(0, 0, '12345\n', ''),
          'kanshictl reload': ProcessResult(0, 0, '', ''),
        },
      );
      backend = SwayBackend(runner: fake);
      await backend.restartCompositorProfileApply();
      expect(
        fake.calls.map((c) => c.first).toList(),
        containsAllInOrder(['pgrep', 'kanshictl']),
      );
      // Did NOT fall through to systemctl/bash.
      expect(fake.calls.any((c) => c.first == 'systemctl'), isFalse);
      expect(fake.calls.any((c) => c.first == 'bash'), isFalse);
    });
  });
}
