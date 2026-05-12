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

    test('apply() guards negative coordinates with -- separator', () async {
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
      // Stack the monitor above origin → Y=-1440. Without `--`, swaymsg's
      // getopt parses "-1440" as the option flags -1/-4/-4/-0 and aborts
      // with "invalid option -- '4'".
      final m = outs.first.copyWith(x: 0, y: -1440);
      await backend.apply(m);
      final args = fake.calls.last;
      final dashDashIdx = args.indexOf('--');
      final outputIdx = args.indexOf('output');
      expect(dashDashIdx, greaterThanOrEqualTo(0),
          reason: '`--` must precede the message so getopt stops.');
      expect(dashDashIdx, lessThan(outputIdx),
          reason: '`--` must come before the message args.');
      expect(args, contains('-1440'));
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

  group('SwayBackend.evacuateOutputWorkspaces', () {
    test('no-ops when targets list is empty', () async {
      final fake = FakeProcessRunner(installed: {'swaymsg'});
      final backend = SwayBackend(runner: fake);
      await backend.evacuateOutputWorkspaces('DP-2', const []);
      expect(fake.calls, isEmpty);
    });

    test('moves numeric workspaces on dst to the single target', () async {
      const wsJson = '''
[
  {"num": 1, "name": "1", "output": "DP-1", "focused": false},
  {"num": 2, "name": "2", "output": "DP-2", "focused": true},
  {"num": 4, "name": "4", "output": "DP-2", "focused": false}
]
''';
      final fake = FakeProcessRunner(installed: {'swaymsg'}, responses: {
        'swaymsg -t get_workspaces': ProcessResult(0, 0, wsJson, ''),
      });
      final backend = SwayBackend(runner: fake);
      await backend.evacuateOutputWorkspaces('DP-2', ['DP-1']);
      // First call is the get_workspaces query, second is the compound chain.
      expect(fake.calls, hasLength(2));
      final chain = fake.calls[1][1];
      expect(
        chain,
        equals(
          "workspace number 2; move workspace to output 'DP-1'; "
          "workspace number 4; move workspace to output 'DP-1'; "
          "workspace number 2",
        ),
        reason: 'must move both ws-on-dst entries and refocus the '
            'originally focused workspace (2) at the end',
      );
    });

    test('round-robins across multiple targets', () async {
      const wsJson = '''
[
  {"num": 1, "name": "1", "output": "DP-3", "focused": false},
  {"num": 2, "name": "2", "output": "DP-3", "focused": false},
  {"num": 3, "name": "3", "output": "DP-3", "focused": true},
  {"num": 4, "name": "4", "output": "eDP-1", "focused": false}
]
''';
      final fake = FakeProcessRunner(installed: {'swaymsg'}, responses: {
        'swaymsg -t get_workspaces': ProcessResult(0, 0, wsJson, ''),
      });
      final backend = SwayBackend(runner: fake);
      await backend.evacuateOutputWorkspaces('DP-3', ['DP-1', 'DP-2']);
      final chain = fake.calls[1][1];
      expect(chain, contains("workspace number 1; move workspace to output 'DP-1'"));
      expect(chain, contains("workspace number 2; move workspace to output 'DP-2'"));
      expect(chain, contains("workspace number 3; move workspace to output 'DP-1'"));
      // ws 4 (on eDP-1) is not on dst — must not be moved.
      expect(chain, isNot(contains('workspace number 4')));
      expect(chain.endsWith('workspace number 3'), isTrue,
          reason: 'must refocus the originally focused workspace at the end');
    });

    test('quotes named workspaces and handles >9 numeric slots', () async {
      const wsJson = r'''
[
  {"num": 10, "name": "10", "output": "DP-2", "focused": false},
  {"num": -1, "name": "code: main", "output": "DP-2", "focused": true}
]
''';
      final fake = FakeProcessRunner(installed: {'swaymsg'}, responses: {
        'swaymsg -t get_workspaces': ProcessResult(0, 0, wsJson, ''),
      });
      final backend = SwayBackend(runner: fake);
      await backend.evacuateOutputWorkspaces('DP-2', ['DP-1']);
      final chain = fake.calls[1][1];
      // Numeric > 9 still goes via `workspace number N`.
      expect(chain, contains("workspace number 10; move workspace to output 'DP-1'"));
      // Non-numeric workspace gets quoted by name.
      expect(chain, contains(r'workspace "code: main"; move workspace to output ' "'DP-1'"));
      // Refocus uses the quoted name (the originally focused one).
      expect(chain.endsWith(r'workspace "code: main"'), isTrue);
    });

    test('skips when no workspace lives on dst', () async {
      const wsJson = '''
[
  {"num": 1, "name": "1", "output": "DP-1", "focused": true},
  {"num": 2, "name": "2", "output": "DP-1", "focused": false}
]
''';
      final fake = FakeProcessRunner(installed: {'swaymsg'}, responses: {
        'swaymsg -t get_workspaces': ProcessResult(0, 0, wsJson, ''),
      });
      final backend = SwayBackend(runner: fake);
      await backend.evacuateOutputWorkspaces('DP-2', ['DP-1']);
      // Only the get_workspaces probe — no compound chain.
      expect(fake.calls, hasLength(1));
      expect(fake.calls.single, equals(['swaymsg', '-t', 'get_workspaces']));
    });
  });

  group('SwayBackend.waitForOutputClear', () {
    test('returns true immediately when no ws lives on dst', () async {
      const wsJson = '''
[
  {"num": 1, "name": "1", "output": "DP-1", "focused": true}
]
''';
      final fake = FakeProcessRunner(installed: {'swaymsg'}, responses: {
        'swaymsg -t get_workspaces': ProcessResult(0, 0, wsJson, ''),
      });
      final backend = SwayBackend(runner: fake);
      final ok = await backend.waitForOutputClear('DP-2',
          timeout: const Duration(milliseconds: 200));
      expect(ok, isTrue);
    });

    test('returns false on timeout when ws stays on dst', () async {
      const wsJson = '''
[
  {"num": 1, "name": "1", "output": "DP-2", "focused": false}
]
''';
      final fake = FakeProcessRunner(installed: {'swaymsg'}, responses: {
        'swaymsg -t get_workspaces': ProcessResult(0, 0, wsJson, ''),
      });
      final backend = SwayBackend(runner: fake);
      final ok = await backend.waitForOutputClear('DP-2',
          timeout: const Duration(milliseconds: 120));
      expect(ok, isFalse);
      // Must have polled at least twice within the 120 ms window
      // (50 ms sleep between probes).
      expect(fake.calls.length, greaterThanOrEqualTo(2));
    });
  });
}
