import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/services/backends/wlr_randr_backend.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';

import 'fakes/fake_process_runner.dart';

const _wlrJson = '''
[
  {
    "name": "HDMI-A-1",
    "make": "Acme",
    "model": "Display",
    "serial": "1",
    "enabled": true,
    "scale": 1.0,
    "transform": "normal",
    "position": {"x": 0, "y": 0},
    "modes": [
      {"width": 1920, "height": 1080, "refresh": 60.0, "current": true},
      {"width": 2560, "height": 1440, "refresh": 60.0}
    ]
  }
]
''';

void main() {
  test('WlrRandrBackend.getOutputs parses --json output', () async {
    final fake = FakeProcessRunner(
      installed: {'wlr-randr'},
      responses: {
        'wlr-randr --json': ProcessResult(0, 0, _wlrJson, ''),
      },
    );
    final backend = WlrRandrBackend(runner: fake);
    final outputs = await backend.getOutputs();
    expect(outputs, hasLength(1));
    expect(outputs.first.id, equals('HDMI-A-1'));
    expect(outputs.first.width, equals(1920));
    expect(outputs.first.refresh, equals(60));
  });

  test('WlrRandrBackend uses neutral write options (no Sway extras)', () {
    final fake = FakeProcessRunner();
    final backend = WlrRandrBackend(runner: fake);
    expect(backend.writeOptions, equals(KanshiWriteOptions.neutral));
  });

  test('WlrRandrBackend.enable issues --on', () async {
    final fake = FakeProcessRunner();
    final backend = WlrRandrBackend(runner: fake);
    await backend.enable('HDMI-A-1');
    expect(
      fake.calls.last,
      equals(['wlr-randr', '--output', 'HDMI-A-1', '--on']),
    );
  });

  test('WlrRandrBackend.disable issues --off', () async {
    final fake = FakeProcessRunner();
    final backend = WlrRandrBackend(runner: fake);
    await backend.disable('HDMI-A-1');
    expect(
      fake.calls.last,
      equals(['wlr-randr', '--output', 'HDMI-A-1', '--off']),
    );
  });
}
