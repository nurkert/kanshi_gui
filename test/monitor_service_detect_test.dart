import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/services/backends/noop_backend.dart';
import 'package:kanshi_gui/services/backends/sway_backend.dart';
import 'package:kanshi_gui/services/backends/wlr_randr_backend.dart';
import 'package:kanshi_gui/services/monitor_service.dart';

import 'fakes/fake_process_runner.dart';

/// Stand-in for `File(path).exists()` that consults a static set so tests
/// can simulate "this socket file is/isn't present" without touching the
/// real filesystem.
Future<bool> Function(String) _existsIn(Set<String> present) =>
    (p) async => present.contains(p);

void main() {
  group('MonitorService.detect', () {
    test('picks SwayBackend only when SWAYSOCK points at an existing path',
        () async {
      final runner = FakeProcessRunner(installed: {'swaymsg', 'wlr-randr'});
      final svc = await MonitorService.detect(
        runner: runner,
        environment: {'SWAYSOCK': '/run/user/1000/sway-ipc.sock'},
        socketExists: _existsIn({'/run/user/1000/sway-ipc.sock'}),
      );
      expect(svc, isA<SwayBackend>());
    });

    test('falls back to wlr-randr when swaymsg is in PATH but SWAYSOCK is unset',
        () async {
      // Regression: a niri / river / hyprland user with the sway package
      // installed for tooling reasons used to land on SwayBackend, where
      // every IPC call would fail because no sway socket exists. Detection
      // must require a *running* sway, not just an installed binary.
      final runner = FakeProcessRunner(installed: {'swaymsg', 'wlr-randr'});
      final svc = await MonitorService.detect(
        runner: runner,
        environment: const {},
        socketExists: _existsIn(const {}),
      );
      expect(svc, isA<WlrRandrBackend>());
    });

    test('falls back to wlr-randr when SWAYSOCK is set but the file is gone',
        () async {
      // SWAYSOCK can stick around in inherited environments (tmux,
      // screen, persistent shell sessions) after sway exited. Treat
      // a stale value the same as no value.
      final runner = FakeProcessRunner(installed: {'swaymsg', 'wlr-randr'});
      final svc = await MonitorService.detect(
        runner: runner,
        environment: {'SWAYSOCK': '/run/user/1000/stale.sock'},
        socketExists: _existsIn(const {}),
      );
      expect(svc, isA<WlrRandrBackend>());
    });

    test('falls back to noop when neither swaymsg nor wlr-randr are present',
        () async {
      final runner = FakeProcessRunner(installed: const {});
      final svc = await MonitorService.detect(
        runner: runner,
        environment: const {},
        socketExists: _existsIn(const {}),
      );
      expect(svc, isA<NoopBackend>());
    });

    test('SWAYSOCK without swaymsg in PATH still falls through to wlr-randr',
        () async {
      // Pathological — running sway but no swaymsg client somehow. The
      // backend can't speak IPC without the binary, so prefer the
      // wlroots fallback.
      final runner = FakeProcessRunner(installed: {'wlr-randr'});
      final svc = await MonitorService.detect(
        runner: runner,
        environment: {'SWAYSOCK': '/run/user/1000/sway-ipc.sock'},
        socketExists: _existsIn({'/run/user/1000/sway-ipc.sock'}),
      );
      expect(svc, isA<WlrRandrBackend>());
    });
  });
}
